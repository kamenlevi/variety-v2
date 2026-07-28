import SwiftUI

/// How and when the wallpaper changes.
///
/// This was previously one cramped row sharing a line with a checkbox, above a
/// large source table that dominated the tab — easy to miss entirely. Rotation
/// is the app's central setting, so it gets its own block, presets for the
/// common intervals, and a live countdown that makes it obvious the setting has
/// taken effect.
struct RotationSection: View {

    @Binding var settings: Settings
    let rotator: Rotator

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The intervals worth one click. Variety's own default is 5 minutes.
    private static let presets: [(String, TimeInterval)] = [
        ("1 min", 60), ("5 min", 300), ("15 min", 900),
        ("30 min", 1800), ("1 hour", 3600), ("6 hours", 21600), ("1 day", 86400),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Change the wallpaper automatically", isOn: $settings.changeEnabled)
                .font(.headline)

            HStack(spacing: 8) {
                Text("Every")
                IntervalStepper(seconds: $settings.changeInterval)
                Spacer()
            }
            .disabled(!settings.changeEnabled)

            // Presets: one click for the intervals people actually pick.
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.0) { label, seconds in
                    Button(label) { settings.changeInterval = seconds }
                        .buttonStyle(.bordered)
                        .tint(settings.changeInterval == seconds ? .accentColor : nil)
                }
            }
            .controlSize(.small)
            .disabled(!settings.changeEnabled)

            countdown

            Divider().padding(.vertical, 2)

            Toggle("Also change when the app starts", isOn: $settings.changeOnStart)
            Toggle("Also change on waking from sleep", isOn: $settings.changeOnWake)

            Text("macOS cross-fades between wallpapers itself and does not expose a way to change that speed, so there is no transition setting here. The slideshow does have its own fade, zoom and pan controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var countdown: some View {
        if !settings.changeEnabled {
            Label("Rotation is paused — the wallpaper will only change when you ask.",
                  systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if let due = rotator.nextChangeDate {
            let remaining = max(0, due.timeIntervalSince(now))
            Label("Next change in \(Self.format(remaining))", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Label("Next change scheduled when you close Preferences.", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

/// Amount plus unit, as Variety's "Change wallpaper every [7] [hours]".
///
/// Uses a stepper and a bordered field rather than a bare `TextField`, which in
/// a plain stack is easy to overlook entirely.
struct IntervalStepper: View {
    @Binding var seconds: TimeInterval

    enum Unit: String, CaseIterable, Identifiable {
        case seconds, minutes, hours, days
        var id: String { rawValue }
        var factor: TimeInterval {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86400
            }
        }
    }

    /// Largest unit that divides evenly, so 3600 reads "1 hours" not
    /// "3600 seconds".
    private var unit: Unit {
        for candidate in [Unit.days, .hours, .minutes]
        where seconds >= candidate.factor
            && seconds.truncatingRemainder(dividingBy: candidate.factor) == 0 {
            return candidate
        }
        return .seconds
    }

    private var amount: Int { max(1, Int(seconds / unit.factor)) }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(
                get: { amount },
                set: { seconds = TimeInterval(max(1, $0)) * unit.factor }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)

            Stepper("") {
                seconds += unit.factor
            } onDecrement: {
                seconds = max(unit.factor, seconds - unit.factor)
            }
            .labelsHidden()

            Picker("", selection: Binding(
                get: { unit },
                set: { seconds = TimeInterval(amount) * $0.factor })) {
                ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }
}
