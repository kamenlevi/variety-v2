import AppKit
import SwiftUI

/// Variety's Donate tab.
///
/// The destinations are Peter Levi's, copied verbatim from upstream
/// (`data/ui/PreferencesVarietyDialog.ui` and `VarietyWindow.DONATE_URL`) —
/// this is his software's donate page, kept intact in a port of it, exactly as
/// a fork should. Nothing here is invented or redirected.
struct DonateTab: View {

    /// From `VarietyWindow.DONATE_URL`.
    static let payPalURL = URL(string:
        "https://www.paypal.com/donate/?business=DHQUELMQRQW46&no_recurring=0"
        + "&item_name=Variety+Wallpaper+Changer&currency_code=EUR")!

    /// From the `donate_bitcoin_address` field in the preferences UI.
    static let bitcoinAddress = "bc1qgxlvmwe2pj5lvku6vm53edes3q7c3ykta7xyu4"

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Donate to Variety")
                    .font(.title2)

                // Peter Levi's own words from the Donate tab, unchanged.
                Text("""
                    I am developing Variety in my spare time, which usually means \
                    the late hours after my kids go to bed. Any amount you donate \
                    will be appreciated. It will show me Variety is valued by you \
                    — the users — and will motivate me to continue working \
                    actively on it. Thank you, Peter Levi
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)

                Link(destination: Self.payPalURL) {
                    Label("Donate via PayPal", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("To donate in Bitcoin, please send to this wallet:")
                    HStack {
                        // Selectable so the address can be copied by hand as
                        // well as by the button.
                        Text(Self.bitcoinAddress)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))

                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.bitcoinAddress, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                    }
                }

                Divider()

                Text("Donations go to Peter Levi, who wrote Variety. This macOS version is a separate reimplementation and takes nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
