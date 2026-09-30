//
//  MainWindowServices.swift
//  AXTerm
//
//  The objects the main window builds around the session coordinator, and
//  the box that makes sure they are built once per window.
//

import Foundation

/// The session coordinator, wired to the engine, and the mailbox services
/// that hang off it.
///
/// Built in one place because each needs the one before it: the mailbox
/// needs the coordinator (which owns inbound calls), the file library, and
/// the callsign cache.
struct MainWindowServices {
    let coordinator: SessionCoordinator
    let bbsLibrary: BBSFileLibrary
    let callsignLookup: CallsignLookupService
    let bbsService: BBSService
}

/// Builds `MainWindowServices` the first time they are asked for, and never
/// again.
///
/// The main window's initializer runs every time its parent's body does,
/// and the app's body is evaluated again whenever any setting publishes.
/// Building the services there directly made a new library, lookup service
/// and mailbox on every settings edit, and re-wired the coordinator each
/// time: the packet subscription was torn down and remade, the APRS retry
/// timer restarted, and the NET/ROM broadcast timer re-armed, which also
/// canceled the warm-up broadcast. `@StateObject` kept only the first set,
/// so the rest was thrown away.
///
/// Each `StateObject(wrappedValue:)` autoclosure reads from the same box.
/// SwiftUI evaluates those autoclosures once, when it first installs the
/// view, so the services are built then; every later initializer makes a
/// box that nothing ever opens.
final class MainWindowServicesBox {

    /// How many times any box in this process has built its services. Read
    /// by tests; nothing else should care.
    private(set) static var buildCount = 0

    private var make: (() -> MainWindowServices)?
    private var built: MainWindowServices?

    init(_ make: @escaping () -> MainWindowServices) {
        self.make = make
    }

    var services: MainWindowServices {
        if let built { return built }
        guard let make else { preconditionFailure("MainWindowServicesBox has no builder") }
        let made = make()
        built = made
        self.make = nil
        Self.buildCount += 1
        return made
    }
}
