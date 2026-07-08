import SwiftUI

/// Stronger, more intentional curves than SwiftUI's built-in `.easeOut`/
/// `.easeInOut` — same shape Emil Kowalski's design-eng notes point to
/// (animations.dev), ported from their CSS `cubic-bezier` form.
extension Animation {
    /// For anything entering, exiting, or responding to a press — starts
    /// fast, reads as instantly responsive. cubic-bezier(0.23, 1, 0.32, 1).
    static func uiEaseOut(duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// For something already on screen moving from A to B (reordering,
    /// expanding in place). cubic-bezier(0.77, 0, 0.175, 1).
    static func uiEaseInOut(duration: Double) -> Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: duration)
    }
}
