import AppKit
import MaxActCore
import SwiftUI

/// The statistics with the workout inspector drawn **over** their trailing edge, not beside them as
/// a split-view pane (issue 8d).
///
/// The window's real `.inspector` can't sit beside the statistics: when it opens, SwiftUI pins the
/// statistics column's minimum to its current width, and the panes overflow the window. This keeps
/// the inspector inside the statistics' own column, so the split view never changes and nothing is
/// pinned. The statistics take what's left and scroll sideways below their minimum width.
/// Same `showsDetail`, so the toolbar toggle and ⌃⌘I work as they do beside the list.
struct StatisticsWithInspector: View {
    @Bindable var model: AppModel

    @AppStorage("statisticsInspectorWidth") private var width: Double = 440
    @State private var dragStart: Double?

    /// The inspector's own range beside the list — see `DetailPane`.
    private static let widths = 440.0...760.0

    var body: some View {
        HStack(spacing: 0) {
            StatisticsView(model: model)
            if model.showsDetail {
                handle
                DetailPane(model: model)
                    .frame(width: width)
                    .background(.background)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("StatisticsInspector")
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.showsDetail)
    }

    /// A divider that resizes the inspector when dragged, like the system inspector's.
    private var handle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(max(start - drag.translation.width, Self.widths.lowerBound),
                                            Self.widths.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}
