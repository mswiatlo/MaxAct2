import AppKit
import MapKit
import MaxActCore
import SwiftUI

/// Renders and caches the little route maps shown in the table.
///
/// The rule this exists to enforce: **never put a live `Map` in a table row.** A few hundred rows
/// each hosting a MapKit view would allocate a renderer apiece and make scrolling miserable. A row
/// here shows a plain `Image` of a bitmap, rendered once per (workout, size, appearance) and then
/// cached on disk indefinitely.
///
/// Three layers, cheapest first: an in-memory `NSCache`, a PNG on disk, then an actual render.
///
/// **`@MainActor`, not an `actor`.** `NSImage` and `MKMapSnapshotter.Snapshot` are both
/// main-actor-isolated in the macOS 26 SDK, so an actor here would mean sending non-`Sendable`
/// AppKit types across isolation boundaries — which Swift 6 correctly rejects. The genuinely
/// expensive work happens elsewhere anyway: tile fetching inside MapKit, blob loading on
/// `SeriesStore`'s actor, and simplification in a `nonisolated` function. What remains on the main
/// actor is stroking a few hundred points into a 96×56 bitmap, which is sub-millisecond.
@MainActor
final class RouteThumbnailRenderer {
    struct Key: Hashable {
        let workoutID: String
        let width: Int
        let height: Int
        let isDark: Bool
        /// Part of the identity, not merely a draw parameter: thumbnails are cached on disk
        /// indefinitely, so without this a colour change would leave every existing thumbnail in
        /// the old colour until something else happened to invalidate it.
        let routeColor: RouteColor
        /// What the route is coloured by (issue 31), and — only when that's heart rate — the
        /// profile's resting and maximum, since they move the zones. Both part of the identity
        /// for the same reason as the colour.
        var coloring: RouteColoring = .solid
        var zoneProfile: ZoneProfile?

        struct ZoneProfile: Hashable {
            let resting: Double
            let maximum: Double
        }

        /// Bump when anything about *how* the track is drawn changes, as opposed to what is drawn
        /// from. `2` introduced `RouteQuality` filtering: a single spurious fix can be a 20-pixel
        /// spur on a 96-pixel thumbnail, so images cached before it had to be redrawn rather than
        /// left showing an artifact the detail map no longer has. `3` added the out-and-back rule,
        /// which removes a 2.5 km spur from at least one real ride.
        static let drawingVersion = 3

        var fileName: String {
            "\(workoutID)-\(width)x\(height)-\(isDark ? "dark" : "light")"
                + "-\(routeColor.cacheToken)" + coloringToken + "-v\(Self.drawingVersion).png"
        }
        private var coloringToken: String {
            guard coloring != .solid else { return "" }
            return "-\(coloring.rawValue)" + (zoneProfile.map { "-\(Int($0.resting))-\(Int($0.maximum))" } ?? "")
        }
        var cacheKey: NSString { fileName as NSString }
    }

    private let seriesStore: SeriesStore
    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()

    /// MapKit's snapshotter is a shared, rate-limited resource: too many at once makes every one
    /// slower and eventually starts failing outright.
    private let concurrencyLimit = 3
    private var running = 0

    /// - Parameter directory: defaults to `Application Support/com.swiatlowski.MaxAct/Thumbnails`.
    ///   Injectable because this was previously hardcoded, which meant UI tests — otherwise
    ///   carefully isolated onto a throwaway database and defaults domain — were still reading
    ///   and writing the user's real thumbnail cache.
    init(seriesStore: SeriesStore, directory: URL? = nil) throws {
        self.seriesStore = seriesStore
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            self.directory = base
                .appending(path: "com.swiatlowski.MaxAct", directoryHint: .isDirectory)
                .appending(path: "Thumbnails", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    /// Clears both cache layers. Thumbnails are derived data, so this is always safe — they
    /// regenerate from the stored series on next display.
    @discardableResult
    func deleteAll() throws -> Int {
        memory.removeAllObjects()
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        for file in files { try FileManager.default.removeItem(at: file) }
        return files.count
    }

    /// Drops one workout's thumbnails, every size and appearance — for when its route changed.
    func delete(workoutID: String) {
        memory.removeAllObjects()   // NSCache can't be enumerated; it refills from disk quickly
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("\(workoutID)-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// A synchronous cache peek, so a row re-scrolled into view draws immediately instead of
    /// flashing a placeholder for a frame.
    func cached(_ key: Key) -> NSImage? {
        memory.object(forKey: key.cacheKey)
    }

    /// Cached image, or a fresh render. `nil` means no route is stored yet — under lazy detail
    /// fetching that is an ordinary state, not a failure.
    func thumbnail(for key: Key) async -> NSImage? {
        if let hit = memory.object(forKey: key.cacheKey) { return hit }

        let file = directory.appending(path: key.fileName)
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key.cacheKey)
            return image
        }

        guard let series = await seriesStore.loadIfAvailable(key.workoutID) else { return nil }
        guard let prepared = Self.prepare(series, key: key, routeColor: key.routeColor) else {
            return nil
        }
        if Task.isCancelled { return nil }

        guard await acquireSlot() else { return nil }
        let rendered = await snapshotPNG(prepared.strokes, bounds: prepared.bounds, key: key)
        running -= 1
        if Task.isCancelled { return nil }

        let size = NSSize(width: key.width, height: key.height)
        // Tiles are a nicety; the shape is the point. Offline, or with the snapshotter refusing
        // under load, draw the line alone rather than showing nothing.
        let image = rendered.flatMap(NSImage.init(data:))
            ?? polylineOnly(prepared.strokes, bounds: prepared.bounds, size: size, isDark: key.isDark)
        guard let image else { return nil }

        memory.setObject(image, forKey: key.cacheKey)
        if let png = rendered ?? image.pngData { try? png.write(to: file, options: .atomic) }
        return image
    }

    /// Simplification and bounds are pure maths on value types, so they need no isolation and can
    /// run wherever the caller happens to be.
    /// One stretch of the line in one colour: the whole route when solid, or each shade's
    /// stretch when coloured (issue 31).
    struct Stroke {
        let coordinates: [Coordinate]
        let color: NSColor
    }

    private static func prepare(
        _ series: WorkoutSeries, key: Key, routeColor: RouteColor
    ) -> (strokes: [Stroke], bounds: CoordinateBounds)? {
        let route = series.cleanedRoute
        let coordinates = route.map(\.coordinate)
        guard coordinates.count >= 2, let bounds = CoordinateBounds(coordinates) else { return nil }
        let profile = key.zoneProfile.flatMap {
            HeartRateProfile(resting: $0.resting, maximum: $0.maximum, curve: .male)   // the curve doesn't move zones
        }
        if let gradient = RouteGradient(key.coloring, route: route, heartRate: series.heartRate, profile: profile) {
            let strokes = gradient.simplified(fittingPixels: key.width).map {
                Stroke(coordinates: $0.coordinates, color: NSColor($0.shade.color))
            }
            return (strokes, bounds)
        }
        return ([Stroke(coordinates: RouteSimplifier.simplify(coordinates, fittingPixels: key.width),
                        color: NSColor(routeColor))], bounds)
    }

    /// Takes the snapshot and draws the route onto it, returning **PNG bytes**.
    ///
    /// The drawing happens inside the completion handler rather than after it because
    /// `MKMapSnapshotter.Snapshot` is not `Sendable` and cannot be carried out through a
    /// continuation. `Data` can.
    private func snapshotPNG(
        _ strokes: [Stroke], bounds: CoordinateBounds, key: Key
    ) async -> Data? {
        let options = MKMapSnapshotter.Options()
        // Tighter framing than the detail map: at 96×56 the track needs the pixels more than it
        // needs breathing room.
        options.region = MKCoordinateRegion(fitting: bounds, headroom: 1.25, minimumSpan: 0.002)
        options.size = NSSize(width: key.width, height: key.height)
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        options.appearance = NSAppearance(named: key.isDark ? .darkAqua : .aqua)

        let snapshotter = MKMapSnapshotter(options: options)
        let size = NSSize(width: key.width, height: key.height)
        let png: Data? = await withCheckedContinuation { continuation in
            // The no-queue overload's handler is declared `@MainActor @Sendable`, so calling it
            // from here keeps Snapshot on the main actor and it never crosses a boundary. The
            // `start(with:completionHandler:)` overload does not, and rejects this outright.
            snapshotter.start { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: Self.draw(strokes, over: snapshot, size: size).pngData
                )
            }
        }
        // `start` is the snapshotter's last use, so ARC is free to release it the moment the call
        // returns, and a deallocated snapshotter never calls back. Retaining it across the await
        // is the documented way to use this API.
        //
        // Added while chasing thumbnails that never appeared, but **not confirmed to have been
        // the cause**: removing it again and re-running `testSeededRoutesRenderThumbnails` still
        // passes. The actual fix was more likely the throttle rewrite or the `.task(id:)` retry
        // in the same round. Kept because it is correct regardless; don't cite it as the fix.
        withExtendedLifetime(snapshotter) {}
        return png
    }

    private static func draw(
        _ strokes: [Stroke], over snapshot: MKMapSnapshotter.Snapshot, size: NSSize
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        snapshot.image.draw(in: NSRect(origin: .zero, size: size))
        stroke(strokes) { coordinate in
            snapshot.point(for: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        image.unlockFocus()
        return image
    }

    /// Draws the strokes: first a dark casing under the whole line, which keeps it legible over
    /// both parkland and city blocks, then each stretch in its colour.
    private static func stroke(_ strokes: [Stroke], casing: Bool = true, at point: (Coordinate) -> NSPoint) {
        let paths = strokes.map { stroke -> (NSBezierPath, NSColor) in
            let path = NSBezierPath()
            for (index, coordinate) in stroke.coordinates.enumerated() {
                index == 0 ? path.move(to: point(coordinate)) : path.line(to: point(coordinate))
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            return (path, stroke.color)
        }
        if casing {
            NSColor.black.withAlphaComponent(0.35).setStroke()
            for (path, _) in paths { path.lineWidth = 4; path.stroke() }
        }
        for (path, color) in paths { path.lineWidth = 2; color.setStroke(); path.stroke() }
    }

    private func polylineOnly(
        _ strokes: [Stroke], bounds: CoordinateBounds, size: NSSize, isDark: Bool
    ) -> NSImage? {
        guard strokes.reduce(0, { $0 + $1.coordinates.count }) >= 2 else { return nil }
        let scale = cos(bounds.centre.latitude * .pi / 180)
        let spanX = max(bounds.longitudeSpan * scale, 1e-9)
        let spanY = max(bounds.latitudeSpan, 1e-9)
        let inset: CGFloat = 6
        let usable = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let fit = min(usable.width / spanX, usable.height / spanY)
        let offsetX = (usable.width - spanX * fit) / 2
        let offsetY = (usable.height - spanY * fit) / 2

        let image = NSImage(size: size)
        image.lockFocus()
        (isDark ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        NSRect(origin: .zero, size: size).fill()

        Self.stroke(strokes, casing: false) { coordinate in
            NSPoint(x: inset + offsetX + (coordinate.longitude - bounds.minLongitude) * scale * fit,
                    y: inset + offsetY + (coordinate.latitude - bounds.minLatitude) * fit)
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Throttle

    /// Waits for a rendering slot. Returns `false` if the task was cancelled while waiting.
    ///
    /// **Polls rather than queueing continuations, deliberately.** The first version parked
    /// waiters in `CheckedContinuation`s resumed by whoever finished next. Scrolling cancels
    /// thumbnail tasks constantly, and a task cancelled while parked never resumed — so once
    /// waiters outnumbered future completions they hung forever, `running` stayed pinned at the
    /// limit, and *every* later thumbnail wedged on its spinner. A cancellation-correct semaphore
    /// is possible but fiddly; a 30 ms poll is trivially correct and costs nothing, because this
    /// only runs while thumbnails are actually being generated and each one is cached for good.
    private func acquireSlot() async -> Bool {
        while running >= concurrencyLimit {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if Task.isCancelled { return false }
        running += 1
        return true
    }
}

extension NSImage {
    @MainActor
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension NSColor {
    /// Bridges the model's colour choice into AppKit. Here so the components are converted in
    /// exactly one place, shared by the thumbnail renderer and the detail map.
    convenience init(_ routeColor: RouteColor) {
        let (red, green, blue) = routeColor.components
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension Color {
    init(_ routeColor: RouteColor) {
        let (red, green, blue) = routeColor.components
        self.init(.sRGB, red: red, green: green, blue: blue)
    }
}
