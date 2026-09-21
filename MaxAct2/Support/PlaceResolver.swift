import Foundation
import MapKit
import MaxActCore

/// Turns coarse coordinates into place names, once per place rather than once per workout.
///
/// An actor because reverse geocoding is a shared, rate-limited system service: Apple's own
/// guidance is to issue requests sparingly, and the only way to honour that is to funnel every
/// request through one place that can count them.
///
/// **Measured, so the throttle is a choice rather than a guess.** A request costs ~0.1 s and five
/// back-to-back lookups all succeeded with no sign of throttling. The delay below is therefore
/// defensive rather than observed — Apple documents a limit without publishing it, and a
/// seven-year corpus is a lot of requests to find it with. Cell caching is what actually keeps the
/// count down: repeat rides from one trailhead collapse to a single lookup.
actor PlaceResolver {
    private let store: WorkoutStore

    /// Snapped-cell key → resolved name. The reason a corpus costs a request per *place*.
    private var resolved: [String: String] = [:]

    /// Cells that came back with nothing. Retried on a later launch but not again this session —
    /// a start in the middle of a park or a bay legitimately has no city, and asking again in a
    /// second won't change that.
    private var unresolvable: Set<String> = []

    /// Between network requests only; a cache hit waits for nothing.
    private let requestInterval: Duration = .seconds(1)
    private var lastRequest: ContinuousClock.Instant?

    /// Stop after this many consecutive failures. A geocoder that has started refusing won't be
    /// talked round by continuing to ask, and a silent hour of retries is worse than stopping.
    private let failureLimit = 3

    init(store: WorkoutStore) {
        self.store = store
    }

    /// Resolves every workout that has a coarse start but no name yet.
    ///
    /// Returns how many names were newly stored, so the caller knows whether to refresh the table.
    /// Cancellation is honoured between workouts — this can run for minutes on a first import.
    @discardableResult
    func resolvePending(limit: Int? = nil) async -> Int {
        var stored = 0
        // Re-query between batches. A detail backfill stores routes while this is running, so
        // workouts become pending *during* the run; a single up-front fetch would leave them
        // until the next launch.
        while !Task.isCancelled {
            let batch = (try? await store.itemsNeedingPlace(limit: limit ?? 200)) ?? []
            guard !batch.isEmpty else { break }
            let (batchStored, exhausted) = await resolve(batch)
            stored += batchStored
            // Nothing in that batch could be stored — every entry was already known unresolvable,
            // or the geocoder gave up. Re-querying would return the same rows for ever.
            if batchStored == 0 || exhausted { break }
        }
        return stored
    }

    /// Returns what it stored, and whether it stopped early because the geocoder kept failing.
    private func resolve(_ pending: [(id: String, coordinate: Coordinate)]) async -> (Int, Bool) {
        var stored = 0
        var consecutiveFailures = 0

        for entry in pending {
            if Task.isCancelled { break }

            let key = PlaceGrid.cacheKey(for: entry.coordinate)
            if unresolvable.contains(key) { continue }

            if let hit = resolved[key] {
                if (try? await store.setPlaceLabel(hit, for: entry.id)) != nil { stored += 1 }
                continue
            }

            await waitForSlot()
            switch await lookUp(entry.coordinate) {
            case .found(let name):
                resolved[key] = name
                consecutiveFailures = 0
                if (try? await store.setPlaceLabel(name, for: entry.id)) != nil { stored += 1 }
            case .nothingThere:
                // Not a failure — the geocoder answered, and the answer was "nowhere named".
                unresolvable.insert(key)
                consecutiveFailures = 0
            case .failed:
                consecutiveFailures += 1
                if consecutiveFailures >= failureLimit { return (stored, true) }
                // Back off before the next attempt, on top of the usual interval.
                try? await Task.sleep(for: .seconds(2 * consecutiveFailures))
            }
        }
        return (stored, false)
    }

    private enum Outcome {
        case found(String)
        case nothingThere
        case failed
    }

    /// One reverse-geocoding request.
    ///
    /// Takes only `cityWithContext(.automatic)`, which gives MapKit's own localized "Vancouver BC".
    /// **Never `name`, `shortAddress` or `fullAddress`** — measured, those return the street
    /// address ("4629 Haggart St, Vancouver"), which is the whole thing the snapping exists to
    /// avoid ever handling.
    private func lookUp(_ coordinate: Coordinate) async -> Outcome {
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) else { return .nothingThere }

        do {
            let items = try await request.mapItems
            guard let representations = items.first?.addressRepresentations else {
                return .nothingThere
            }
            // Measured: a start over water returns an *empty string* rather than nil, and storing
            // that would show a blank cell that never retries.
            let name = representations.cityWithContext(.automatic)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return .found(name) }

            let city = representations.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let city, !city.isEmpty { return .found(city) }
            return .nothingThere
        } catch {
            return .failed
        }
    }

    private func waitForSlot() async {
        let now = ContinuousClock.now
        if let lastRequest {
            let elapsed = now - lastRequest
            if elapsed < requestInterval {
                try? await Task.sleep(for: requestInterval - elapsed)
            }
        }
        lastRequest = ContinuousClock.now
    }
}
