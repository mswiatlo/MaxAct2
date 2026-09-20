import Foundation

/// Per-sample data on disk, one compressed file per workout.
///
/// Series are far too big for the database: a single 3.5-hour hike is 12,645 route points, and the
/// full corpus is thousands of workouts. Keeping them out of SwiftData is what lets the table
/// query stay fast, and it means the list view never pays for data it doesn't draw.
///
/// **LZFSE rather than the zlib the plan named.** Both are in Foundation; LZFSE decompresses
/// several times faster at a comparable ratio, and these blobs are read interactively — every time
/// a workout is opened, charted or exported. Health Auto Export reached the same conclusion for
/// its own `.hae` files. The extension records the choice so a future change is detectable.
public actor SeriesStore {
    public enum StoreError: Error, CustomStringConvertible {
        case notFound(workoutID: String)
        case corrupt(workoutID: String, underlying: String)

        public var description: String {
            switch self {
            case .notFound(let id): "no stored series for workout \(id)"
            case .corrupt(let id, let detail): "series for workout \(id) is unreadable: \(detail)"
            }
        }
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// - Parameter directory: defaults to
    ///   `Application Support/com.swiatlowski.MaxAct/Series`. Tests pass a temporary directory.
    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            self.directory = base
                .appending(path: "com.swiatlowski.MaxAct", directoryHint: .isDirectory)
                .appending(path: "Series", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func fileName(for workoutID: String) -> String {
        "\(workoutID).json.lzfse"
    }

    /// Public so the app can reveal a blob in Finder, and so tests can damage one on purpose.
    public func fileURL(for workoutID: String) -> URL {
        directory.appending(path: fileName(for: workoutID))
    }

    private func url(for workoutID: String) -> URL { fileURL(for: workoutID) }

    public func has(_ workoutID: String) -> Bool {
        fileManager.fileExists(atPath: url(for: workoutID).path)
    }

    @discardableResult
    public func save(_ series: WorkoutSeries) throws -> String {
        let json = try JSONEncoder().encode(series)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        let target = url(for: series.workoutID)
        // Atomic, so a crash mid-write can't leave a half-file that later reads as corrupt.
        try compressed.write(to: target, options: .atomic)
        return fileName(for: series.workoutID)
    }

    /// Throws ``StoreError/notFound(workoutID:)`` when absent — callers should treat that as
    /// "detail not fetched yet", which is a normal state under lazy detail fetching, not an error
    /// worth surfacing.
    public func load(_ workoutID: String) throws -> WorkoutSeries {
        let target = url(for: workoutID)
        guard fileManager.fileExists(atPath: target.path) else {
            throw StoreError.notFound(workoutID: workoutID)
        }
        do {
            let compressed = try Data(contentsOf: target)
            let json = try (compressed as NSData).decompressed(using: .lzfse) as Data
            return try JSONDecoder().decode(WorkoutSeries.self, from: json)
        } catch {
            throw StoreError.corrupt(workoutID: workoutID, underlying: "\(error)")
        }
    }

    /// Non-throwing convenience for views: a missing or damaged blob degrades to "no series"
    /// rather than taking the detail pane down with it.
    public func loadIfAvailable(_ workoutID: String) -> WorkoutSeries? {
        try? load(workoutID)
    }

    public func delete(_ workoutID: String) throws {
        let target = url(for: workoutID)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    /// Total bytes on disk, for a settings screen that reports cache size.
    public func totalBytes() throws -> Int {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
