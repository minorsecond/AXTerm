//
//  NetRomForwarding.swift
//  AXTerm
//
//  The transit-routing decision: what to do with a NET/ROM datagram
//  addressed to somebody else.
//
//  Kept as a pure function because every branch here is a way to hurt
//  the network if it is wrong. Forwarding puts this station's
//  transmitter at the service of other people's traffic, so the failure
//  modes are not "my app misbehaves" but "the channel fills with
//  packets going in circles".
//
//  Reference: `nr_route_frame` in the Linux AF_NETROM stack decrements
//  TTL and drops at zero. The loop guard and the self-hop guard are
//  ours, and both are cheap insurance against a routing table that has
//  learned something silly.
//

import Foundation

nonisolated enum NetRomForwarding {

    enum Decision: Equatable {
        /// Send this datagram — TTL already decremented — to `neighbor`.
        case forward(NetRomDatagram, neighbor: AX25Address)
        /// Forwarding is switched off; this station is an endpoint.
        case notARouter
        /// TTL reached zero. The packet has travelled far enough; if it
        /// has not arrived by now it is looping.
        case ttlExpired
        /// Nothing in the routing table reaches the destination.
        case noRoute(String)
        /// The only route points back where the datagram came from, or
        /// at ourselves. Either would loop.
        case wouldLoop(String)
    }

    /// Decide the fate of a transit datagram.
    ///
    /// - Parameters:
    ///   - datagram: as received, with the sender's TTL.
    ///   - arrivedFrom: the neighbor whose link carried it here.
    ///   - forwardingEnabled: the operator's switch.
    ///   - localNode: this station, so we never forward to ourselves.
    ///   - nextHop: routing-table lookup, destination display → neighbor.
    static func decide(
        datagram: NetRomDatagram,
        arrivedFrom: AX25Address,
        forwardingEnabled: Bool,
        localNode: AX25Address,
        nextHop: (String) -> String?
    ) -> Decision {
        guard forwardingEnabled else { return .notARouter }

        // Decrement first, drop at zero (nr_route_frame). A datagram that
        // arrives with TTL 1 has used its last hop getting here.
        guard datagram.ttl > 1 else { return .ttlExpired }

        guard let hopText = nextHop(datagram.destination.display), !hopText.isEmpty else {
            return .noRoute(datagram.destination.display)
        }
        let neighbor = CallsignNormalizer.toAddress(hopText)

        // Straight back down the link it came from is a loop, and so is
        // handing it to ourselves.
        if CallsignNormalizer.addressesMatch(neighbor, arrivedFrom) {
            return .wouldLoop(neighbor.display)
        }
        if CallsignNormalizer.addressesMatch(neighbor, localNode) {
            return .wouldLoop(neighbor.display)
        }

        var forwarded = datagram
        forwarded.ttl = datagram.ttl - 1
        return .forward(forwarded, neighbor: neighbor)
    }
}
