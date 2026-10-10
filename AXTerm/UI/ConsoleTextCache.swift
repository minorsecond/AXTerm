import Foundation

/// What a console row draws, kept until something it depends on changes.
///
/// A row's decoded sentence, its links and its underlines used to be worked
/// out again on every render. Scrolling renders the visible rows on every
/// step, and in a profile of the terminal stuttering that rebuilding was a
/// fifth of the main thread (2026-10-10). Each value is stored per row and
/// per type, under a version the row computes from everything that could
/// change the result: a station newly heard, a setting, the row's own text.
@MainActor
final class ConsoleTextCache {
    private struct Key: Hashable {
        let line: UUID
        let type: ObjectIdentifier
    }

    private var entries: [Key: (version: Int, value: Any)] = [:]

    var count: Int { entries.count }

    func value<T>(line: UUID, version: Int, build: () -> T) -> T {
        let key = Key(line: line, type: ObjectIdentifier(T.self))
        if let entry = entries[key], entry.version == version, let value = entry.value as? T {
            return value
        }
        let value = build()
        entries[key] = (version, value)
        return value
    }

    /// Forget rows that have left the console, so the cache cannot outgrow it.
    func prune(keeping lines: Set<UUID>) {
        entries = entries.filter { lines.contains($0.key.line) }
    }
}
