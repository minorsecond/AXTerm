//
//  TimeAxisTicks.swift
//  AXTerm
//
//  Generates well-spaced, non-overlapping time axis ticks for charts.
//

import Foundation

/// Generates time axis ticks with appropriate spacing and formatting.
enum TimeAxisTicks {

    // MARK: - Configuration

    /// Minimum pixel spacing between tick labels to avoid overlap
    private static let minTickSpacing: CGFloat = 70

    /// Preferred tick intervals in seconds, ordered by preference
    private static let preferredIntervals: [TimeInterval] = [
        10,           // 10 seconds
        30,           // 30 seconds
        60,           // 1 minute
        120,          // 2 minutes
        300,          // 5 minutes
        600,          // 10 minutes
        900,          // 15 minutes
        1800,         // 30 minutes
        3600,         // 1 hour
        7200,         // 2 hours
        14400,        // 4 hours
        21600,        // 6 hours
        43200,        // 12 hours
        86400,        // 1 day
        172800,       // 2 days
        604800        // 1 week
    ]

    // MARK: - Tick Generation

    /// A single axis tick with its position and label.
    struct Tick: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let position: CGFloat  // 0-1 normalized position
        let isMinor: Bool
        let isDayBoundary: Bool
    }

    /// Generates ticks for a time range that fit within the given plot width.
    /// - Parameters:
    ///   - range: The time range to generate ticks for
    ///   - plotWidth: Width of the plot area in points
    ///   - bucketSeconds: Optional bucket size in seconds for alignment
    /// - Returns: Array of ticks that won't overlap
    static func generateTicks(
        for range: DateInterval,
        plotWidth: CGFloat,
        bucketSeconds: TimeInterval? = nil
    ) -> [Tick] {
        let duration = range.duration
        guard duration > 0, plotWidth > 0 else { return [] }

        // Determine appropriate tick interval
        let maxTicks = Int(plotWidth / minTickSpacing)
        let interval = selectInterval(duration: duration, maxTicks: max(2, maxTicks), bucketSeconds: bucketSeconds)

        // Generate ticks aligned to interval boundaries
        var ticks: [Tick] = []
        let calendar = Calendar.current

        // Find the first tick time (aligned to interval)
        let firstTickTime = alignedTime(after: range.start, interval: interval, calendar: calendar)

        // Determine format based on duration and interval
        let format = selectFormat(duration: duration, interval: interval)

        // Track last label to avoid duplicates
        var lastLabel: String?
        var lastDayComponent: Int?

        var tickTime = firstTickTime
        while tickTime <= range.end {
            let position = CGFloat(tickTime.timeIntervalSince(range.start) / duration)

            // Only add if position is valid
            if position >= 0 && position <= 1 {
                let label = format(tickTime)

                // Check for day boundary
                let dayComponent = calendar.component(.day, from: tickTime)
                let isDayBoundary = lastDayComponent != nil && dayComponent != lastDayComponent

                // Skip duplicate labels
                if label != lastLabel {
                    ticks.append(Tick(
                        date: tickTime,
                        label: label,
                        position: position,
                        isMinor: false,
                        isDayBoundary: isDayBoundary
                    ))
                    lastLabel = label
                }

                lastDayComponent = dayComponent
            }

            tickTime = tickTime.addingTimeInterval(interval)
        }

        return ticks
    }

    // MARK: - Private Helpers

    private static func selectInterval(
        duration: TimeInterval,
        maxTicks: Int,
        bucketSeconds: TimeInterval?
    ) -> TimeInterval {
        let minInterval = duration / TimeInterval(maxTicks)

        // Find the smallest preferred interval that doesn't exceed max ticks
        for interval in preferredIntervals {
            if interval >= minInterval {
                // If bucket size is specified, prefer intervals that are multiples
                if let bucket = bucketSeconds, bucket > 0 {
                    // Find nearest multiple of bucket that's >= interval
                    let multiple = ceil(interval / bucket) * bucket
                    if multiple >= minInterval {
                        return multiple
                    }
                }
                return interval
            }
        }

        // Fallback: just divide duration by max ticks
        return duration / TimeInterval(maxTicks)
    }

    private static func alignedTime(
        after date: Date,
        interval: TimeInterval,
        calendar: Calendar
    ) -> Date {
        // Align to nice boundaries based on interval
        let components: Set<Calendar.Component>

        if interval >= 86400 {
            // Days: align to midnight
            components = [.year, .month, .day]
        } else if interval >= 3600 {
            // Hours: align to hour boundary
            components = [.year, .month, .day, .hour]
        } else if interval >= 60 {
            // Minutes: align to minute boundary
            components = [.year, .month, .day, .hour, .minute]
        } else {
            // Seconds: align to interval boundary
            let midnight = calendar.startOfDay(for: date)
            let secondsSinceMidnight = date.timeIntervalSince(midnight)
            let alignedSeconds = ceil(secondsSinceMidnight / interval) * interval
            return midnight.addingTimeInterval(alignedSeconds)
        }

        var aligned = calendar.dateComponents(components, from: date)

        if interval >= 86400 {
            // Move to next day boundary
            aligned.day = (aligned.day ?? 0) + 1
            aligned.hour = 0
            aligned.minute = 0
            aligned.second = 0
        } else if interval >= 3600 {
            // Move to next hour boundary
            aligned.hour = (aligned.hour ?? 0) + 1
            aligned.minute = 0
            aligned.second = 0
        } else {
            // Move to next minute boundary
            aligned.minute = (aligned.minute ?? 0) + 1
            aligned.second = 0
        }

        if let result = calendar.date(from: aligned), result > date {
            return result
        }
        return date.addingTimeInterval(interval)
    }

    private static func selectFormat(
        duration: TimeInterval,
        interval: TimeInterval
    ) -> (Date) -> String {
        // Choose format based on the time span being displayed
        if duration > 172800 {  // > 2 days
            // Show date only or date + hour for longer spans
            if interval >= 86400 {
                return { date in
                    formatDate(date, style: .monthDay)
                }
            } else {
                return { date in
                    formatDate(date, style: .monthDayHour)
                }
            }
        } else if duration > 7200 {  // > 2 hours
            // Show hour:minute
            return { date in
                formatDate(date, style: .hourMinute)
            }
        } else {
            // Short duration: hour:minute
            return { date in
                formatDate(date, style: .hourMinute)
            }
        }
    }

    private enum DateStyle {
        case hourMinute       // "14:30"
        case hourMinuteSecond // "14:30:45"
        case monthDay         // "Jan 15"
        case monthDayHour     // "Jan 15 14:00"
    }

    private static let hourMinuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let monthDayHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private static func formatDate(_ date: Date, style: DateStyle) -> String {
        switch style {
        case .hourMinute:
            return hourMinuteFormatter.string(from: date)
        case .hourMinuteSecond:
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f.string(from: date)
        case .monthDay:
            return monthDayFormatter.string(from: date)
        case .monthDayHour:
            return monthDayHourFormatter.string(from: date)
        }
    }
}

// MARK: - Chart Axis Stride Extension

extension TimeBucket {
    /// Returns appropriate axis stride for Swift Charts based on bucket size.
    var chartAxisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .tenSeconds:
            return (.minute, 1)
        case .minute:
            return (.minute, 5)
        case .fiveMinutes:
            return (.minute, 15)
        case .fifteenMinutes:
            return (.hour, 1)
        case .hour:
            return (.hour, 4)
        case .day:
            return (.day, 1)
        }
    }

    /// Returns the bucket duration in seconds.
    var durationSeconds: TimeInterval {
        switch self {
        case .tenSeconds: return 10
        case .minute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .hour: return 3600
        case .day: return 86400
        }
    }
}
