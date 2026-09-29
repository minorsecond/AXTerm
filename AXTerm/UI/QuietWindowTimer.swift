//
//  QuietWindowTimer.swift
//  AXTerm
//
//  A trailing debounce that keeps at most one timer in flight.
//
//  The obvious way to write one is to hold a DispatchWorkItem, cancel it on
//  each poke, and schedule a replacement. That is correct about *when* the
//  action runs and wrong about what it costs. `cancel()` stops the block from
//  running; it does not retract the `asyncAfter`. The dispatch source, the work
//  item and the group stay queued until the deadline passes, and the block goes
//  on holding whatever it captured — for a SwiftUI view, the view itself, and
//  through it the generation of any array it was carrying.
//
//  That is affordable while the main thread is draining the queue. It is
//  unbounded while it is not, and the two views that used the pattern poke from
//  places that fire hardest exactly when the main thread is already behind: the
//  console's bottom sentinel flips from inside the SwiftUI update pass, and the
//  connect bar refreshes once per packet heard. A pass that runs long stops the
//  timers firing at the moment it starts producing more of them.
//
//  A release build sampled on 2026-09-18 had been pegged at 100% of the main
//  thread since launch, with 101,465 live dispatch sources, 95,565 work items
//  and 2.97 million CFStrings, growing about a megabyte a second. Whatever
//  first pushed it over, that backlog is why it never came back.
//
//  Re-arming from the timer instead of from the poke keeps the quiet-window
//  behaviour — the action still runs only once the pokes stop — at one timer and
//  one retained capture, however fast the pokes arrive.
//

import Foundation

/// Runs an action once a quiet window has passed with no further pokes.
///
/// Main-thread only: nothing here is synchronised, and both callers poke from
/// SwiftUI view updates.
final class QuietWindowTimer {

    /// How the timer gets scheduled. Injectable so tests can drive it without
    /// waiting on a real clock.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let window: TimeInterval
    private let scheduler: Scheduler
    private let now: () -> Date

    /// When `poke` was last called. Nil when nothing is waiting to run.
    private var pokedAt: Date?
    /// Whether a timer is already waiting. The invariant this type exists for:
    /// this is true for at most one outstanding scheduled block.
    private var armed = false
    private var action: (() -> Void)?

    init(window: TimeInterval,
         now: @escaping () -> Date = Date.init,
         scheduler: @escaping Scheduler = { delay, body in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
         }) {
        self.window = window
        self.now = now
        self.scheduler = scheduler
    }

    /// Ask for `action` to run once the pokes stop. The most recent action wins,
    /// matching the cancel-and-replace behaviour this replaced.
    func poke(_ action: @escaping () -> Void) {
        self.action = action
        pokedAt = now()
        arm()
    }

    /// Drop the pending action. A timer already in flight still fires, finds
    /// nothing waiting, and goes away.
    func cancel() {
        action = nil
        pokedAt = nil
    }

    /// True while a scheduled block is outstanding. Tests assert on this; it is
    /// the property that went wrong in the frozen build.
    var isArmed: Bool { armed }

    private func arm() {
        guard !armed else { return }
        armed = true
        scheduler(window) { [self] in
            armed = false
            guard let pokedAt, let action else { return }
            // Poked again while this timer was waiting: wait out another window
            // rather than running mid-storm.
            guard now().timeIntervalSince(pokedAt) >= window else {
                arm()
                return
            }
            self.pokedAt = nil
            self.action = nil
            action()
        }
    }
}
