import SwiftUI

/// Stands in for Variety's 1,300-line GTK preferences dialog.
///
/// Deliberately much smaller: the options that shipped in Variety but only
/// existed to paper over desktop-environment differences on Linux have no
/// counterpart here, and the wallpaper-setting script hooks are gone because
/// there is exactly one way to set a wallpaper on macOS.
struct SettingsView: View {

    @State var settings: Settings
    let onChange: (Settings) -> Void

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            sources.tabItem { Label("Sources", systemImage: "square.stack.3d.up") }
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 560, height: 520)
        .onChange(of: settings) { _, new in onChange(new) }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Picker("Change wallpaper", selection: $settings.changeIntervalSeconds) {
                Text("Every minute").tag(TimeInterval(60))
                Text("Every 5 minutes").tag(TimeInterval(300))
                Text("Every 10 minutes").tag(TimeInterval(600))
                Text("Every 30 minutes").tag(TimeInterval(1800))
                Text("Every hour").tag(TimeInterval(3600))
                Text("Every day").tag(TimeInterval(86400))
            }

            Toggle("Change on wake from sleep", isOn: $settings.changeOnWake)
            Toggle("Change on login", isOn: $settings.changeOnLogin)
            Toggle("Pause rotation", isOn: $settings.paused)

            Divider()

            LabeledContent("Downloads") {
                Text(settings.downloadFolder).foregroundStyle(.secondary)
            }
            LabeledContent("Favorites") {
                Text(settings.favoritesFolder).foregroundStyle(.secondary)
            }

            Stepper("Keep \(settings.keepDownloaded) downloaded images",
                    value: $settings.keepDownloaded, in: 20...2000, step: 20)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sources

    private var sources: some View {
        Form {
            Section("Ready to use") {
                sourceToggle("bing", "Bing Photo of the Day")
                sourceToggle("earthview", "Google Earth View")
                sourceToggle("apod", "NASA Astronomy Picture of the Day")
                sourceToggle("wallhaven", "Wallhaven")
                sourceToggle("artstation", "ArtStation Trending")
            }

            Section("Needs an account") {
                // Both of these were open when Variety was written and have
                // since closed off, so they are separated out rather than
                // appearing broken alongside the working sources.
                LabeledContent("Unsplash access key") {
                    SecureField("from unsplash.com/developers",
                                text: binding(\.unsplashAccessKey))
                }
                LabeledContent("Wallhaven API key") {
                    SecureField("optional — needed for NSFW",
                                text: binding(\.wallhavenAPIKey))
                }
                LabeledContent("Reddit client ID") {
                    SecureField("from reddit.com/prefs/apps", text: binding(\.redditClientID))
                }
                LabeledContent("Reddit secret") {
                    SecureField("", text: binding(\.redditClientSecret))
                }
                Text("Reddit stopped serving anonymous requests in 2023; a free script app restores access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func sourceToggle(_ id: String, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { settings.enabledSourceIDs.contains(id) },
            set: { on in
                if on {
                    if !settings.enabledSourceIDs.contains(id) { settings.enabledSourceIDs.append(id) }
                } else {
                    settings.enabledSourceIDs.removeAll { $0 == id }
                }
            }))
    }

    /// Optional strings need a non-optional binding for the text fields; empty
    /// is stored as nil so "unset" and "set to empty" stay the same thing.
    private func binding(_ keyPath: WritableKeyPath<Settings, String?>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] ?? "" },
            set: { settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Appearance

    private var appearance: some View {
        Form {
            Picker("Fit to screen", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Show a quote on the wallpaper", isOn: $settings.quotesEnabled)
            Toggle("Show a clock on the wallpaper", isOn: $settings.clockEnabled)

            if settings.clockEnabled {
                Text("The clock redraws the wallpaper every minute. macOS caches wallpapers by file path, so each redraw writes a new file; old ones are cleaned up automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

extension Settings: Equatable {
    static func == (a: Settings, b: Settings) -> Bool {
        a.changeIntervalSeconds == b.changeIntervalSeconds
            && a.changeOnWake == b.changeOnWake
            && a.changeOnLogin == b.changeOnLogin
            && a.paused == b.paused
            && a.enabledSourceIDs == b.enabledSourceIDs
            && a.wallhavenAPIKey == b.wallhavenAPIKey
            && a.unsplashAccessKey == b.unsplashAccessKey
            && a.redditClientID == b.redditClientID
            && a.redditClientSecret == b.redditClientSecret
            && a.displayMode == b.displayMode
            && a.quotesEnabled == b.quotesEnabled
            && a.clockEnabled == b.clockEnabled
            && a.keepDownloaded == b.keepDownloaded
    }
}
