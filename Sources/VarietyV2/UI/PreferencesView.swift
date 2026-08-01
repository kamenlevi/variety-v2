import AppKit
import SwiftUI

/// Variety's Preferences dialog, tab for tab.
///
/// The Linux-only options are the only ones absent: the wallpaper-setting
/// script hooks (macOS has one way to set a wallpaper) and the desktop-
/// environment workarounds. Everything else is here under the same names.
struct PreferencesView: View {

    /// A snapshot, taken when the window opens.
    ///
    /// That is a hazard: anything that changes settings elsewhere while this
    /// window is open — the Find Images window adding a source, the app
    /// reacting to something — is invisible here, and the next edit made in
    /// this window writes the stale snapshot back, silently undoing it. So the
    /// snapshot is re-synced whenever the window becomes active, and edits are
    /// merged rather than wholesale replacing.
    @State var settings: Settings
    let rotator: Rotator
    let onChange: (Settings) -> Void
    var onOpenFolder: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", wallpaper = "Wallpaper", quotes = "Quotes"
        case clock = "Clock", slideshow = "Slideshow", downloading = "Downloading"
        case library = "Library", filtering = "Filtering", effects = "Effects"
        case tips = "Tips", about = "About", donate = "Donate"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // A single compact row of small tabs, as in the GTK original.
            // SwiftUI's own TabView on macOS renders large pill tabs that wrap
            // once there are ten of them, which looks nothing like Variety.
            TabStrip(selection: $tab)

            Divider()

            Group {
                switch tab {
                case .general:     GeneralTab(settings: $settings, rotator: rotator)
                case .wallpaper:   WallpaperTab(settings: $settings)
                case .quotes:      QuotesTab(settings: $settings)
                case .clock:       ClockTab(settings: $settings)
                case .slideshow:   SlideshowTab(settings: $settings)
                case .downloading: DownloadingTab(settings: $settings)
                case .library:     LibraryTab(rotator: rotator)
                case .filtering:   FilteringTab(settings: $settings)
                case .effects:     CustomizeTab(settings: $settings)
                case .tips:        TipsTab()
                case .about:       AboutTab()
                case .donate:      DonateTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 580)
        .onChange(of: settings) { _, new in onChange(new) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            resync()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in
            resync()
        }
    }

    /// Pulls in changes made outside this window without clobbering them.
    private func resync() {
        let live = rotator.settings
        if live != settings { settings = live }
    }
}

/// The row of small tabs across the top.
private struct TabStrip: View {
    @Binding var selection: PreferencesView.Tab

    var body: some View {
        // Scrollable: there are eleven tabs, and a plain HStack silently clips
        // the last of them at narrower window widths, making those pages
        // unreachable.
        ScrollView(.horizontal, showsIndicators: false) {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(PreferencesView.Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selection == tab
                                      ? Color.accentColor.opacity(0.85)
                                      : Color.clear))
                        .foregroundStyle(selection == tab ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            // No trailing Spacer: inside a horizontal ScrollView it claims
            // infinite width and the strip stops laying out correctly.
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Binding var settings: Settings
    let rotator: Rotator
    @State private var selection: Source.ID?
    @State private var showingAdd = false

    var body: some View {
        // Scrollable: this tab is taller than the window, and content clipped
        // off the bottom is content the user will never find.
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("General").font(.headline)
                Spacer()
                Toggle("Use Internet Access", isOn: $settings.internetEnabled)
                    .toggleStyle(.switch)
            }

            Toggle("Start Variety when the computer starts", isOn: Binding(
                get: { settings.startAtLogin },
                set: { want in
                    // Reflect what macOS actually did — it can refuse if the
                    // user disabled the item in System Settings.
                    settings.startAtLogin = LoginItem.set(want) ? want : LoginItem.isEnabled
                }))
            .disabled(!LoginItem.isAvailable)

            Divider()

            RotationSection(settings: $settings, rotator: rotator)

            Divider()

            Text("Images").font(.headline)
            SourceTable(settings: $settings, selection: $selection, showingAdd: $showingAdd)

            Divider()

            HStack {
                Text("Copy favorite wallpapers to")
                FolderField(path: $settings.favoritesFolder)
            }
        }
        .padding()
    }
}

/// The Images table: every origin in one list, exactly as Variety presents it.
private struct SourceTable: View {
    @Binding var settings: Settings
    @Binding var selection: Source.ID?
    @Binding var showingAdd: Bool
    @State private var editing: Source?
    @State private var showingSearch = false

    private var selected: Source? {
        settings.sources.first { $0.id == selection }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Table(of: Source.self, selection: $selection) {
                TableColumn("Enabled") { source in
                    Toggle("", isOn: binding(for: source).enabled).labelsHidden()
                }
                .width(60)

                TableColumn("Type") { source in
                    Text(source.kind.rawValue)
                }
                .width(90)

                TableColumn("Location") { source in
                    Text(source.displayLocation).lineLimit(1)
                }
            } rows: {
                ForEach(settings.sources) { TableRow($0) }
            }
            .frame(height: 190)

            VStack(spacing: 6) {
                Button("Search…") { showingSearch = true }
                Button("Add…") { showingAdd = true }
                Button("Open Folder") { openFolder() }
                    .disabled(selected.map { !isFolderish($0) } ?? true)
                Button("Edit…") { editing = selected }
                    .disabled(selected.map { !$0.kind.isEditable } ?? true)
                Button("Remove") { remove() }
                    .disabled(selected.map { !$0.kind.isRemovable } ?? true)
            }
            .frame(width: 110)
        }
        .sheet(isPresented: $showingAdd) {
            AddSourceSheet { new in
                settings.sources.append(new)
                showingAdd = false
            } cancel: { showingAdd = false }
        }
        .sheet(isPresented: $showingSearch) {
            ImageSearchView(settings: settings) { new in
                if !settings.sources.contains(where: { $0.id == new.id }) {
                    settings.sources.append(new)
                }
                showingSearch = false
            }
            .overlay(alignment: .topTrailing) {
                Button("Close") { showingSearch = false }
                    .padding(10)
            }
        }
        .sheet(item: $editing) { source in
            AddSourceSheet(editing: source) { updated in
                if let index = settings.sources.firstIndex(where: { $0.id == source.id }) {
                    // Preserve the enabled state; the sheet only edits the target.
                    settings.sources[index].kind = updated.kind
                    settings.sources[index].location = updated.location
                }
                editing = nil
            } cancel: { editing = nil }
        }
    }

    private func binding(for source: Source) -> Binding<Source> {
        guard let index = settings.sources.firstIndex(where: { $0.id == source.id }) else {
            return .constant(source)
        }
        return $settings.sources[index]
    }

    private func isFolderish(_ source: Source) -> Bool {
        [.folder, .favorites, .fetched].contains(source.kind)
    }

    private func openFolder() {
        guard let selected else { return }
        let url: URL
        switch selected.kind {
        case .favorites: url = settings.favoritesFolderURL
        case .fetched: url = settings.fetchedFolderURL
        default: url = settings.expand(selected.location)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func remove() {
        settings.sources.removeAll { $0.id == selection }
        selection = nil
    }
}

private struct AddSourceSheet: View {
    var add: (Source) -> Void
    var cancel: () -> Void

    @State private var kind: Source.Kind
    @State private var location: String
    private let isEditing: Bool

    init(editing: Source? = nil, add: @escaping (Source) -> Void, cancel: @escaping () -> Void) {
        self.add = add
        self.cancel = cancel
        _kind = State(initialValue: editing?.kind ?? .folder)
        _location = State(initialValue: editing?.location ?? "")
        isEditing = editing != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit image source" : "Add an image source").font(.headline)

            Picker("Type", selection: $kind) {
                ForEach(SourceRegistry.addableKinds, id: \.0) { kind, label in
                    Text(label).tag(kind)
                }
            }
            .disabled(isEditing)

            if kind == .folder || kind == .image {
                HStack {
                    TextField("Path", text: $location)
                    Button("Choose…") { choose() }
                }
            } else if kind.isEditable {
                TextField(placeholder, text: $location)
            } else {
                Text("No configuration needed.").foregroundStyle(.secondary)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(isEditing ? "Save" : "Add") {
                    add(Source(enabled: true, kind: kind, location: location))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 460)
    }

    /// A path source has to point at something that exists. Without this a
    /// search term typed into the default "Folder of images" row becomes a
    /// source pointing at a folder that was never there, which then silently
    /// contributes nothing.
    private var pathExists: Bool {
        var isDirectory: ObjCBool = false
        let expanded = (location as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        else { return false }
        return kind == .folder ? isDirectory.boolValue : !isDirectory.boolValue
    }

    private var isValid: Bool {
        switch kind {
        case .folder, .image: return !location.isEmpty && pathExists
        case .artstation, .unsplash: return true          // blank means Trending / random
        case .wallhaven, .reddit, .mediarss: return !location.isEmpty
        default: return true
        }
    }

    private var validationMessage: String? {
        guard !location.isEmpty else { return nil }
        switch kind {
        case .folder where !pathExists:
            return "No folder at that path. To search a website for “\(location)”, use Search instead."
        case .image where !pathExists:
            return "No file at that path."
        default: return nil
        }
    }

    private var placeholder: String {
        switch kind {
        case .wallhaven: return "Search query, e.g. nature"
        case .reddit: return "Subreddit, e.g. EarthPorn"
        case .mediarss: return "Feed URL"
        case .unsplash: return "Search query (optional)"
        case .artstation: return "Username (blank for Trending)"
        default: return "Location"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind == .image
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { location = url.path }
    }
}

// MARK: - Wallpaper

private struct WallpaperTab: View {
    @Binding var settings: Settings

    private var mode: DisplayMode {
        DisplayMode(rawValue: settings.wallpaperDisplayMode) ?? .os
    }

    var body: some View {
        ScrollView { form }
    }

    private var form: some View {
        Form {
            Section("Alignment and scaling") {
                Toggle("Auto-rotate the image according to EXIF data",
                       isOn: $settings.wallpaperAutoRotate)

                Picker("Display mode", selection: Binding(
                    get: { mode },
                    set: { settings.wallpaperDisplayMode = $0.rawValue })) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)

                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar icon") {
                Picker("Tint", selection: $settings.icon) {
                    Text("Automatic").tag("Auto")
                    Text("Light (for dark menu bars)").tag("Light")
                    Text("Dark (for light menu bars)").tag("Dark")
                }
                .pickerStyle(.inline)
            }

            Section("Transition") {
                Picker("Fade between wallpapers", selection: $settings.wallpaperFade) {
                    ForEach(FadeSpeed.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)

                Text("macOS cross-fades once per change and offers no control over it. Anything beyond the system default is animated by Variety itself, in a layer between the wallpaper and your desktop icons, at your display's refresh rate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Also set the lock screen wallpaper", isOn: $settings.changeLockScreen)
                Text("macOS ties the lock screen to the desktop wallpaper for the logged-in user, so this has no separate effect here. Kept for parity with the Linux build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Quotes

private struct QuotesTab: View {
    @Binding var settings: Settings

    var body: some View {
        ScrollView {
            Form {
                Toggle("Show random wise quotes on the desktop", isOn: $settings.quotesEnabled)

                Section("Appearance") {
                    ColorRow(label: "Text color", rgb: $settings.quotesTextColor)
                    FontRow(label: "Text font", description: $settings.quotesFont)
                    Toggle("Draw a text shadow", isOn: $settings.quotesTextShadow)
                    ColorRow(label: "Backdrop color", rgb: $settings.quotesBgColor)
                    SliderRow(label: "Backdrop opacity", value: $settings.quotesBgOpacity,
                              range: 0...100, low: "Transparent", high: "Opaque")
                }

                Section("Placement") {
                    SliderRow(label: "Horizontal position", value: $settings.quotesHpos,
                              range: 0...100, low: "Left", high: "Right")
                    SliderRow(label: "Vertical position", value: $settings.quotesVpos,
                              range: 0...100, low: "Top", high: "Bottom")
                    SliderRow(label: "Quotes area width", value: $settings.quotesWidth,
                              range: 10...100, low: "Narrow", high: "Wide")
                }

                Section("Sources and filtering") {
                    ForEach(QuoteProvider.allSourceNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { !settings.quotesDisabledSources.contains(name) },
                            set: { on in
                                if on { settings.quotesDisabledSources.removeAll { $0 == name } }
                                else if !settings.quotesDisabledSources.contains(name) {
                                    settings.quotesDisabledSources.append(name)
                                }
                            }))
                    }
                    TextField("Tags (comma separated)", text: $settings.quotesTags)
                    TextField("Authors (comma separated)", text: $settings.quotesAuthors)
                    Stepper("Maximum length: \(settings.quotesMaxLength) characters",
                            value: $settings.quotesMaxLength, in: 50...1000, step: 25)
                }

                Section {
                    HStack {
                        Toggle("Change quote every", isOn: $settings.quotesChangeEnabled)
                        IntervalField(seconds: $settings.quotesChangeInterval)
                            .disabled(!settings.quotesChangeEnabled)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .disabled(!settings.quotesEnabled && false)
    }
}

// MARK: - Clock

private struct ClockTab: View {
    @Binding var settings: Settings

    var body: some View {
        ScrollView { form }
    }

    private var form: some View {
        Form {
            Toggle("Show a clock on the desktop", isOn: $settings.clockEnabled)

            Section("Fonts") {
                FontRow(label: "Clock font", description: $settings.clockFont)
                FontRow(label: "Date font", description: $settings.clockDateFont)
            }

            Section("Format") {
                TextField("Time format", text: $settings.clockTimeFormat)
                TextField("Date format", text: $settings.clockDateFormat)
                Text("Unicode date patterns, e.g. HH:mm and EEEE, d MMMM.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Position") {
                Stepper("Distance from right edge: \(settings.clockHorizontalOffset) px",
                        value: $settings.clockHorizontalOffset, in: 0...2000, step: 10)
                Stepper("Distance from bottom edge: \(settings.clockVerticalOffset) px",
                        value: $settings.clockVerticalOffset, in: 0...2000, step: 10)
            }

            if settings.clockEnabled {
                Text("The clock redraws the wallpaper every minute. macOS caches wallpapers by file path, so each redraw writes a new file; old ones are cleaned up automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Slideshow

private struct SlideshowTab: View {
    @Binding var settings: Settings

    var body: some View {
        ScrollView { form }
    }

    private var form: some View {
        Form {
            Section("Use images from") {
                Toggle("All enabled sources", isOn: $settings.slideshowSourcesEnabled)
                Toggle("Favorites", isOn: $settings.slideshowFavoritesEnabled)
                Toggle("Downloads", isOn: $settings.slideshowDownloadsEnabled)
                Toggle("A custom folder", isOn: $settings.slideshowCustomEnabled)
                if settings.slideshowCustomEnabled {
                    FolderField(path: $settings.slideshowCustomFolder)
                }
            }

            Section("Playback") {
                Picker("Order", selection: $settings.slideshowSortOrder) {
                    ForEach(["Random", "Name", "Date"], id: \.self) { Text($0) }
                }
                Picker("Mode", selection: $settings.slideshowMode) {
                    ForEach(["Fullscreen", "Desktop", "Window"], id: \.self) { Text($0) }
                }
                Picker("Monitor", selection: $settings.slideshowMonitor) {
                    Text("All").tag("All")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, _ in
                        Text("Monitor \(index + 1)").tag("\(index + 1)")
                    }
                }
            }

            Section("Timing and motion") {
                LabeledContent("Seconds per image") {
                    Slider(value: $settings.slideshowSeconds, in: 1...60) {
                        Text("\(Int(settings.slideshowSeconds))s")
                    }
                }
                LabeledContent("Fade") {
                    Slider(value: $settings.slideshowFade, in: 0...2)
                }
                LabeledContent("Zoom") {
                    Slider(value: $settings.slideshowZoom, in: 0...1)
                }
                LabeledContent("Pan") {
                    Slider(value: $settings.slideshowPan, in: 0...1)
                }
                Text("Zoom and pan together produce the slow drift known as the Ken Burns effect. Set both to zero for still images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Downloading

private struct DownloadingTab: View {
    @Binding var settings: Settings

    var body: some View {
        ScrollView { form }
    }

    private var form: some View {
        Form {
            Section("Folders") {
                LabeledContent("Download to") { FolderField(path: $settings.downloadFolder) }
                LabeledContent("Fetched") { FolderField(path: $settings.fetchedFolder) }
            }

            Section("Quota") {
                Toggle("Limit the size of the download folder", isOn: $settings.quotaEnabled)
                Stepper("Keep at most \(settings.quotaSize) MB",
                        value: $settings.quotaSize, in: 100...100_000, step: 100)
                    .disabled(!settings.quotaEnabled)
            }

            Section("Balance") {
                LabeledContent("Prefer freshly downloaded images") {
                    Slider(value: $settings.downloadPreferenceRatio, in: 0...1)
                }
                Text("At 0 the rotation only uses your local folders; at 1 it only uses downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Accounts") {
                CredentialField(
                    title: "Unsplash access key",
                    prompt: "paste your Access Key here",
                    value: $settings.unsplashAccessKey,
                    help: "photography, not digital art",
                    link: ("Register a free app",
                           URL(string: "https://unsplash.com/oauth/applications")!))

                CredentialField(
                    title: "Wallhaven API key",
                    prompt: "optional",
                    value: $settings.wallhavenAPIKey,
                    help: "only needed for NSFW and your own collections",
                    link: ("Get key", URL(string: "https://wallhaven.cc/settings/account")!))

                CredentialField(
                    title: "Reddit client ID",
                    prompt: "from a script app",
                    value: $settings.redditClientID,
                    link: ("reddit.com/prefs/apps",
                           URL(string: "https://www.reddit.com/prefs/apps")!))

                CredentialField(
                    title: "Reddit secret",
                    prompt: "",
                    value: $settings.redditClientSecret,
                    help: "Reddit stopped serving anonymous requests in 2023")
            }

            Section {
                Toggle("Safe mode (SFW content only)", isOn: $settings.safeMode)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Filtering

private struct FilteringTab: View {
    @Binding var settings: Settings

    var body: some View {
        ScrollView { form }
    }

    private var form: some View {
        Form {
            Section("Your display") {
                LabeledContent("Detected") { Text(ScreenGeometry.description) }
                Text("Sources are queried for images at least this large, so downloads fit without upscaling. The filters below narrow it further.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Only use landscape images", isOn: $settings.useLandscapeEnabled)
            }

            Section {
                Toggle("Only images at least this big", isOn: $settings.minSizeEnabled)
                Stepper("\(settings.minSize)% of the screen size",
                        value: $settings.minSize, in: 10...200, step: 5)
                    .disabled(!settings.minSizeEnabled)
            }

            Section {
                Toggle("Only images of this lightness", isOn: $settings.lightnessEnabled)
                Picker("Lightness", selection: $settings.lightnessMode) {
                    ForEach(LightnessMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(!settings.lightnessEnabled)
            }

            Section {
                Toggle("Only images close to a colour", isOn: $settings.desiredColorEnabled)
                ColorRow(label: "Desired colour", rgb: Binding(
                    get: { settings.desiredColor ?? [128, 128, 128] },
                    set: { settings.desiredColor = $0 }))
                    .disabled(!settings.desiredColorEnabled)
            }

            Section {
                Toggle("Only filenames matching a pattern", isOn: $settings.nameRegexEnabled)
                TextField("Regular expression", text: $settings.nameRegex)
                    .disabled(!settings.nameRegexEnabled)
            }

            Section {
                Toggle("Only images rated at least", isOn: $settings.minRatingEnabled)
                Stepper("\(settings.minRating) stars",
                        value: $settings.minRating, in: 1...5)
                    .disabled(!settings.minRatingEnabled)
                Text("Ratings come from EXIF metadata, which most downloaded wallpapers do not carry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Effects

private struct CustomizeTab: View {
    @Binding var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Randomly apply these effects to the displayed wallpapers:")
                .font(.callout)

            List {
                ForEach($settings.filters) { $filter in
                    Toggle(filter.name, isOn: $filter.enabled)
                }
            }

            Text("Variety renders these with ImageMagick. Here they are Core Image equivalents, so they run on the GPU and need no external dependency. The original ImageMagick arguments are kept in the settings file for reference.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Tips / About

private struct TipsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tips, id: \.self) { tip in
                    Text("•  \(tip)")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private let tips = [
        "Use the menu bar icon to move between wallpapers with Next and Previous.",
        "Press the Favorites item to keep an image — favourites are never deleted by the download quota.",
        "Delete to Trash also tells the source never to offer that image again.",
        "Add your own folders under General → Images. Local folders and web sources are treated the same way.",
        "The Wallpaper Selector shows everything available at once; the filmstrip along the bottom shows what is recent.",
        "Effects apply to one wallpaper at a time, chosen at random from the ones you enable.",
        "Turning off Use Internet Access stops all downloading without losing your source configuration.",
    ]
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Variety for macOS").font(.title2)
            Text("A native reimplementation of Variety, the wallpaper manager for Linux by Peter Levi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/varietywalls/variety",
                 destination: URL(string: "https://github.com/varietywalls/variety")!)
            Link("github.com/kamenlevi/variety-v2",
                 destination: URL(string: "https://github.com/kamenlevi/variety-v2")!)
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - Shared controls

/// Variety's "every N hours/minutes" pair.
private struct IntervalField: View {
    @Binding var seconds: TimeInterval

    private enum Unit: String, CaseIterable {
        case seconds, minutes, hours, days
        var factor: TimeInterval {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86400
            }
        }
    }

    /// Chooses the largest unit that divides evenly, so 3600 shows as "1 hours"
    /// rather than "3600 seconds".
    private var unit: Unit {
        for candidate in [Unit.days, .hours, .minutes] where seconds >= candidate.factor
            && seconds.truncatingRemainder(dividingBy: candidate.factor) == 0 {
            return candidate
        }
        return .seconds
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(
                get: { Int(seconds / unit.factor) },
                set: { seconds = TimeInterval(max(1, $0)) * unit.factor }),
                       format: .number)
                .frame(width: 60)

            Picker("", selection: Binding(
                get: { unit },
                set: { newUnit in
                    let amount = max(1, Int(seconds / unit.factor))
                    seconds = TimeInterval(amount) * newUnit.factor
                })) {
                ForEach(Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }
}

private struct FolderField: View {
    @Binding var path: String

    var body: some View {
        HStack {
            TextField("", text: $path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
        }
    }
}

private struct ColorRow: View {
    let label: String
    @Binding var rgb: [Int]

    var body: some View {
        LabeledContent(label) {
            ColorPicker("", selection: Binding(
                get: {
                    Color(.sRGB,
                          red: Double(rgb.count > 0 ? rgb[0] : 255) / 255,
                          green: Double(rgb.count > 1 ? rgb[1] : 255) / 255,
                          blue: Double(rgb.count > 2 ? rgb[2] : 255) / 255)
                },
                set: { colour in
                    let ns = NSColor(colour).usingColorSpace(.sRGB) ?? .white
                    rgb = [Int(ns.redComponent * 255),
                           Int(ns.greenComponent * 255),
                           Int(ns.blueComponent * 255)]
                }))
            .labelsHidden()
        }
    }
}

/// Variety stores fonts as Pango descriptions ("Serif 30"); this edits the
/// family and size separately and writes that form back out.
private struct FontRow: View {
    let label: String
    @Binding var description: String

    private var family: String {
        let parts = description.split(separator: " ").map(String.init)
        guard let last = parts.last, Double(last) != nil else { return description }
        return parts.dropLast().joined(separator: " ")
    }
    private var size: Int {
        Int(description.split(separator: " ").last.flatMap { Double($0) } ?? 30)
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                TextField("Family", text: Binding(
                    get: { family },
                    set: { description = "\($0) \(size)" }))
                    .frame(width: 160)
                TextField("", value: Binding(
                    get: { size },
                    set: { description = "\(family) \($0)" }),
                          format: .number)
                    .frame(width: 50)
            }
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                Slider(value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0) }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
            }
            HStack {
                Text(low); Spacer(); Text(high)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

extension Settings: Equatable {
    /// Encoded comparison: with ninety options, an explicit field-by-field
    /// equality check is a standing invitation to forget one — which would
    /// silently stop that option from taking effect when changed.
    static func == (a: Settings, b: Settings) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }
}
