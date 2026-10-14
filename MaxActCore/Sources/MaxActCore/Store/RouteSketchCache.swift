import Foundation

/// The heat map's route sketches, kept on disk so they're built once (issue 15).
///
/// Measured: loading all 418 of the user's series took 7.4 s and simplifying them 1.7 s (debug).
/// Too slow for every visit to Statistics, so sketches are built once, saved in one compressed
/// file, and afterwards only workouts missing from it are loaded.
public actor RouteSketchCache {
    /// Bumped when what a sketch holds, or how it's made, changes — an old file is then rebuilt.
    static let version = 1

    private struct File: Codable {
        let version: Int
        let sketches: [String: RouteSketch]
        /// Workouts known to have no usable route, so they aren't reloaded every time.
        let noRoute: Set<String>
    }

    private let url: URL
    private var sketches: [String: RouteSketch] = [:]
    private var noRoute: Set<String> = []
    private var loaded = false

    /// - Parameter directory: defaults to `Application Support/com.swiatlowski.MaxAct`.
    public init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "com.swiatlowski.MaxAct", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appending(path: "route-sketches.json.lzfse")
    }

    /// Sketches for `workoutIDs`, building any that are missing from `seriesStore`.
    /// `progress` reports (done, total) for the ones that had to be built.
    public func sketches(
        for workoutIDs: [String], seriesStore: SeriesStore,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> [RouteSketch] {
        loadIfNeeded()
        let missing = workoutIDs.filter { sketches[$0] == nil && !noRoute.contains($0) }
        for (index, id) in missing.enumerated() {
            if let series = try? await seriesStore.load(id), let sketch = RouteSketch(series: series) {
                sketches[id] = sketch
            } else if await seriesStore.has(id) {
                noRoute.insert(id)   // has detail, but no usable route
            }
            await progress(index + 1, missing.count)
        }
        if !missing.isEmpty { save() }
        return workoutIDs.compactMap { sketches[$0] }
    }

    /// Forget everything — for when the library itself is deleted.
    public func clear() {
        sketches = [:]
        noRoute = []
        loaded = true
        try? FileManager.default.removeItem(at: url)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let compressed = try? Data(contentsOf: url),
              let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let file = try? JSONDecoder().decode(File.self, from: json),
              file.version == Self.version
        else { return }
        sketches = file.sketches
        noRoute = file.noRoute
    }

    private func save() {
        guard let json = try? JSONEncoder().encode(File(version: Self.version, sketches: sketches, noRoute: noRoute)),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        try? compressed.write(to: url, options: .atomic)
    }
}
