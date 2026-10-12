import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owner sign-in from the road, in Settings › Remote Control on the Mac and iOS
/// (Docs/RemoteAccessPlan.md, "Signing in"): the switch, and the code's
/// secret as a QR code for an authenticator app.
struct OwnerAccessSection: View {
    @ObservedObject var settings: BBSSettings
    /// The mailbox's callsign, for the authenticator's label.
    let mailboxCallsign: String

    @State private var secret: Data?
    @State private var confirmsNewCode = false
    @State private var thisDeviceKey: String?
    @State private var addsDevice = false
    @State private var newDeviceName = ""
    @State private var newDeviceKey = ""

    var body: some View {
        Section {
            Toggle("Sign in from the road with a one-time code", isOn: $settings.ownerCommandsEnabled)
            Text("Calling the mailbox or the node on your own callsign, type OWNER and the six-digit code from an "
                 + "authenticator app to open ST, the station's state. The code goes out in plain text "
                 + "with the command, which hides nothing and is allowed on the air, and it works once. "
                 + "Three wrong codes stop code sign-in for 15 minutes, and each lockout after that "
                 + "is twice as long, up to a week, until a right code. From another AXTerm paired below, "
                 + "Sign In as Owner in the terminal signs in with that device's key instead. Every "
                 + "attempt shows in the call log.")
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

                // Signing in from another AXTerm with a key instead of a code.
                Text("Devices that may sign in with a key")
                    .font(.subheadline)
                if settings.ownerDevices.isEmpty {
                    Text("None yet. On your iPhone or iPad, copy its owner key from this section and add it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(settings.ownerDevices) { device in
                    HStack {
                        Image(systemName: "key")
                        Text(device.name)
                        Spacer()
                        Button("Remove") {
                            settings.ownerDevices.removeAll { $0.publicKey == device.publicKey }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add a Device\u{2026}") { addsDevice = true }
            }
            if let thisDeviceKey {
                Text("This device's owner key, to add to the mailbox at home:")
                    .font(.caption)
                Text(thisDeviceKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy This Device's Key") { Self.copy(thisDeviceKey) }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("Owner sign-in")
        }
        .onAppear {
            secret = OwnerCodeSecretStore().read()
            thisDeviceKey = OwnerDeviceKey().publicKeyText()
        }
        .sheet(isPresented: $addsDevice) { addDeviceSheet }
        .confirmationDialog("Make a new code?", isPresented: $confirmsNewCode) {
            Button("Make a New Code", role: .destructive) { secret = OwnerCodeSecretStore().replace() }
        } message: {
            Text("The code in your authenticator app stops working. Scan the new one before you leave.")
        }
    }

    private var addDeviceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a device").font(.headline)
            TextField("Name, such as iPad", text: $newDeviceName)
            TextField("Its owner key", text: $newDeviceKey, axis: .vertical)
                .font(.caption.monospaced())
                .lineLimit(2...4)
            if !newDeviceKey.isEmpty, OwnerKey.decode(newDeviceKey) == nil {
                Text("That is not an owner key. Copy it again from the device's mailbox settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { resetNewDevice() }
                Button("Add") {
                    let name = newDeviceName.trimmingCharacters(in: .whitespaces)
                    let key = newDeviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !settings.ownerDevices.contains(where: { $0.publicKey == key }) {
                        settings.ownerDevices.append(OwnerKey.PairedDevice(
                            name: name.isEmpty ? "Device \(settings.ownerDevices.count + 1)" : name,
                            publicKey: key))
                    }
                    resetNewDevice()
                }
                .disabled(OwnerKey.decode(newDeviceKey) == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(minWidth: 360)
    }

    private func resetNewDevice() {
        newDeviceName = ""
        newDeviceKey = ""
        addsDevice = false
    }

    private static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
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
