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

    /// What one cell resolves to: the short label the column shows, and the parts — city,
    /// subdivision, country — that search terms are built from and that borrowing compares.
    struct Place {
        let label: String
        let parts: PlaceDescription?
        /// MapKit's zone for the place ("Europe/Zurich"), which Strava names are read in.
        var timeZone: String? = nil
    }

    /// Snapped-cell key → resolved place. The reason a corpus costs a request per *place*.
    private var resolved: [String: Place] = [:]

    /// Cells that came back with nothing. Retried on a later launch but not again this session —
    /// a start in the middle of a park or a bay legitimately has no city, and asking again in a
    /// second won't change that.
    private var unresolvable: Set<String> = []

    /// Between network requests only; a cache hit waits for nothing.
    private let requestInterval: Duration
    private var lastRequest: ContinuousClock.Instant?

    /// Stop after this many consecutive failures. A geocoder that has started refusing won't be
    /// talked round by continuing to ask, and a silent hour of retries is worse than stopping.
    private let failureLimit = 3

    /// Tests stand in for MapKit here, and skip the throttle.
    private let lookUpOverride: (@Sendable (Coordinate) async -> Outcome)?

    init(store: WorkoutStore, requestInterval: Duration = .seconds(1),
         lookUp: (@Sendable (Coordinate) async -> Outcome)? = nil) {
        self.store = store
        self.requestInterval = requestInterval
        lookUpOverride = lookUp
    }

    /// Resolves every workout that has a coarse start but no name yet.
    ///
    /// Returns how many names were newly stored, so the caller knows whether to refresh the table.
    /// Cancellation is honoured between workouts — this can run for minutes on a first import.
    @discardableResult
    func resolvePending(limit: Int? = nil) async -> Int {
        var stored = 0
        let size = limit ?? 200
        var offset = 0
        // Re-query between batches. A detail backfill stores routes while this is running, so
        // workouts become pending *during* the run; a single up-front fetch would leave them
        // until the next launch.
        while !Task.isCancelled {
            let batch = (try? await store.itemsNeedingPlace(limit: size, offset: offset)) ?? []
            guard !batch.isEmpty else { break }
            let (batchStored, exhausted) = await resolve(batch)
            stored += batchStored
            if exhausted || batch.count < size { break }
            // Named rows leave the pending set; the rest stay, so step past them. Stopping at a
            // batch with nothing named instead (issue 38) let 200 starts the geocoder can't name
            // — a park you often start from — hide every older workout for good.
            offset += batch.count - batchStored
        }
        // Then fill in subdivisions MapKit didn't give, from places in the same city that have
        // one. Every time, not only after new lookups: it's a cheap local pass, and it lets a
        // place that resolved alone earlier pick up a province once a neighbour has resolved.
        let borrowed = (try? await store.borrowMissingSubdivisions()) ?? 0
        return stored + borrowed
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
                if (try? await store.setPlace(label: hit.label, parts: hit.parts, timeZone: hit.timeZone,
                                              for: entry.id)) != nil { stored += 1 }
                continue
            }

            await waitForSlot()
            switch await lookUp(entry.coordinate) {
            case .found(let place):
                resolved[key] = place
                consecutiveFailures = 0
                if (try? await store.setPlace(label: place.label, parts: place.parts, timeZone: place.timeZone,
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

    enum Outcome {
        case found(Place)
        case nothingThere
        case failed
    }

    /// Resolves one cell from a single MapKit request: the short label, and the parts that let
    /// search match a region or country.
    ///
    /// **MapKit only, and one request.** The subdivision has no supported structured source on
    /// macOS 26 — `CLGeocoder` (used at first) and `MKMapItem.placemark` both carry
    /// `administrativeArea` but are **deprecated**, and MapKit's address representations expose
    /// only formatted strings. So the subdivision is read out of `cityWithContext(.full)`
    /// (``PlaceTerms/subdivision(inCityContext:city:country:)``), which measured regular across ten
    /// places, and the country code is looked up from MapKit's country name.
    ///
    /// Reads only city-level fields. **Never `name`, `shortAddress` or `fullAddress`** — measured,
    /// those return the street address ("4629 Haggart St, Vancouver"), which is the whole thing
    /// the snapping exists to avoid.
    private func lookUp(_ coordinate: Coordinate) async -> Outcome {
        if let lookUpOverride { return await lookUpOverride(coordinate) }
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) else { return .nothingThere }

        let representations: MKAddressRepresentations
        let timeZone: String?
        do {
            let item = try await request.mapItems.first
            guard let found = item?.addressRepresentations else { return .nothingThere }
            representations = found
            // Measured: Geneva → Europe/Zurich, Chicago → America/Chicago, even a point on Lake
            // Geneva → Europe/Paris.
            timeZone = item?.timeZone?.identifier
        } catch {
            return .failed
        }

        let city = representations.cityName?.cleaned
        let country = representations.regionName?.cleaned
        let parts = PlaceDescription(
            city: city,
            subdivision: PlaceTerms.subdivision(
                inCityContext: representations.cityWithContext(.full)?.cleaned, city: city, country: country),
            country: country,
            countryCode: PlaceTerms.countryCode(forName: country)
        )

        guard let label = label(
            context: representations.cityWithContext(.automatic)?.cleaned, parts: parts
        ) else { return .nothingThere }
        return .found(Place(label: label, parts: parts.isEmpty ? nil : parts, timeZone: timeZone))
    }

    /// MapKit's own short form when it has one — "Vancouver BC", "Geneva, Switzerland" — else the
    /// city alone.
    ///
    /// Measured: `cityWithContext` comes back as an **empty string** over water and for places
    /// outside any municipality. The one seen was UBC (the University Endowment Lands), which
    /// reported a city of "Vancouver" but no context at all. Every other Canadian place tested
    /// returned "City BC"-style context. (Issue 9 first read that empty string as a "device's own
    /// region" behaviour, from that single UBC sample; ten places showed otherwise.)
    private func label(context: String?, parts: PlaceDescription) -> String? {
        if let context { return context }
        if let city = parts.city, let subdivision = parts.subdivision { return "\(city) \(subdivision)" }
        return parts.city
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
