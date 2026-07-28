import AppKit
import SwiftUI

/// A labelled secret entry row.
///
/// Not `LabeledContent { SecureField(...) }`: inside a grouped `Form` that
/// sizes the control to its intrinsic width, and a `SecureField` has almost
/// none, so it renders as an unusable sliver a few points wide. The label and
/// field are laid out explicitly here with a real width instead.
struct CredentialField: View {

    let title: String
    let prompt: String
    @Binding var value: String
    var help: String?
    var link: (label: String, url: URL)?

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(width: 140, alignment: .leading)

                Group {
                    if revealed {
                        TextField(prompt, text: $value)
                    } else {
                        SecureField(prompt, text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Show")

                // Pasting a key copied from a browser is the whole workflow, so
                // it gets a button rather than relying on focus being right.
                Button("Paste") {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        value = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                if !value.isEmpty {
                    Button("Clear") { value = "" }
                }
            }

            HStack(spacing: 6) {
                if !value.isEmpty {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let link {
                    Link(link.label, destination: link.url).font(.caption)
                }
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 148)
        }
        .padding(.vertical, 2)
    }
}
