import SwiftUI

/// The link to the TNC, visible from wherever the operator happens to be.
///
/// A packet terminal whose radio link has dropped looks exactly like a quiet
/// channel: no error, no packets, nothing. On a Mac the toolbar carries this
/// permanently, but the iOS shell showed it only on the Terminal tab, so an
/// operator reading mail or a map had no way to know the station had gone
/// deaf.
///
/// Graded rather than uniform, because a status line that shouts when
/// everything is fine trains people to stop reading it:
///
/// - **Connected** is nearly silent — a small green dot and nothing else. The
///   normal case earns the least ink.
/// - **Connecting** is muted, and says so, because a pause needs explaining
///   before it needs fixing.
/// - **Not connected** and **failed** are the ones worth interrupting for, so
///   they carry words and colour, and offer the fix.
///
/// Tapping anywhere on it opens the radio's settings — the strip states a
/// problem, so it also has to lead somewhere.
struct TNCStatusStrip: View {
    let status: ConnectionStatus
    let host: String
    let port: Int
    /// Every radio, when there are several; the one-radio init leaves this
    /// empty and the strip reads exactly as it always has.
    var radios: [RadioStatusSummary] = []

    init(status: ConnectionStatus, host: String, port: Int) {
        self.status = status
        self.host = host
        self.port = port
    }

    /// One dot per radio, one line about whichever needs attention.
    init(radios: [RadioStatusSummary]) {
        self.radios = radios
        self.status = RadioPresentation.aggregateStatus(radios.map(\.status))
        self.host = radios.first?.host ?? ""
        self.port = radios.first?.port ?? 0
    }

    var body: some View {
        HStack(spacing: 6) {
            if radios.count > 1 {
                HStack(spacing: 3) {
                    ForEach(radios, id: \.id) { radio in
                        Circle()
                            .fill(Self.tint(for: radio.status))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }

            if let label {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(needsAttention ? tint : .secondary)
            }

            if needsAttention {
                Spacer(minLength: 4)
                Text("Connection")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, needsAttention ? 6 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A plain background.
        //
        // This used to bleed a `Rectangle().ignoresSafeArea(edges: .bottom)`
        // so the material reached the physical bottom edge with no dead chin
        // below it. The strip is not the last thing on screen any more — the
        // tab bar sits below it — so there is no chin to fill, and a plain
        // background is what a bar between two things should have.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { SettingsRouter.shared.navigate(to: .radios) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens Radio settings")
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var needsAttention: Bool {
        radios.count > 1 ? Presentation.needsAttention(radios) : Presentation.needsAttention(status)
    }
    private var label: String? {
        radios.count > 1 ? Presentation.label(radios) : Presentation.label(status)
    }
    private var accessibilityText: String {
        radios.count > 1 ? Presentation.spoken(radios) : Presentation.spoken(status, host: host, port: port)
    }

    private var tint: Color { Self.tint(for: status) }

    private static func tint(for status: ConnectionStatus) -> Color {
        switch status {
        case .connected: .green
        case .connecting: .secondary
        case .disconnected: .orange
        case .failed: .red
        }
    }

    /// The strip's decisions, free of SwiftUI so they can be tested.
    ///
    /// What this thing says is the whole point of it — a status line that
    /// shouts when everything is fine trains people to stop reading it, and
    /// one that stays quiet when the link is down defeats its own purpose.
    nonisolated enum Presentation {

        /// Whether this state is worth the operator's attention. Drives how
        /// much room and colour the strip takes.
        static func needsAttention(_ status: ConnectionStatus) -> Bool {
            switch status {
            case .disconnected, .failed: true
            case .connected, .connecting: false
            }
        }

        /// Nothing at all when connected: the dot alone says it, and a working
        /// station should not spend a line of every screen saying so.
        static func label(_ status: ConnectionStatus) -> String? {
            switch status {
            case .connected: nil
            case .connecting: "Connecting to the TNC…"
            case .disconnected: "Not connected to a TNC"
            case .failed: "TNC connection failed"
            }
        }

        /// Spoken aloud the endpoint matters, because there is no toolbar to
        /// glance at for it.
        static func spoken(_ status: ConnectionStatus, host: String, port: Int) -> String {
            let endpoint = host.isEmpty ? "" : " at \(host) port \(port)"
            switch status {
            case .connected: return "Connected to the TNC\(endpoint)"
            case .connecting: return "Connecting to the TNC\(endpoint)"
            case .disconnected: return "Not connected to a TNC\(endpoint)"
            case .failed: return "TNC connection failed\(endpoint)"
            }
        }

        // MARK: Several radios

        /// One radio: exactly the single-radio decisions above, so nothing
        /// changes for the operator who has one. Several: any radio worth
        /// attention makes the strip worth attention.
        static func needsAttention(_ radios: [RadioStatusSummary]) -> Bool {
            guard radios.count > 1 else {
                return needsAttention(radios.first?.status ?? .disconnected)
            }
            return radios.contains { needsAttention($0.status) }
        }

        /// Names the one radio that needs attention, or counts them; the
        /// restraint rule holds — every radio working says nothing.
        static func label(_ radios: [RadioStatusSummary]) -> String? {
            guard radios.count > 1 else { return label(radios.first?.status ?? .disconnected) }
            let down = radios.filter { needsAttention($0.status) }
            if down.count == 1, let one = down.first {
                return one.status == .failed
                    ? "\(one.name) connection failed"
                    : "\(one.name) not connected"
            }
            if down.count > 1 { return "\(down.count) radios not connected" }
            if let connecting = radios.first(where: { $0.status == .connecting }) {
                return "Connecting to \(connecting.name)\u{2026}"
            }
            return nil
        }

        /// Every radio in turn, because there is no other place on the
        /// screen that lists them.
        static func spoken(_ radios: [RadioStatusSummary]) -> String {
            guard radios.count > 1 else {
                let radio = radios.first
                return spoken(radio?.status ?? .disconnected,
                              host: radio?.host ?? "", port: radio?.port ?? 0)
            }
            return radios.map { radio in
                let endpoint = radio.endpoint.isEmpty ? "" : " at \(radio.endpoint)"
                switch radio.status {
                case .connected: return "\(radio.name) connected\(endpoint)"
                case .connecting: return "\(radio.name) connecting\(endpoint)"
                case .disconnected: return "\(radio.name) not connected"
                case .failed: return "\(radio.name) connection failed"
                }
            }.joined(separator: "; ")
        }
    }
}
