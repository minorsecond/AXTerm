import Foundation

/// SailDocs request builder — the classic "internet over Winlink" trick.
///
/// SailDocs (saildocs.com) is a free email robot: send commands to
/// `query@saildocs.com` and it mails back web pages, spot forecasts,
/// text bulletins, or GRIB files. Not a Winlink service, but reachable
/// through the Winlink↔internet gateway, which makes it the de-facto way
/// to pull arbitrary internet data over packet radio.
nonisolated enum SailDocsRequestBuilder {

    static let address = "SMTP:query@saildocs.com"

    enum Request: Equatable, Sendable {
        /// Fetches a web page as plain text: `send <url>`.
        case webPage(url: String)
        /// Text spot forecast for a position: `send spot:<lat>,<lon>`.
        case spotForecast(latitude: Double, longitude: Double)
        /// Raw command line for power users (`send gfs:...` etc.).
        case custom(String)

        var commandLine: String {
            switch self {
            case .webPage(let url):
                return "send \(url.trimmingCharacters(in: .whitespaces))"
            case .spotForecast(let latitude, let longitude):
                let lat = String(format: "%.2f%@", abs(latitude), latitude >= 0 ? "N" : "S")
                let lon = String(format: "%.2f%@", abs(longitude), longitude >= 0 ? "E" : "W")
                return "send spot:\(lat),\(lon)"
            case .custom(let line):
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// Builds the request message. Multiple commands ride one message,
    /// one per line.
    static func buildMessage(requests: [Request], myCallsign: String, now: Date = Date()) -> WinlinkB2Message? {
        let lines = requests.map(\.commandLine).filter { !$0.isEmpty }
        guard !lines.isEmpty, !myCallsign.isEmpty else { return nil }

        return WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: myCallsign),
            date: now,
            type: .privateMessage,
            from: myCallsign,
            to: [address],
            cc: [],
            subject: "SailDocs request",
            mbo: myCallsign,
            body: Data((lines.joined(separator: "\r\n") + "\r\n").utf8),
            attachments: [])
    }
}
