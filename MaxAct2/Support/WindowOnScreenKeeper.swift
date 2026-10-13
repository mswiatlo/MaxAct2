import AppKit
import SwiftUI

/// Keeps the window on screen when its minimum width rises.
///
/// The minimum width depends on what's showing (`AppModel.minimumWindowWidth`), and raising it
/// makes AppKit grow the window **rightwards from its current origin** — past the screen's edge if
/// the window already sat against it. Measured with the inspector opening over the statistics: the
/// window grew from 1,200pt to 1,320pt and ended 112pt off the right of a 1,710pt screen, taking
/// part of the inspector with it. This shifts the window left by the overflow, and only then:
/// a window the user deliberately placed part-way off screen is otherwise left alone.
struct WindowOnScreenKeeper: NSViewRepresentable {
    let minimumWidth: CGFloat

    final class Coordinator {
        var lastMinimum: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let previous = context.coordinator.lastMinimum
        context.coordinator.lastMinimum = minimumWidth
        guard let previous, minimumWidth > previous else { return }
        // After SwiftUI has applied the new minimum and AppKit has grown the window.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.pullOnScreen(window)
        }
    }

    static func pullOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        let overflow = frame.maxX - visible.maxX
        guard overflow > 0 else { return }
        frame.origin.x = max(visible.minX, frame.origin.x - overflow)
        window.setFrame(frame, display: true, animate: false)
    }
}
