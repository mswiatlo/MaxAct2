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
    let routeColor: RouteColor
    var size = CGSize(width: 96, height: 56)

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    /// Distinguishes "still working" from "tried and there's nothing to draw". Without it a
    /// render that legitimately yields no image leaves the spinner up for ever.
    @State private var didFinishAttempt = false

    private var key: RouteThumbnailRenderer.Key {
        RouteThumbnailRenderer.Key(
            workoutID: workoutID,
            width: Int(size.width),
            height: Int(size.height),
            isDark: colorScheme == .dark,
            routeColor: routeColor
        )
    }

    /// The `.task` identity. **Includes `hasDetail`**, which the cache key deliberately doesn't:
    /// the cache is keyed by what the image looks like, but the *work* has to be retried once the
    /// series arrives. Without this, the first attempt runs before any route is stored, returns
    /// nothing, and never runs again — the row sits on its spinner after Download Detail
    /// completes.
    private struct RenderIdentity: Hashable {
        let key: RouteThumbnailRenderer.Key
        let hasDetail: Bool
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
        .task(id: RenderIdentity(key: key, hasDetail: hasDetail)) {
            // A cache hit avoids even a frame of placeholder on re-scroll. Synchronous: the
            // renderer is main-actor isolated, same as this view.
            if let hit = renderer.cached(key) {
                image = hit
                didFinishAttempt = true
                return
            }
            image = nil
            didFinishAttempt = false
            let rendered = await renderer.thumbnail(for: key)
            // Cancellation means "scrolled away", not "nothing to draw" — leave the attempt
            // unfinished so it retries when the row comes back.
            guard !Task.isCancelled else { return }
            image = rendered
            didFinishAttempt = true
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
            } else if !hasRoute || didFinishAttempt {
                Image(systemName: "mappin.slash")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("No route recorded")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
