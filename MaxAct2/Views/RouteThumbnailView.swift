import MaxActCore
import SwiftUI

/// A table row's route map. An `Image` of a pre-rendered bitmap — never a live `Map`.
///
/// Rendering is requested in `.task(id:)`, so scrolling a row out of view cancels its render
/// automatically rather than leaving hundreds of snapshot requests queued behind the visible ones.
struct RouteThumbnailView: View {
    let workoutID: String
    let hasRoute: Bool
    let hasDetail: Bool
    var size = CGSize(width: 96, height: 56)

    @Environment(AppModel.self) private var model
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
            if let hit = model.thumbnails.cached(key) {
                image = hit
                return
            }
            image = nil
            image = await model.thumbnails.thumbnail(for: key)
        }
    }

    /// Three distinct absences, each meaning something different to the user: no route at all
    /// (indoor), a route not yet downloaded, or a route being drawn.
    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if !hasRoute {
                Image(systemName: "house")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Indoor, no route")
            } else if !hasDetail {
                Image(systemName: "arrow.down.circle.dotted")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Route not downloaded")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
