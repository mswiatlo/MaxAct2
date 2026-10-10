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

    /// What one cell resolves to: the short label the column shows, and the hidden terms that let
    /// search match a region or country.
    private struct Place {
        let label: String
        let searchTerms: String?
    }

    /// Snapped-cell key → resolved place. The reason a corpus costs a request per *place*.
    private var resolved: [String: Place] = [:]

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
                if (try? await store.setPlace(label: hit.label, searchTerms: hit.searchTerms,
                                              for: entry.id)) != nil { stored += 1 }
                continue
            }

            await waitForSlot()
            switch await lookUp(entry.coordinate) {
            case .found(let place):
                resolved[key] = place
                consecutiveFailures = 0
                if (try? await store.setPlace(label: place.label, searchTerms: place.searchTerms,
                                              for: entry.id)) != nil { stored += 1 }
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
        case found(Place)
        case nothingThere
        case failed
    }

    /// Resolves one cell: MapKit for the label, Core Location for the parts search needs.
    ///
    /// **Two geocoders, on purpose.** MapKit composes the label well — it knows to write
    /// "Boulder, CO United States" but "Geneva, Switzerland" — yet it exposes no structured
    /// subdivision: `regionCode` is documented but *absent from the SDK*, and `regionName` is the
    /// country. `CLPlacemark` has the structure (`locality`, `administrativeArea`, `country`,
    /// `isoCountryCode`) and no equivalent composer. So each is used for what it does well.
    ///
    /// Costs two requests per *new cell*, not per workout; both go through the same throttle, and
    /// the cache means a repeat trailhead costs nothing.
    ///
    /// Reads only city-level fields from either. **Never `name`, `shortAddress` or `fullAddress`,
    /// nor a placemark's `thoroughfare`** — measured, those return the street address
    /// ("4629 Haggart St, Vancouver"), which is the whole thing the snapping exists to avoid.
    private func lookUp(_ coordinate: Coordinate) async -> Outcome {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return .nothingThere
        }

        let context: String?
        let cityName: String?
        do {
            let items = try await request.mapItems
            guard let representations = items.first?.addressRepresentations else {
                return .nothingThere
            }
            context = representations.cityWithContext(.automatic)?.cleaned
            cityName = representations.cityName?.cleaned
        } catch {
            return .failed
        }

        // Core Location's turn. A failure here is survivable — the label is what the column needs,
        // and a later `PlaceTerms.version` bump will try the terms again.
        await waitForSlot()
        let parts = await describe(location)

        guard let label = label(context: context, cityName: cityName, parts: parts) else {
            return .nothingThere
        }
        return .found(Place(label: label, searchTerms: parts.flatMap(PlaceTerms.searchTerms(for:))))
    }

    /// Picks the most informative short label available.
    ///
    /// The order matters, and the second entry is why this isn't just MapKit's string. Measured:
    /// `cityWithContext` returns an **empty string** both for a start over water *and* for a place
    /// in the device's own region — on a Canadian Mac, Vancouver came back blank. Falling straight
    /// to `cityName` would then have quietly demoted every local label from "Greater Vancouver BC"
    /// to "Vancouver" the first time a library was re-resolved.
    private func label(context: String?, cityName: String?, parts: PlaceDescription?) -> String? {
        if let context { return context }
        if let city = parts?.city, let subdivision = parts?.subdivision {
            return "\(city) \(subdivision)"
        }
        return cityName ?? parts?.city
    }

    /// The structured half, via Core Location — the only one of the two that exposes a
    /// subdivision. Reads four city-level fields and nothing finer.
    private func describe(_ location: CLLocation) async -> PlaceDescription? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        // `CLPlacemark` is `@MainActor`-isolated under this project's default isolation, so its
        // fields are read in one hop rather than four.
        let description = await MainActor.run {
            PlaceDescription(
                city: placemark.locality?.cleaned,
                subdivision: placemark.administrativeArea?.cleaned,
                country: placemark.country?.cleaned,
                countryCode: placemark.isoCountryCode?.cleaned
            )
        }
        return description.isEmpty ? nil : description
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

private extension String {
    /// Trimmed, and `nil` rather than empty. Both geocoders return `""` often enough — over water,
    /// and for the device's own region — that storing it unchecked would leave a blank cell that
    /// never retries.
    ///
    /// `nonisolated` because the project defaults to `MainActor` isolation and this is called from
    /// inside the resolver actor.
    nonisolated var cleaned: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
