//
//  SessionCoordinator+NodeHost.swift
//  AXTerm
//
//  What the NET/ROM node tells its callers: the alias and callsign it
//  greets them with, and what NODES, ROUTES, MH, INFO and BBS have to say.
//
//  This used to be set up by the Mac's ContentView when it appeared. The
//  iOS app has its own root view and never did it, yet its settings can
//  turn the node on, so an iOS caller was greeted as NODE:N0CALL, saw empty
//  tables, and was told the mailbox was off the air. The coordinator lives
//  for the whole run of the app on both platforms, so the node reads from
//  it no matter which shell or which view is up.
//

import Foundation

extension SessionCoordinator {

    /// Points the node host at this coordinator. Called once, from `init`.
    ///
    /// Every closure reads at the moment a caller needs it, so a changed
    /// alias, callsign or mailbox setting shows on the next call without
    /// anything having to run this again.
    func wireNodeHost() {
        let host = netRomNodeHost
        host.identityProvider = { [weak self] in
            self?.nodeHostIdentity() ?? ("NODE", "N0CALL", "AXTerm")
        }
        host.snapshotProvider = { [weak self] in
            self?.nodeHostSnapshot() ?? NetRomNodeShell.Snapshot()
        }
        host.bbsSessionFactory = { [weak self] caller in
            self?.nodeMailbox?.beginCircuitSession(caller: caller)
        }
    }

    /// The alias the operator set, and the node's callsign, which is the
    /// primary radio's address when every radio is one node (see
    /// `localCallsign`).
    func nodeHostIdentity() -> (alias: String, call: String, version: String) {
        let alias = appSettings?.netRomNodeAlias
            .trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        return (alias.isEmpty ? "NODE" : alias,
                appSettings?.primaryCallsign.uppercased() ?? "N0CALL",
                "AXTerm")
    }

    /// What this station knows right now, in the shape the node shell prints.
    func nodeHostSnapshot() -> NetRomNodeShell.Snapshot {
        var snapshot = NetRomNodeShell.Snapshot()
        if let integration = packetEngine?.netRomIntegration {
            let entries = nodeAliases?.directory.allEntries ?? []
            let aliasFor = { (call: String) -> String in
                entries.first { $0.callsign.uppercased() == call.uppercased() }?.alias ?? ""
            }
            snapshot.routes = integration.currentRoutes().map { route in
                NetRomNodeShell.Snapshot.Route(
                    destination: route.destination,
                    alias: aliasFor(route.destination),
                    nextHop: route.origin,
                    quality: route.quality)
            }
            snapshot.neighbors = integration.currentNeighbors().map { neighbor in
                NetRomNodeShell.Snapshot.Neighbor(
                    callsign: neighbor.call,
                    quality: neighbor.quality,
                    count: max(1, neighbor.obsolescenceCount))
            }
        }
        snapshot.heard = (packetEngine?.stations ?? []).compactMap { station in
            station.lastHeard.map {
                NetRomNodeShell.Snapshot.Heard(callsign: station.call, lastHeard: $0)
            }
        }
        snapshot.stationInfo = nodeMailbox?.settings.stationInfo ?? ""
        snapshot.bbsAvailable = nodeMailbox?.settings.onAir ?? false
        return snapshot
    }
}
