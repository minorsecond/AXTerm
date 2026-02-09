//
//  MainThreadWatchdog.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-08.
//

import Foundation
import OSLog

/// A watchdog that monitors the main thread for responsiveness.
///
/// It periodically schedules a block on the main queue and measures the time
/// it takes to execute. If the delay exceeds a threshold, it logs a warning
/// indicating a potential main thread hang (ANR).
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    /// Threshold in seconds before a hang is reported.
    /// 200ms is noticeable to users (dropped frames).
    let threshold: TimeInterval = 0.2

    /// Interval between checks.
    let interval: TimeInterval = 1.0

    private let logger = Logger(subsystem: "AXTerm", category: "Watchdog")
    private var timer: Timer?
    private let queue = DispatchQueue.global(qos: .userInteractive)
    private var isRunning = false

    private init() {}

    /// Start the watchdog.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        logger.info("MainThreadWatchdog started (threshold: \(self.threshold, format: .fixed(precision: 3))s)")

        // Schedule timer on background runloop
        queue.async { [weak self] in
            guard let self = self else { return }
            let timer = Timer(timeInterval: self.interval, repeats: true) { _ in
                self.checkMainThread()
            }
            // Add to a runloop so it fires
            let runLoop = RunLoop.current
            runLoop.add(timer, forMode: .common)
            self.timer = timer
            runLoop.run()
        }
    }

    /// Stop the watchdog.
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func checkMainThread() {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime
            
            if duration > self.threshold {
                self.logger.fault("⚠️ Main thread blocked for \(duration, format: .fixed(precision: 3))s (threshold: \(self.threshold)s)")
                
                // In a debug build, we might want to pause execution or print more info
                #if DEBUG
                print("⚠️ [MainThreadWatchdog] Main thread blocked for \(String(format: "%.3f", duration))s")
                #endif
                
                // TODO: If possible, capture stack trace (hard in swift without signal handlers)
            }
        }
    }
}
