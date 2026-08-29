import Foundation

/// The operator's own details, carried between their devices.
///
/// Without this the sync policy is a statement of intent that nothing
/// implements: `callsignBase` and `operatorProfile` are declared syncable and
/// then never leave the machine, so a second device asks for everything from
/// scratch.
///
/// What travels is **the operator**, not the station. The licence callsign,
/// their name, organisation, phone and address — the things an ICS form wants
/// and that are identical on every radio they own. The SSID is excluded on
/// purpose (see `WinlinkSyncPolicy.callsignSSID`), and so is the grid square,
/// because a handheld is not where the home rig is.
nonisolated struct WinlinkIdentitySyncSource: WinlinkSyncSource {

    /// Reading and writing the operator's details, abstracted so this can be
    /// tested without a settings store or a database.
    ///
    /// `async` because the real store is the operator's settings, which are
    /// `@MainActor` observable objects driving the UI, while the sync engine
    /// is an actor doing database and network work off the main thread. The
    /// hop is real and has to be awaited — reaching across it with
    /// `assumeIsolated` traps at runtime rather than failing to compile.
    nonisolated protocol Store: Sendable {
        func read() async -> WinlinkIdentityPayload
        func apply(_ payload: WinlinkIdentityPayload) async
    }

    let kind: WinlinkSyncPolicy.Kind
    private let store: Store
    private let now: @Sendable () -> Date

    init(kind: WinlinkSyncPolicy.Kind, store: Store,
         now: @escaping @Sendable () -> Date = Date.init) {
        precondition(kind == .callsignBase || kind == .operatorProfile,
                     "this source owns the operator's own details only")
        self.kind = kind
        self.store = store
        self.now = now
    }

    /// Both halves, ready to plug into an engine.
    static func sources(store: Store,
                        now: @escaping @Sendable () -> Date = Date.init) -> [WinlinkSyncSource] {
        [WinlinkIdentitySyncSource(kind: .callsignBase, store: store, now: now),
         WinlinkIdentitySyncSource(kind: .operatorProfile, store: store, now: now)]
    }

    /// One record per kind: there is exactly one operator.
    static let recordID = "operator"

    func localRecords() async throws -> [WinlinkSyncRecord] {
        let payload = await store.read()
        // Nothing to publish until the operator has actually entered
        // something. An empty record would otherwise race a configured device
        // and blank it.
        guard payload.hasContent(for: kind) else { return [] }

        return [WinlinkSyncRecord(
            kind: kind,
            id: Self.recordID,
            modifiedAt: payload.updatedAt,
            payload: try Self.encoder.encode(payload.narrowed(to: kind)))]
    }

    @discardableResult
    func apply(_ records: [WinlinkSyncRecord]) async throws -> Int {
        var changed = 0
        for record in records where record.kind == kind {
            guard let remote = try? Self.decoder.decode(
                WinlinkIdentityPayload.self, from: record.payload) else {
                throw WinlinkSyncError.payloadUnreadable(kind: kind, id: record.id)
            }
            let local = await store.read()
            let merged = WinlinkIdentityPayload.merge(local: local, remote: remote, for: kind)
            guard merged != local else { continue }
            await store.apply(merged)
            changed += 1
        }
        return changed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The operator's details as they travel.
nonisolated struct WinlinkIdentityPayload: Codable, Equatable, Sendable {

    /// Licence callsign with **no SSID**.
    var callsignBase: String
    var realName: String
    var positionTitle: String
    var organization: String
    var phone: String
    var email: String
    var street: String
    var city: String
    var state: String
    var postalCode: String
    var county: String
    var updatedAt: Date

    init(callsignBase: String = "", realName: String = "", positionTitle: String = "",
         organization: String = "", phone: String = "", email: String = "",
         street: String = "", city: String = "", state: String = "",
         postalCode: String = "", county: String = "", updatedAt: Date = Date()) {
        self.callsignBase = callsignBase
        self.realName = realName
        self.positionTitle = positionTitle
        self.organization = organization
        self.phone = phone
        self.email = email
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.county = county
        self.updatedAt = updatedAt
    }

    /// Whether there is anything worth publishing for this kind.
    func hasContent(for kind: WinlinkSyncPolicy.Kind) -> Bool {
        switch kind {
        case .callsignBase: !callsignBase.isEmpty
        case .operatorProfile: !profileFields.allSatisfy(\.isEmpty)
        default: false
        }
    }

    private var profileFields: [String] {
        [realName, positionTitle, organization, phone, email,
         street, city, state, postalCode, county]
    }

    /// Only the fields this kind owns, so a callsign record does not carry
    /// an address and vice versa.
    func narrowed(to kind: WinlinkSyncPolicy.Kind) -> WinlinkIdentityPayload {
        switch kind {
        case .callsignBase:
            // Stripped here rather than trusted to the store: the SSID is
            // this device's station address, and publishing it would invite
            // another device to answer to the same one.
            return WinlinkIdentityPayload(
                callsignBase: CallsignParser.parse(callsignBase).base,
                updatedAt: updatedAt)
        case .operatorProfile:
            var copy = self
            copy.callsignBase = ""
            return copy
        default:
            return self
        }
    }

    /// Merges a remote record into the local details.
    ///
    /// Last-writer-wins on the whole record rather than field by field: these
    /// are one coherent identity, and a half-updated address — this device's
    /// street with the other device's city — would be worse than either.
    ///
    /// **A non-empty value is never replaced by an empty one.** A device that
    /// has not been configured publishes nothing (`hasContent`), but a device
    /// mid-edit can briefly hold a blank field, and letting that blank win
    /// would wipe the operator's details across every device they own.
    static func merge(local: WinlinkIdentityPayload,
                      remote: WinlinkIdentityPayload,
                      for kind: WinlinkSyncPolicy.Kind) -> WinlinkIdentityPayload {
        var result = local
        let remoteIsNewer = remote.updatedAt > local.updatedAt

        func take(_ remoteValue: String, _ localValue: String) -> String {
            if remoteValue.isEmpty { return localValue }
            if localValue.isEmpty { return remoteValue }
            return remoteIsNewer ? remoteValue : localValue
        }

        switch kind {
        case .callsignBase:
            // Stored without an SSID even if one arrives: this field is the
            // licence, and the station address is chosen per device.
            let base = CallsignParser.parse(remote.callsignBase).base
            result.callsignBase = take(base, local.callsignBase)

        case .operatorProfile:
            result.realName = take(remote.realName, local.realName)
            result.positionTitle = take(remote.positionTitle, local.positionTitle)
            result.organization = take(remote.organization, local.organization)
            result.phone = take(remote.phone, local.phone)
            result.email = take(remote.email, local.email)
            result.street = take(remote.street, local.street)
            result.city = take(remote.city, local.city)
            result.state = take(remote.state, local.state)
            result.postalCode = take(remote.postalCode, local.postalCode)
            result.county = take(remote.county, local.county)

        default:
            return local
        }

        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        return result
    }
}

// MARK: - Live store

/// Reads and writes the operator's details in the real settings stores.
///
/// Main-actor isolated, and the protocol it conforms to is `async` for that
/// reason: `AppSettingsStore` and `StationProfile` are observable objects
/// that publish to the UI, while the sync engine is an actor doing database
/// and network work that has no business on the main thread. The compiler
/// inserts the hop at each call.
@MainActor
final class LiveIdentityStore: WinlinkIdentitySyncSource.Store {

    private let settings: AppSettingsStore
    private let profile: StationProfile
    /// Stamped whenever this device changes something, so last-writer-wins
    /// has something to compare. Kept here rather than in each store because
    /// it describes the identity as a whole.
    private let defaults: UserDefaults
    private static let stampKey = "identity.updatedAt"

    init(settings: AppSettingsStore, profile: StationProfile,
         defaults: UserDefaults = AppEnvironment.defaults) {
        self.settings = settings
        self.profile = profile
        self.defaults = defaults
    }

    func read() -> WinlinkIdentityPayload {
        WinlinkIdentityPayload(
            // The licence only — the SSID is this device's own.
            callsignBase: CallsignParser.parse(settings.myCallsign).base,
            realName: profile.realName,
            positionTitle: profile.positionTitle,
            organization: profile.organization,
            phone: profile.phone,
            email: profile.email,
            street: profile.street,
            city: profile.city,
            state: profile.state,
            postalCode: profile.postalCode,
            county: profile.county,
            updatedAt: Date(timeIntervalSince1970:
                defaults.double(forKey: Self.stampKey)))
    }

    func apply(_ payload: WinlinkIdentityPayload) {
        // The SSID this device already chose is preserved. Overwriting it
        // with the incoming callsign would put two stations on one
        // address — the collision the whole split exists to avoid.
        if !payload.callsignBase.isEmpty {
            let existing = CallsignParser.parse(settings.myCallsign)
            let merged = ParsedCallsign(base: payload.callsignBase, ssid: existing.ssid)
            if merged.full != settings.myCallsign {
                settings.myCallsign = merged.full
            }
        }

        if !payload.realName.isEmpty { profile.realName = payload.realName }
        if !payload.positionTitle.isEmpty { profile.positionTitle = payload.positionTitle }
        if !payload.organization.isEmpty { profile.organization = payload.organization }
        if !payload.phone.isEmpty { profile.phone = payload.phone }
        if !payload.email.isEmpty { profile.email = payload.email }
        if !payload.street.isEmpty { profile.street = payload.street }
        if !payload.city.isEmpty { profile.city = payload.city }
        if !payload.state.isEmpty { profile.state = payload.state }
        if !payload.postalCode.isEmpty { profile.postalCode = payload.postalCode }
        if !payload.county.isEmpty { profile.county = payload.county }

        defaults.set(payload.updatedAt.timeIntervalSince1970, forKey: Self.stampKey)
    }

    /// Records that this device changed the operator's details, so its
    /// version wins on the next pass.
    func stampLocalEdit(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.stampKey)
    }
}
