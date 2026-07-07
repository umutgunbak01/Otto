import SwiftUI

/// Ambient backdrop — a flat, calm surface.
///
/// The old HUD drew an animated grid + scanline + vignette here; the
/// redesign is a still, hairline-bordered UI, so the backdrop is now just
/// the window background color. Keeping the type (rather than deleting it)
/// preserves the `GridBackground()` call sites.
struct GridBackground: View {
    var body: some View {
        Theme.Colors.bg0
            .ignoresSafeArea()
    }
}
