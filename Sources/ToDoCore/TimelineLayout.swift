import Foundation

/// Detects which scheduled items double-book each other. No positioning
/// math — just "does this item's time range overlap another's" — so it can
/// back a simple flat list with a text flag instead of a calendar-grid
/// layout.
///
/// Mirrored by `findOverlappingIds` in mcp-server/planning.js so that
/// "overlapping" means the same thing in the app's UI as it does in a
/// week_overview count.
public enum TimelineLayout {
    /// An item with no end time is treated as 30 minutes long, and every
    /// item is given a 15-minute minimum footprint — otherwise two
    /// zero-length items at the same instant wouldn't register as a clash.
    public static let assumedDurationMinutes = 30
    public static let minimumFootprintMinutes = 15

    /// Returns the URLs of every item whose time range overlaps at least
    /// one other item's.
    public static func overlappingTaskIDs(_ items: [TaskItem]) -> Set<URL> {
        struct Entry { let id: URL; let start: Int; let end: Int }

        let entries = items
            .compactMap { item -> Entry? in
                guard let start = item.startMinutes else { return nil }
                let end = max(
                    item.endMinutes ?? (start + assumedDurationMinutes),
                    start + minimumFootprintMinutes
                )
                return Entry(id: item.url, start: start, end: end)
            }
            .sorted { $0.start < $1.start }

        var overlapping: Set<URL> = []
        for i in entries.indices {
            for j in (i + 1)..<entries.count {
                if entries[j].start >= entries[i].end { break } // sorted by start — nothing later can overlap either
                overlapping.insert(entries[i].id)
                overlapping.insert(entries[j].id)
            }
        }
        return overlapping
    }
}
