import AppKit
import Foundation

let appSupport = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/VarietyV2")
let generatedDir = appSupport.appendingPathComponent("generated")

let args = Array(CommandLine.arguments.dropFirst())

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

case "--selftest":
    exit(SelfTest.run() ? 0 : 1)

case "--probe-sources":
    // Hits the real endpoints. Used to catch upstream APIs changing shape or
    // closing off, which is the main way this app rots.
    let settings = Settings.load()
    let sources: [any ImageSource] = args.count > 1
        ? SourceRegistry.all(settings: settings).filter { $0.id.hasPrefix(args[1]) }
        : SourceRegistry.all(settings: settings)

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

default:
    print("""
    VarietyV2 — wallpaper manager for macOS

      --set <image>   set the wallpaper
      --current       print the wallpaper macOS actually has set
      --selftest      run internal checks
    """)
}
