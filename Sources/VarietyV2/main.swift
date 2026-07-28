import AppKit
import ServiceManagement
import Foundation

let appSupport = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/VarietyV2")
let generatedDir = appSupport.appendingPathComponent("generated")

let args = Array(CommandLine.arguments.dropFirst())

/// Runs main-actor work to completion from a synchronous entry point.
///
/// Blocking on a semaphore here would deadlock: the main thread is the only
/// place `@MainActor` work can run, so waiting on it guarantees it never does.
/// Pumping the run loop instead lets the task be scheduled.
func runPumpingMainRunLoop(_ work: @escaping @MainActor () async -> Void) {
    let finished = Finished()
    Task { @MainActor in
        await work()
        finished.value = true
    }
    while !finished.value {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Reference box so the flag survives being captured by the escaping task.
final class Finished: @unchecked Sendable {
    var value = false
}

switch args.first {
case "--current":
    if let url = WallpaperStore.currentImageURL() {
        print(url.path)
    } else {
        print("(dynamic system wallpaper — no backing file)")
    }

case "--set":
    guard args.count > 1 else {
        FileHandle.standardError.write(Data("usage: VarietyV2 --set <image>\n".utf8))
        exit(2)
    }
    let source = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let store = GenerationStore(directory: generatedDir)
    // Copy into a fresh generation path rather than pointing at the original:
    // this is what makes repeated sets of the *same* source image actually
    // reach the screen.
    let dest = store.nextURL(ext: source.pathExtension.isEmpty ? "png" : source.pathExtension)
    do {
        try FileManager.default.copyItem(at: source, to: dest)
        try WallpaperSetter.apply(url: dest)
        store.collect(keeping: dest)
        print("set: \(dest.path)")
    } catch {
        FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
        exit(1)
    }

case "--login-status":
    // Run this as the bundle's executable, not the bare SwiftPM binary —
    // SMAppService resolves against Bundle.main.
    print("bundle:    \(Bundle.main.bundlePath)")
    print("available: \(LoginItem.isAvailable)")
    print("enabled:   \(LoginItem.isEnabled)")
    let raw = SMAppService.mainApp.status
    let names: [Int: String] = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
    print("status:    \(names[Int(raw.rawValue)] ?? "?") (\(raw.rawValue))")
    if args.count > 1, args[1] == "enable" {
        do {
            try SMAppService.mainApp.register()
            print("register:  ok -> \(LoginItem.isEnabled)")
        } catch {
            print("register:  FAILED -> \(error)")
        }
    }

case "--search":
    // Exercises the same path the Find Images window uses.
    guard args.count > 2 else {
        FileHandle.standardError.write(Data("usage: VarietyV2 --search <wallhaven|unsplash|reddit|artstation> <query>\n".utf8))
        exit(2)
    }
    let kindName = args[1]
    let term = args[2...].joined(separator: " ")
    let settings = Settings.load()

    guard let kind = Source.Kind(rawValue: kindName) else {
        FileHandle.standardError.write(Data("unknown source '\(kindName)'\n".utf8))
        exit(2)
    }

    print("screen: \(ScreenGeometry.description)")
    print("asking for at least \(Int(ScreenGeometry.primaryPixelSize.width))×\(Int(ScreenGeometry.primaryPixelSize.height))")

    let searchSemaphore = DispatchSemaphore(value: 0)
    Task {
        let source = Source(enabled: true, kind: kind, location: term)
        guard let downloader = SourceRegistry.downloader(for: source, settings: settings, breadth: true) else {
            print("source unavailable (needs credentials, or internet access is off)")
            searchSemaphore.signal(); return
        }
        do {
            let found = try await downloader.fetch()
            let fitting = found.filter { $0.fitsScreen(settings: settings) }
                .sorted { $0.aspectMatch > $1.aspectMatch }
            print("\(found.count) result(s), \(fitting.count) fit this screen")
            for image in fitting.prefix(5) {
                let dims = image.pixelWidth.map { "\($0)×\(image.pixelHeight ?? 0)" } ?? "size unreported"
                print(String(format: "  %-14@ match %.2f  %@", dims as NSString,
                             image.aspectMatch, (image.title ?? "") as NSString))
            }
        } catch {
            print("failed: \(error)")
        }
        searchSemaphore.signal()
    }
    searchSemaphore.wait()

case "--selftest":
    exit(SelfTest.run() ? 0 : 1)

case "--cycle":
    // One complete pass — fetch, download, render, set — without starting the
    // menu bar app. This is the end-to-end check.
    //
    // Note the run loop is *pumped* rather than blocked on a semaphore:
    // Rotator is @MainActor, so parking the main thread would deadlock it —
    // the work can only run on the thread the wait would be holding.
    runPumpingMainRunLoop { @MainActor in
        let rotator = Rotator(settings: Settings.load())
        print("filling library…")
        await rotator.refillIfNeeded()
        print("downloaded: \(rotator.recentForDisplay().count) image(s)")
        await rotator.next()
        if let current = rotator.current {
            print("showing: \(current.lastPathComponent)")
            if let origin = rotator.currentOrigin {
                print("  from: \(origin.sourceName)")
                if let title = origin.title { print("  title: \(title)") }
            }
            print("on screen: \(WallpaperStore.currentImageURL()?.lastPathComponent ?? "unknown")")
        } else {
            print("no image was set")
        }
    }

case "--render":
    // Renders every display mode plus the overlays from one source image, so
    // the pipeline can be eyeballed without touching the desktop.
    guard args.count > 1 else {
        FileHandle.standardError.write(Data("usage: VarietyV2 --render <image> [outdir]\n".utf8))
        exit(2)
    }
    let source = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let outDir = URL(fileURLWithPath: args.count > 2
                     ? (args[2] as NSString).expandingTildeInPath
                     : NSTemporaryDirectory()).appendingPathComponent("varietyv2-render")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let size = CGSize(width: 2560, height: 1600)
    for mode in DisplayMode.allCases {
        let dest = outDir.appendingPathComponent("\(mode.rawValue).jpg")
        do {
            try ImagePipeline.render(.init(source: source, targetSize: size, mode: mode,
                                           quote: nil, clockDate: nil, settings: Settings(), effect: nil),
                                     to: dest)
            print("  ok    \(mode.rawValue) -> \(dest.path)")
        } catch {
            print("  FAIL  \(mode.rawValue): \(error)")
        }
    }

    for filter in Filter.defaults {
        let slug = filter.name.lowercased().replacingOccurrences(of: " ", with: "-")
        let dest = outDir.appendingPathComponent("effect-\(slug).jpg")
        do {
            try ImagePipeline.render(.init(source: source, targetSize: size, mode: .zoom,
                                           quote: nil, clockDate: nil, settings: Settings(),
                                           effect: filter),
                                     to: dest)
            print("  ok    effect \(filter.name)")
        } catch {
            print("  FAIL  effect \(filter.name): \(error)")
        }
    }

    var quoteDemoSettings = Settings()
    quoteDemoSettings.quotesEnabled = true
    quoteDemoSettings.clockEnabled = true
    let overlaid = outDir.appendingPathComponent("overlays.jpg")
    do {
        try ImagePipeline.render(.init(
            source: source, targetSize: size, mode: .zoom,
            quote: QuoteProvider.offline[0], clockDate: Date(), settings: quoteDemoSettings),
                                 to: overlaid)
        print("  ok    quote + clock -> \(overlaid.path)")
    } catch {
        print("  FAIL  overlays: \(error)")
    }

case "--probe-sources":
    // Hits the real endpoints. Used to catch upstream APIs changing shape or
    // closing off, which is the main way this app rots.
    let settings = Settings.load()
    let sources: [any ImageSource] = args.count > 1
        ? SourceRegistry.activeDownloaders(settings: settings).filter { $0.id.hasPrefix(args[1]) }
        : SourceRegistry.activeDownloaders(settings: settings)

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        var failures = 0
        for source in sources {
            do {
                let images = try await source.fetch()
                let sample = images.first.map { " e.g. \($0.imageURL.absoluteString.prefix(72))" } ?? ""
                print("  ok    \(source.displayName): \(images.count) image(s)\(sample)")
                if images.isEmpty { failures += 1 }
            } catch {
                print("  FAIL  \(source.displayName): \(error)")
                failures += 1
            }
        }
        print(failures == 0 ? "\nall sources responded" : "\n\(failures) source(s) unavailable")
        semaphore.signal()
    }
    semaphore.wait()

case "--help", "-h":
    print("""
    VarietyV2 — wallpaper manager for macOS

    Run with no arguments to start the menu bar app.

      --set <image>        set the wallpaper immediately
      --current            print the wallpaper macOS actually has set
      --render <image>     render every display mode to files, for inspection
      --probe-sources [id] fetch from the live image sources
      --selftest           run internal checks
    """)

default:
    // No arguments: run the menu bar app.
    // Top-level code is nonisolated, but this only ever runs on the main
    // thread, so the assumption is sound.
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    // Accessory, not regular: no Dock icon, no menu bar of its own. The
    // bundle's LSUIElement covers this too, but setting it here means running
    // the bare binary during development behaves the same way.
    app.setActivationPolicy(.accessory)
    app.run()
}
