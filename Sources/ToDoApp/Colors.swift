import SwiftUI

extension Color {
    /// Aircall's brand dark green — used as a background tint for meeting
    /// blocks. Too dark to use as foreground text on a dark background;
    /// use `aircallAccent` for that.
    static let aircallGreen = Color(red: 0.031, green: 0.216, blue: 0.161)

    /// A brighter emerald pulled from the same brand family, for anything
    /// that needs to read as legible text/foreground — links, the "Today"
    /// button — in place of the system blue accent.
    static let aircallAccent = Color(red: 0.15, green: 0.78, blue: 0.55)
}
