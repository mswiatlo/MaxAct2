import MaxActCore
import SwiftUI

/// A table row's route map. An `Image` of a pre-rendered bitmap — never a live `Map`.
///
/// Rendering is requested in `.task(id:)`, so scrolling a row out of view cancels its render
/// automatically rather than leaving hundreds of snapshot requests queued behind the visible ones.
struct RouteThumbnailView: View {
    /// Only the renderer, not the whole model: a table cell is hosted detached and cannot read
    /// the environment, and this view has no other dependency.
    let renderer: RouteThumbnailRenderer
    let workoutID: String
    let hasRoute: Bool
    let hasDetail: Bool
    let isIndoor: Bool?
    var size = CGSize(width: 96, height: 56)

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    private var key: RouteThumbnailRenderer.Key {
        RouteThumbnailRenderer.Key(
            workoutID: workoutID,
            width: Int(size.width),
            height: Int(size.height),
            isDark: colorScheme == .dark
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .accessibilityLabel("Route map")
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 6))
        .task(id: key) {
            // A cache hit avoids even a frame of placeholder on re-scroll. Synchronous: the
            // renderer is main-actor isolated, same as this view.
            if let hit = renderer.cached(key) {
                image = hit
                return
            }
            image = nil
            image = await renderer.thumbnail(for: key)
        }
    }

    /// Four distinct absences, each meaning something different.
    ///
    /// The order matters, and getting it wrong was visible and wrong: `hasRoute` is `false` after
    /// a list-pass sync because that pass is fetched with `includeRoutes: false`, so it means
    /// **unknown**, not "no route". Keying the indoor icon off it labelled every outdoor ride as
    /// indoor. Indoor-ness comes from `isIndoor`, which the list pass does provide.
    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if isIndoor == true {
                Image(systemName: "house")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Indoor workout")
            } else if !hasDetail {
                Image(systemName: "arrow.down.circle.dotted")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Route not downloaded yet")
            } else if !hasRoute {
                Image(systemName: "mappin.slash")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("No route recorded")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
