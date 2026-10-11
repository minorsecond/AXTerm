import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Owner sign-in from the road, in the mailbox settings on the Mac and iOS
/// (Docs/RemoteAccessPlan.md, "Signing in"): the switch, and the code's
/// secret as a QR code for an authenticator app.
struct OwnerAccessSection: View {
    @ObservedObject var settings: BBSSettings
    /// The mailbox's callsign, for the authenticator's label.
    let mailboxCallsign: String

    @State private var secret: Data?
    @State private var confirmsNewCode = false

    var body: some View {
        Section {
            Toggle("Sign in from the road with a one-time code", isOn: $settings.ownerCommandsEnabled)
            Text("Calling this mailbox on your own callsign, type OWNER and the six-digit code from an "
                 + "authenticator app to open ST, the station's state. The code goes out in plain text "
                 + "with the command, which hides nothing and is allowed on the air, and it works once. "
                 + "Three wrong codes stop sign-in for 15 minutes. Every attempt shows in the call log.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.ownerCommandsEnabled {
                if let secret {
                    let link = OwnerCode.setupLink(secret: secret, station: mailboxCallsign)
                    if let qr = Self.qrImage(for: link) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 160, height: 160)
                            .accessibilityLabel("QR code for your authenticator app")
                    }
                    Text("Scan it with an authenticator app, or enter this key: "
                         + Self.grouped(OwnerCode.base32(secret)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Make a New Code\u{2026}") { confirmsNewCode = true }
                } else {
                    Button("Set Up the Code") { secret = OwnerCodeSecretStore().replace() }
                }
            }
        } header: {
            Text("Owner sign-in")
        }
        .onAppear { secret = OwnerCodeSecretStore().read() }
        .confirmationDialog("Make a new code?", isPresented: $confirmsNewCode) {
            Button("Make a New Code", role: .destructive) { secret = OwnerCodeSecretStore().replace() }
        } message: {
            Text("The code in your authenticator app stops working. Scan the new one before you leave.")
        }
    }

    private static func grouped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { start in
            let from = key.index(key.startIndex, offsetBy: start)
            let to = key.index(from, offsetBy: min(4, key.count - start))
            return String(key[from..<to])
        }.joined(separator: " ")
    }

    private static func qrImage(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
