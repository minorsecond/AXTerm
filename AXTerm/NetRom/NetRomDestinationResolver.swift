//
//  NetRomDestinationResolver.swift
//  AXTerm
//
//  Turning what the operator names into what goes in the L3 header.
//
//  NET/ROM addresses stations by **callsign**. Operators, node tables,
//  and this app's own Routes page name them by **alias** — COSCO, EVANS,
//  DRLNOD. BPQ resolves the alias before building the header; until now
//  AXTerm did not, so a circuit opened to "COSCO" put the six bytes
//  C-O-S-C-O in a field that is supposed to hold KE0GB-7.
//
//  Two reasons that matters, one soft and one hard:
//
//   - A strict peer routes on the callsign and will not match an alias.
//   - The NODES broadcast destination field is validated as a callsign
//     by every conforming parser, including ours. Advertising `EVANS`
//     emits bytes that are simply thrown away at the far end.
//
//  The resolution is best-effort on purpose. This network genuinely uses
//  aliases as L2 addresses — DRLNOD answers a SABM sent to "DRLNOD" —
//  so when nothing is known, passing the operator's name through
//  unchanged is better than refusing to transmit. What we will not do is
//  *guess*: an unresolvable name goes out exactly as typed, and the
//  caller can tell the two cases apart.
//

import Foundation

nonisolated enum NetRomDestinationResolver {

    /// What a name resolved to, and how.
    struct Resolution: Equatable {
        /// The address to put in the L3 header.
        let address: AX25Address
        /// What the operator asked for, preserved for display. Nil when
        /// it is the same as `address`.
        let requestedAlias: String?
        /// True when an alias was translated into a callsign.
        let didResolve: Bool

        /// How to name this circuit to a human: the alias they know,
        /// with the callsign that is actually on the air.
        var displayName: String {
            guard let requestedAlias else { return address.display }
            return "\(requestedAlias) (\(address.display))"
        }
    }

    /// Resolve a destination the operator named.
    ///
    /// - Parameters:
    ///   - name: what was typed or clicked — a callsign or an alias.
    ///   - callsignForAlias: alias → callsign, from the node directory.
    static func resolve(
        _ name: String,
        callsignForAlias: (String) -> String?
    ) -> Resolution {
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        let asAddress = CallsignNormalizer.toAddress(trimmed)

        // Already a callsign: nothing to do. Checked first so a station
        // whose callsign happens to appear in the alias table as well is
        // never rewritten out from under the operator.
        if CallsignValidator.isValidCallsign(asAddress.display) {
            return Resolution(address: asAddress, requestedAlias: nil, didResolve: false)
        }

        // An alias. The directory is keyed by the alias exactly as
        // harvested, so try the whole name before the SSID-stripped base
        // — "KB5YZB-1" style aliases exist, and so do bare ones.
        let candidates = [trimmed, asAddress.call]
        for candidate in candidates {
            guard let resolvedText = callsignForAlias(candidate), !resolvedText.isEmpty else {
                continue
            }
            let resolved = CallsignNormalizer.toAddress(resolvedText)
            guard CallsignValidator.isValidCallsign(resolved.display) else { continue }
            return Resolution(address: resolved, requestedAlias: trimmed, didResolve: true)
        }

        // Unknown alias. Send it as named — this network does answer to
        // aliases at L2 — but say plainly that nothing was resolved.
        return Resolution(address: asAddress, requestedAlias: nil, didResolve: false)
    }

    /// The names a route lookup should try for a destination, in order.
    ///
    /// The route table is keyed by whatever the broadcast said, which may
    /// be either form, so a resolved circuit must still be able to find
    /// the route that was learned under the alias — and vice versa.
    static func routeLookupKeys(for resolution: Resolution) -> [String] {
        var keys: [String] = [resolution.address.display]
        if let alias = resolution.requestedAlias, alias != resolution.address.display {
            keys.append(alias)
        }
        return keys
    }
}
