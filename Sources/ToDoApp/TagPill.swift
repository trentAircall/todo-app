import SwiftUI

/// A small pill/capsule label — used for tags and the "overdue" date badge.
/// Lighter fill + a brighter stroke than a plain `.secondary.opacity(...)`
/// fill alone, so it stays legible sitting on a dark background (including
/// the dark green meeting blocks).
struct TagPill: View {
    let text: String
    var tint: Color = .white
    var compact: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(tint.opacity(0.28))
            .overlay(Capsule().stroke(tint.opacity(0.65), lineWidth: 1))
            .clipShape(Capsule())
    }
}
