import Foundation

/// Series digests — route sketches and heart-rate histograms — kept on disk so each stored series
/// is read once (issue 15).
///
/// Measured: loading all 418 of the user's series took 7.4 s and simplifying them 1.7 s (debug).
/// Too slow for every visit to Statistics, so digests are built once, saved in one compressed
/// file, and afterwards only workouts missing from it are loaded.
public actor RouteSketchCache {
    /// Bumped when what a digest holds, or how it's made, changes — an old file is then rebuilt.
    /// 2: heart-rate histograms added beside the sketches.
    static let version = 2

    private struct File: Codable {
        let version: Int
        let digests: [String: SeriesDigest]
    }

    private let url: URL
    private var digests: [String: SeriesDigest] = [:]
    private var loaded = false

    /// - Parameter directory: defaults to `Application Support/com.swiatlowski.MaxAct`.
    public init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "com.swiatlowski.MaxAct", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appending(path: "series-digests.json.lzfse")
        // The version-1 file, sketches only, is superseded.
        try? FileManager.default.removeItem(at: base.appending(path: "route-sketches.json.lzfse"))
    }

    /// Digests for `workoutIDs`, building any that are missing from `seriesStore`. Workouts whose
    /// series isn't downloaded are skipped. `progress` reports (done, total) for those built.
    public func digests(
        for workoutIDs: [String], seriesStore: SeriesStore,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> [SeriesDigest] {
        loadIfNeeded()
        let missing = workoutIDs.filter { digests[$0] == nil }
        for (index, id) in missing.enumerated() {
            if let series = try? await seriesStore.load(id) {
                digests[id] = SeriesDigest(series: series)
            }
            await progress(index + 1, missing.count)
        }
        if !missing.isEmpty { save() }
        return workoutIDs.compactMap { digests[$0] }
    }

    /// Just the route sketches, for workouts that have one.
    public func sketches(
        for workoutIDs: [String], seriesStore: SeriesStore,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async -> [RouteSketch] {
        await digests(for: workoutIDs, seriesStore: seriesStore, progress: progress).compactMap(\.sketch)
    }

    /// Forget these workouts' digests — for when their series has been downloaded again.
    public func invalidate(_ workoutIDs: some Sequence<String>) {
        loadIfNeeded()
        var changed = false
        for id in workoutIDs where digests.removeValue(forKey: id) != nil { changed = true }
        if changed { save() }
    }

    /// Forget everything — for when the library itself is deleted.
    public func clear() {
        digests = [:]
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
        digests = file.digests
    }

    private func save() {
        guard let json = try? JSONEncoder().encode(File(version: Self.version, digests: digests)),
              let compressed = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        try? compressed.write(to: url, options: .atomic)
    }
}
