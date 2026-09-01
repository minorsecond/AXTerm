import Combine
import SwiftUI

/// Chooses which of a remote's offered messages to spend airtime on.
///
/// Shown mid-session, with the link up and the remote waiting for the FS
/// line, so the sheet is built around the cost of deciding: a live
/// countdown, a running total of what the current selection will cost, and
/// no way to lose mail by getting it wrong. Everything left unticked is
/// deferred, not refused — the remote keeps it and offers it again.
///
/// What can be shown is fixed by the protocol. A `;PM:` advisory carries
/// sender, recipient and subject; the `FC` proposal carries the byte
/// counts. The body does not cross the air until it is accepted, so there
/// is no preview to offer and no attachment list to read — the subject and
/// the size are the whole of the evidence.
struct WinlinkInboundSelectionSheet: View {

    let request: WinlinkSessionRunner.InboundSelectionRequest
    /// Called exactly once, with the MIDs to download.
    let onDecide: (Set<String>) -> Void

    @State private var selected: Set<String> = []
    @State private var now = Date()

    /// Drives the countdown. One tick a second is plenty and costs nothing
    /// next to the radio traffic underneath it.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            offerList
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640)
        .onAppear {
            // Pre-tick what an unanswered deadline would take anyway, so
            // the default in front of the operator is the default the
            // engine will apply. Confirming is then one click.
            selected = Set(autoAccepted.map(\.mid))
        }
        .onReceive(clock) { now = $0 }
        .interactiveDismissDisabled()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.offers.count == 1
                     ? "1 message waiting"
                     : "\(request.offers.count) messages waiting")
                    .font(.headline)
                Text("at \(request.gatewayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                countdown
            }

            Text(deadlineExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // FBB allows five proposals per block. A gateway holding more
            // sends another block after this one, and asks again — better
            // to say so than to let a second sheet look like a bug.
            if request.offers.count >= B2FProposal.maxProposalsPerBlock {
                Label("A gateway proposes five at a time; more may follow this batch.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var countdown: some View {
        let remaining = max(0, request.deadline.timeIntervalSince(now))
        let urgent = remaining <= 20
        return Label(
            String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60),
            systemImage: "clock")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(urgent ? .red : .secondary)
            .help("The link is open and the gateway is waiting on this answer. Time spent here is time on a shared channel.")
    }

    private var deadlineExplanation: String {
        let threshold = ByteCount.string(Int64(request.autoAcceptUnderBytes))
        return "Unanswered, anything under \(threshold) downloads and the rest stays on the server. "
            + "Nothing you leave unticked is lost — the gateway offers it again next exchange."
    }

    // MARK: - Offers

    /// Sized to its rows, capped so a full block of five still fits on a
    /// laptop screen. A fixed minimum left a single offer floating in a
    /// third of a sheet of nothing.
    private var offerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(request.offers) { offer in
                    OfferRow(
                        offer: offer,
                        airtime: request.airtime,
                        autoAcceptUnderBytes: request.autoAcceptUnderBytes,
                        isSelected: selected.contains(offer.mid),
                        toggle: { toggle(offer.mid) })
                    Divider()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 340)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Select All") { selected = Set(request.offers.map(\.mid)) }
                Button("Select None") { selected = [] }
                if !autoAccepted.isEmpty, autoAccepted.count < request.offers.count {
                    Button("Just the Small Ones") {
                        selected = Set(autoAccepted.map(\.mid))
                    }
                    .help("Everything at or under the size that downloads automatically when this times out.")
                }
                Spacer()
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
            .font(.callout)

            HStack(alignment: .firstTextBaseline) {
                selectionSummary
                Spacer()
                Button("Skip All") { onDecide([]) }
                    .help("Download nothing this session. Everything stays on the server for next time.")
                Button(downloadTitle) { onDecide(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
    }

    private var selectionSummary: some View {
        Group {
            if selected.isEmpty {
                Text("Nothing selected — everything stays on the server.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected.count) selected · \(byteText(selectedBytes)) · about \(request.airtime.airtimeTextOnTheAir(compressedBytes: selectedBytes)) on the air")
                    Text(request.airtime.provenance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private var downloadTitle: String {
        selected.isEmpty
            ? "Download"
            : "Download \(selected.count) (\(request.airtime.airtimeTextOnTheAir(compressedBytes: selectedBytes)))"
    }

    // MARK: - Derived

    /// What the engine would take on its own if this sheet went unanswered.
    private var autoAccepted: [B2FSessionEngine.InboundOffer] {
        request.offers.filter { $0.bytesOnTheAir <= request.autoAcceptUnderBytes }
    }

    private var selectedBytes: Int {
        request.offers.filter { selected.contains($0.mid) }.reduce(0) { $0 + $1.bytesOnTheAir }
    }

    private func toggle(_ mid: String) {
        if selected.contains(mid) { selected.remove(mid) } else { selected.insert(mid) }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCount.string(Int64(bytes))
    }
}

// MARK: - Row

private struct OfferRow: View {

    let offer: B2FSessionEngine.InboundOffer
    let airtime: WinlinkAirtimeEstimate
    let autoAcceptUnderBytes: Int
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) { rowContent }
            .buttonStyle(.plain)
            .accessibilityLabel(subject)
            .accessibilityValue(isSelected ? "Will download" : "Will stay on the server")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// One tap target, one drawn checkbox. A real `Toggle` inside a
    /// tappable row either swallows the row's gesture or fires twice with
    /// it, and neither is acceptable when the countdown is running.
    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(subject)
                    .font(.body.weight(.medium))
                    .foregroundStyle(offer.advisory == nil ? .secondary : .primary)
                    .lineLimit(2)

                Text(correspondents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if offer.resumeFrom > 0 {
                    Label(
                        "Resuming — \(byteText(offer.resumeFrom)) already held, \(byteText(offer.bytesOnTheAir)) to go",
                        systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(airtime.airtimeTextOnTheAir(compressedBytes: offer.bytesOnTheAir))
                    .font(.body.monospacedDigit())
                    // The long ones are the whole reason for asking, so
                    // they are marked rather than left to be inferred from
                    // a number.
                    .foregroundStyle(isCostly ? Color.orange : .primary)
                Text(byteText(offer.bytesOnTheAir))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help(estimateTooltip)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Costs more than an unanswered deadline would spend on its own.
    private var isCostly: Bool { offer.bytesOnTheAir > autoAcceptUnderBytes }

    /// The advisory is the only source of a subject, and a remote need not
    /// have sent one — say so rather than showing a blank line.
    private var subject: String {
        guard let advisory = offer.advisory else { return "Message \(offer.mid)" }
        return advisory.subject.isEmpty ? "(no subject)" : advisory.subject
    }

    /// Field one of `;PM:` is the destination and field four the origin —
    /// the reverse of how the line reads. See `B2FPendingAdvisory`.
    private var correspondents: String {
        guard let advisory = offer.advisory else {
            return "\(offer.mid) — the gateway sent no description"
        }
        return "From \(advisory.origin) · to \(advisory.destination)"
    }

    private var estimateTooltip: String {
        let size = byteText(offer.bytesOnTheAir)
        var text = """
        \(size) compressed, which is what actually crosses the air — \
        the proposal states it exactly, so nothing here is guessed from \
        the \(byteText(offer.uncompressedSize)) of decoded text.

        \(size) ÷ \(WinlinkAirtimeEstimate.rateText(airtime.compressedBytesPerSecond)) — \(airtime.provenance).
        """
        if offer.resumeFrom > 0 {
            text += "\n\nAn interrupted session already left \(byteText(offer.resumeFrom)) here; only the remainder is requested."
        }
        return text
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCount.string(Int64(bytes))
    }
}
