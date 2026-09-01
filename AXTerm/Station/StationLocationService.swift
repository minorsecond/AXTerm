import Foundation
import Combine
import CoreLocation

/// One-shot GPS access, abstracted so tests can inject positions and so
/// the service degrades cleanly when CoreLocation is denied.
protocol GPSProviding: Sendable {
    /// Resolves a single fix, or throws when unavailable/denied/timeout.
    func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double)
}

nonisolated enum GPSError: Error, Equatable {
    case denied
    case timeout
    case unavailable(String)
}

/// The app-wide source of "where am I": tries GPS (CoreLocation) and
/// falls back to the center of the operator's configured grid square.
///
/// Portable by design — Winlink compose, forms, position reports, and
/// the terminal all pull from here.
@MainActor
final class StationLocationService: ObservableObject {

    @Published private(set) var lastLocation: StationLocation?
    @Published private(set) var isResolving = false
    @Published private(set) var lastGPSError: GPSError?

    private let gps: GPSProviding?
    private let manualGridProvider: () -> String
    private let now: () -> Date

    init(
        gps: GPSProviding? = CoreLocationGPSProvider(),
        manualGridProvider: @escaping () -> String,
        now: @escaping () -> Date = { Date() }
    ) {
        self.gps = gps
        self.manualGridProvider = manualGridProvider
        self.now = now
    }

    /// Best available position: a fresh GPS fix when possible, otherwise
    /// the configured grid square's center. Nil when neither exists.
    func currentLocation(gpsTimeout: TimeInterval = 8) async -> StationLocation? {
        isResolving = true
        defer { isResolving = false }

        if let gps {
            do {
                let fix = try await gps.requestOneShotFix(timeout: gpsTimeout)
                let grid = Maidenhead.gridSquare(latitude: fix.latitude, longitude: fix.longitude) ?? ""
                let location = StationLocation(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    gridSquare: grid,
                    source: .gps,
                    timestamp: now())
                lastGPSError = nil
                lastLocation = location
                return location
            } catch let error as GPSError {
                lastGPSError = error
            } catch {
                lastGPSError = .unavailable(String(describing: error))
            }
        }

        if let manual = manualLocation() {
            lastLocation = manual
            return manual
        }
        return nil
    }

    /// The configured grid square's center, without touching GPS.
    func manualLocation() -> StationLocation? {
        let grid = manualGridProvider()
        guard let center = Maidenhead.center(of: grid) else { return nil }
        return StationLocation(
            latitude: center.latitude,
            longitude: center.longitude,
            gridSquare: grid,
            source: .manualGrid,
            timestamp: now())
    }
}

// MARK: - CoreLocation provider

/// Real GPS via CoreLocation (Wi-Fi positioning on most Macs).
// Nonisolated: it is already `@unchecked Sendable` and guards its own
// state, and it is used as a default argument, which is evaluated in the
// caller's context rather than this type's.
nonisolated final class CoreLocationGPSProvider: NSObject, GPSProviding, CLLocationManagerDelegate, @unchecked Sendable {

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double), Error>?
    private let lock = NSLock()

    func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
        // The timeout must resume the continuation itself. A task-group race
        // can't: cancelling a task suspended on a checked continuation leaves
        // it suspended, and CoreLocation can go permanently silent (locationd
        // "registration timer expired") without ever calling the delegate —
        // which left callers awaiting forever.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.lock.lock()
                if self.continuation != nil {
                    // An earlier fix is still pending; don't orphan it.
                    self.lock.unlock()
                    continuation.resume(throwing: GPSError.unavailable("a GPS fix is already in progress"))
                    return
                }
                self.continuation = continuation
                self.lock.unlock()

                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.manager = manager

                switch manager.authorizationStatus {
                case .denied, .restricted:
                    self.finish(.failure(GPSError.denied))
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()
                    // A location request while undetermined queues
                    // behind the authorization prompt.
                    manager.requestLocation()
                default:
                    manager.requestLocation()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    // No-op if the delegate already resolved the fix.
                    self.finish(.failure(GPSError.timeout))
                }
            }
        }
    }

    private func finish(_ result: Result<(latitude: Double, longitude: Double), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success(let fix): continuation?.resume(returning: fix)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(.success((location.coordinate.latitude, location.coordinate.longitude)))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            finish(.failure(GPSError.denied))
        } else {
            finish(.failure(GPSError.unavailable(error.localizedDescription)))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(.failure(GPSError.denied))
        case .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }
}
