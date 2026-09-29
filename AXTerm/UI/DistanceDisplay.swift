//
//  DistanceDisplay.swift
//  AXTerm
//
//  One place that turns kilometres into what the operator reads.
//  Distances were hardcoded to miles on every surface while heights
//  already had a unit choice — the map's reach into VK and ZL made
//  "miles only" a US assumption worth retiring (field ask 2026-08-29).
//

import Foundation

nonisolated enum DistanceDisplay {

    /// "48 mi" or "77 km", with the caller's precision.
    static func string(kilometres: Double, inMiles: Bool, format: String = "%.0f") -> String {
        inMiles
            ? String(format: format + " mi", GreatCircle.miles(fromKilometres: kilometres))
            : String(format: format + " km", kilometres)
    }

    /// The bare unit name, for scale bars and axis labels.
    static func unitName(inMiles: Bool) -> String { inMiles ? "miles" : "km" }

    /// The value alone in the chosen unit, for callers doing their own
    /// layout around it.
    static func value(kilometres: Double, inMiles: Bool) -> Double {
        inMiles ? GreatCircle.miles(fromKilometres: kilometres) : kilometres
    }
}
