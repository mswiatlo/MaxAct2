import Foundation
import SwiftData

/// One-time repairs over stored workouts. Split out of `WorkoutStore.swift` (issue 42).
extension WorkoutStore {
    /// Marks workouts whose stored heart rate is too sparse (``WorkoutSeries/heartRateIsSparse``)
    /// as needing detail again, so the next detail download re-fetches them — now with the dense
    /// heart rate. Only workouts that had a heart rate at all (an average in the summary); the rest
    /// would come back just as empty. Returns their ids. Loads every series, so run it once.
    @discardableResult
    public func markSparseHeartRateForRedownload(seriesStore: SeriesStore) async throws -> [String] {
        var marked: [String] = []
        for record in try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.hasDetail == true }))
        where record.averageHeartRate != nil {
            guard let series = await seriesStore.loadIfAvailable(record.id),
                  WorkoutSeries.heartRateIsSparse(series.heartRate, duration: record.duration)
            else { continue }
            record.hasDetail = false
            marked.append(record.id)
        }
        if !marked.isEmpty { try modelContext.save() }
        return marked
    }

    /// Marks for re-download every workout recorded by the same source as a route that came from
    /// Strava — once, so the re-download records which parts were repaired (issue 22). Repairs
    /// made before provenance existed left no record; heart rate filled from Health's samples is
    /// indistinguishable afterwards. A Strava-filled route is recognisable (Strava's points carry
    /// no GPS accuracy, the export's always do), and only the Apple Workout app's recordings need
    /// repairs, so its source name picks out that app's workouts: measured, 36 of 464, exactly the
    /// user's Workout-app recordings. Returns their ids.
    @discardableResult
    public func markRepairedSourcesForRedownload(seriesStore: SeriesStore) async throws -> [String] {
        let withDetail = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.hasDetail == true }))
        var sources: Set<String> = []
        for record in withDetail {
            guard let source = record.sourceName, !sources.contains(source),
                  let series = await seriesStore.loadIfAvailable(record.id), !series.route.isEmpty,
                  series.provenance.isEmpty,
                  series.route.allSatisfy({ $0.horizontalAccuracyMeters == nil })
            else { continue }
            sources.insert(source)
        }
        let marked = withDetail.filter { $0.sourceName.map(sources.contains) == true }
        for record in marked { record.hasDetail = false }
        if !marked.isEmpty { try modelContext.save() }
        return marked.map(\.id)
    }

    /// Reconciles the `hasDetail` flags against what is actually on disk. Cheap insurance against
    /// the database and the blob directory drifting apart — a blob deleted outside the app, or a
    /// database restored from backup.
    @discardableResult
    public func reconcileDetailFlags(with seriesStore: SeriesStore) async throws -> Int {
        var corrected = 0
        for record in try modelContext.fetch(FetchDescriptor<WorkoutRecord>()) {
            let onDisk = await seriesStore.has(record.id)
            if record.hasDetail != onDisk {
                record.hasDetail = onDisk
                corrected += 1
            }
        }
        if corrected > 0 { try modelContext.save() }
        return corrected
    }
}
