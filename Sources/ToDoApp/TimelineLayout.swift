import Foundation

/// Positions scheduled items on a day's timeline, splitting overlapping
/// items (double-booked meetings happen) into side-by-side columns like a
/// calendar day view, rather than letting them draw on top of each other.
enum TimelineLayout {
    struct Placement {
        let task: TaskItem
        let start: Int
        let end: Int
        let column: Int
        let columnCount: Int
    }

    /// `items` must all have a non-nil `startMinutes`.
    static func layout(_ items: [TaskItem]) -> [Placement] {
        struct Entry { let task: TaskItem; let start: Int; let end: Int }

        let entries = items
            .compactMap { item -> Entry? in
                guard let start = item.startMinutes else { return nil }
                let end = max(item.endMinutes ?? (start + 30), start + 15)
                return Entry(task: item, start: start, end: end)
            }
            .sorted { $0.start < $1.start }

        var results: [Placement] = []
        var cluster: [Entry] = []
        var clusterEnd = Int.min

        func flush() {
            guard !cluster.isEmpty else { return }
            // Greedy column assignment within this overlap cluster: give
            // each item the lowest-numbered column whose previous occupant
            // has already finished.
            var columnEnds: [Int] = []
            var assigned: [(Entry, Int)] = []
            for entry in cluster {
                if let col = columnEnds.firstIndex(where: { $0 <= entry.start }) {
                    columnEnds[col] = entry.end
                    assigned.append((entry, col))
                } else {
                    columnEnds.append(entry.end)
                    assigned.append((entry, columnEnds.count - 1))
                }
            }
            let columnCount = columnEnds.count
            for (entry, col) in assigned {
                results.append(Placement(task: entry.task, start: entry.start, end: entry.end, column: col, columnCount: columnCount))
            }
            cluster = []
        }

        for entry in entries {
            if entry.start >= clusterEnd {
                flush()
                clusterEnd = entry.end
            } else {
                clusterEnd = max(clusterEnd, entry.end)
            }
            cluster.append(entry)
        }
        flush()

        return results
    }
}
