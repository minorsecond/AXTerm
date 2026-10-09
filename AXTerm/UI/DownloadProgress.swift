import Foundation
import MapKit

/// The line under a download button in the Offline Data sheet. Both
/// downloads once looked dead: the region's bar sat off screen at the bottom
/// of the sheet, and terrain showed an empty "0 of 9" while its first
/// multi-megabyte tile came in, then nothing when it ended.
struct DownloadProgress: Equatable {
    let text: String
    /// Nil for a spinner: nothing has landed yet to measure against.
    let fraction: Double?
    var isDone = false

    static func terrain(_ state: ElevationDownloader.State) -> DownloadProgress? {
        switch state {
        case .idle, .failed:
            return nil
        case .downloading(let completed, let total):
            // The tile being fetched, so the count moves as soon as it starts.
            let tile = min(completed + 1, total)
            return DownloadProgress(text: "Fetching terrain tile \(tile) of \(total)…",
                                    fraction: completed == 0 ? nil : Double(completed) / Double(max(total, 1)))
        case .finished(let tiles):
            return DownloadProgress(text: tiles == 0 ? "Already stored. Nothing new to fetch."
                                        : "Stored \(tiles) terrain tile\(tiles == 1 ? "" : "s").",
                                    fraction: 1, isDone: true)
        }
    }

    static func region(_ state: OfflineRegionDownloader.State) -> DownloadProgress? {
        switch state {
        case .idle, .failed, .refused:
            return nil
        case .estimating:
            return DownloadProgress(text: "Working out what is needed…", fraction: nil)
        case .importing:
            return DownloadProgress(text: "Importing…", fraction: nil)
        case .downloading(let completed, let total):
            guard completed > 0 else {
                return DownloadProgress(text: "Starting: \(total.formatted()) tiles to fetch…", fraction: nil)
            }
            return DownloadProgress(text: "\(completed.formatted()) of \(total.formatted()) tiles",
                                    fraction: Double(completed) / Double(max(total, 1)))
        case .finished(let tiles, _):
            return DownloadProgress(text: tiles == 0 ? "Already stored. Nothing new to fetch."
                                        : "Stored \(tiles.formatted()) tiles.",
                                    fraction: 1, isDone: true)
        }
    }
}

extension MapTileSource {
    /// The detail levels worth offering: the source has nothing past its
    /// own top level.
    var offeredZoom: ClosedRange<Int> { 1...maximumZoom }
}

extension OfflineRegionDownloader {
    /// The estimate for what the download will really fetch, which stops at
    /// the source's top level.
    static func estimate(region: MKCoordinateRegion, zoomRange: ClosedRange<Int>, source: MapTileSource) -> Estimate {
        let top = min(zoomRange.upperBound, source.maximumZoom)
        return estimate(region: region, zoomRange: min(zoomRange.lowerBound, top)...top)
    }
}
