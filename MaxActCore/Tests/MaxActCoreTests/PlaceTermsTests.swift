import Foundation
import Testing

@testable import MaxActCore

@Suite struct PlaceTermsTests {
    private func vancouver() -> PlaceDescription {
        PlaceDescription(city: "Greater Vancouver", subdivision: "BC",
                         country: "Canada", countryCode: "CA")
    }

    @Test("the subdivision is searchable both as given and expanded")
    func expandsSubdivision() {
        let terms = try! #require(PlaceTerms.searchTerms(for: vancouver()))
        for needle in ["greater vancouver", "bc", "british columbia", "canada"] {
            #expect(terms.contains(needle), "\(needle) should be searchable, terms were \(terms)")
        }
    }

    @Test("the ISO country code is deliberately not a term")
    func noCountryCode() {
        // "CA", "IN" and "US" are short enough to appear inside unrelated words under a substring
        // match. The country name already covers what someone means by typing them.
        let terms = try! #require(PlaceTerms.searchTerms(for: vancouver()))
        #expect(!terms.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("ca"))
    }

    @Test("terms are folded, so accents and case don't have to be typed")
    func folding() {
        let geneva = PlaceDescription(city: "Genève", subdivision: "GE",
                                      country: "Switzerland", countryCode: "CH")
        let terms = try! #require(PlaceTerms.searchTerms(for: geneva))
        #expect(terms.contains("geneve"))
        #expect(terms.contains("switzerland"))
    }

    @Test("collisions resolve by country: WA is Washington or Western Australia")
    func collidingAbbreviations() {
        #expect(PlaceTerms.subdivisionName("WA", countryCode: "US") == "Washington")
        #expect(PlaceTerms.subdivisionName("WA", countryCode: "AU") == "Western Australia")
        #expect(PlaceTerms.subdivisionName("NT", countryCode: "CA") == "Northwest Territories")
        #expect(PlaceTerms.subdivisionName("NT", countryCode: "AU") == "Northern Territory")
    }

    @Test("a subdivision that is already a name is left alone, not dropped")
    func unknownSubdivision() {
        // The UK's geocoder gives "Scotland", not a code — there is nothing to expand, and the
        // value still has to end up searchable.
        let edinburgh = PlaceDescription(city: "Edinburgh", subdivision: "Scotland",
                                         country: "United Kingdom", countryCode: "GB")
        #expect(PlaceTerms.subdivisionName("Scotland", countryCode: "GB") == nil)
        let terms = try! #require(PlaceTerms.searchTerms(for: edinburgh))
        #expect(terms.contains("scotland"))
        #expect(terms.contains("united kingdom"))
    }

    @Test("an unknown code in an uncovered country is still stored as given")
    func uncoveredCountry() {
        #expect(PlaceTerms.subdivisionName("GE", countryCode: "CH") == nil, "no Swiss table")
        let terms = try! #require(PlaceTerms.searchTerms(for:
            PlaceDescription(city: nil, subdivision: "GE", country: "Switzerland", countryCode: "CH")))
        #expect(terms.contains("ge"))
    }

    @Test("nothing known means no terms, rather than an empty string")
    func emptyDescription() {
        let nothing = PlaceDescription(city: nil, subdivision: nil, country: nil, countryCode: nil)
        #expect(nothing.isEmpty)
        #expect(PlaceTerms.searchTerms(for: nothing) == nil)
        #expect(PlaceTerms.searchTerms(for:
            PlaceDescription(city: "  ", subdivision: nil, country: nil, countryCode: nil)) == nil)
    }

    @Test("a term is not repeated when the parts agree")
    func noDuplicates() {
        // Singapore and the like: city and country are the same word.
        let terms = try! #require(PlaceTerms.searchTerms(for:
            PlaceDescription(city: "Singapore", subdivision: nil,
                             country: "Singapore", countryCode: "SG")))
        #expect(terms == "singapore")
    }
}

@Suite struct WorkoutSearchTests {
    private func item(place: String?, terms: String?, tags: [String] = []) -> WorkoutListItem {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = WorkoutRecord(workout: Workout(
            id: "A", kind: .cycling, start: start, end: start.addingTimeInterval(3600),
            duration: 3600, sourceName: "Maximilian's Apple Watch"
        ))
        record.placeLabel = place
        record.placeSearchTerms = terms
        record.tagNames = tags
        return WorkoutListItem(record: record)
    }

    private var vancouver: WorkoutListItem {
        item(place: "Greater Vancouver BC",
             terms: PlaceTerms.searchTerms(for: PlaceDescription(
                city: "Greater Vancouver", subdivision: "BC",
                country: "Canada", countryCode: "CA")))
    }

    @Test("a region or country finds a ride whose label names only the city")
    func findsByRegionAndCountry() {
        for needle in ["BC", "British Columbia", "british columbia", "Canada", "vancouver"] {
            #expect(vancouver.matches(searchText: needle), "\(needle) should match")
        }
    }

    @Test("an unrelated place doesn't match")
    func doesNotOvermatch() {
        #expect(!vancouver.matches(searchText: "Switzerland"))
        #expect(!vancouver.matches(searchText: "Ontario"))
    }

    @Test("accents need not be typed, in either direction")
    func diacritics() {
        let geneva = item(place: "Genève", terms: PlaceTerms.searchTerms(for: PlaceDescription(
            city: "Genève", subdivision: nil, country: "Switzerland", countryCode: "CH")))
        #expect(geneva.matches(searchText: "geneve"))
        #expect(geneva.matches(searchText: "Genève"))
        #expect(geneva.matches(searchText: "switzerland"))
    }

    @Test("the other searchable fields still work, and still ignore case")
    func otherFields() {
        let tagged = item(place: nil, terms: nil, tags: ["With Kid"])
        #expect(tagged.matches(searchText: "with kid"))
        #expect(tagged.matches(searchText: "CYCLING"))
        #expect(tagged.matches(searchText: "apple watch"))
        #expect(tagged.matches(searchText: ""), "an empty search matches everything")
        #expect(!tagged.matches(searchText: "running"))
    }

    @Test("a workout with no place at all is simply not matched by a place")
    func noPlace() {
        #expect(!item(place: nil, terms: nil).matches(searchText: "Canada"))
    }
}

/// Reading the subdivision out of MapKit's formatted city string — the only non-deprecated source
/// on macOS 26. Every input here is a string MapKit actually returned, measured 2026-10-10.
@Suite struct SubdivisionParsingTests {
    @Test("the province or state is what's left between city and country")
    func measuredStrings() {
        #expect(PlaceTerms.subdivision(inCityContext: "Vancouver BC Canada", city: "Vancouver", country: "Canada") == "BC")
        #expect(PlaceTerms.subdivision(inCityContext: "North Vancouver BC, Canada", city: "North Vancouver", country: "Canada") == "BC")
        #expect(PlaceTerms.subdivision(inCityContext: "Toronto ON Canada", city: "Toronto", country: "Canada") == "ON")
        #expect(PlaceTerms.subdivision(inCityContext: "Seattle, WA United States", city: "Seattle", country: "United States") == "WA")
        // The UK names the nation, and the country isn't repeated at the end.
        #expect(PlaceTerms.subdivision(inCityContext: "Edinburgh, Scotland", city: "Edinburgh", country: "United Kingdom") == "Scotland")
    }

    @Test("no subdivision is reported as none, not guessed")
    func nothingToFind() {
        // Geneva's string carries the country only.
        #expect(PlaceTerms.subdivision(inCityContext: "Geneva, Switzerland", city: "Geneva", country: "Switzerland") == nil)
        // UBC, outside any municipality, comes back empty.
        #expect(PlaceTerms.subdivision(inCityContext: "", city: "Vancouver", country: "Canada") == nil)
        #expect(PlaceTerms.subdivision(inCityContext: nil, city: "Vancouver", country: "Canada") == nil)
        // A string that doesn't start with the city can't be split safely.
        #expect(PlaceTerms.subdivision(inCityContext: "Somewhere BC Canada", city: "Vancouver", country: "Canada") == nil)
    }

    @Test("country names map to the codes the subdivision table is keyed by")
    func countryCodes() {
        let english = Locale(identifier: "en_US")
        #expect(PlaceTerms.countryCode(forName: "Canada", locale: english) == "CA")
        #expect(PlaceTerms.countryCode(forName: "United States", locale: english) == "US")
        #expect(PlaceTerms.countryCode(forName: "Switzerland", locale: english) == "CH")
        #expect(PlaceTerms.countryCode(forName: "United Kingdom", locale: english) == "GB")
        #expect(PlaceTerms.countryCode(forName: "Atlantis", locale: english) == nil)
    }

    @Test("parsed and mapped, the parts give the same search terms as before")
    func endToEnd() {
        let subdivision = PlaceTerms.subdivision(inCityContext: "Vancouver BC Canada", city: "Vancouver", country: "Canada")
        let terms = PlaceTerms.searchTerms(for: PlaceDescription(
            city: "Vancouver", subdivision: subdivision, country: "Canada",
            countryCode: PlaceTerms.countryCode(forName: "Canada", locale: Locale(identifier: "en_US"))))
        #expect(terms == "vancouver · bc · british columbia · canada")
    }
}

/// Lending a subdivision to places MapKit reported without one — UBC, which comes back as city
/// "Vancouver", country "Canada", and nothing else.
@Suite struct SubdivisionBorrowingTests {
    private func place(_ city: String?, _ subdivision: String?, _ country: String?) -> PlaceDescription {
        PlaceDescription(city: city, subdivision: subdivision, country: country,
                         countryCode: PlaceTerms.countryCode(forName: country, locale: Locale(identifier: "en_US")))
    }

    @Test("a city whose places agree lends its subdivision")
    func agreeingCityLends() {
        let lendable = PlaceTerms.lendableSubdivisions(from: [
            place("Vancouver", "BC", "Canada"), place("Vancouver", "BC", "Canada"),
            place("Vancouver", nil, "Canada"),
        ])
        let ubc = PlaceTerms.borrowingSubdivision(for: place("Vancouver", nil, "Canada"), from: lendable)
        #expect(ubc?.subdivision == "BC")
        #expect(ubc.flatMap(PlaceTerms.searchTerms(for:)) == "vancouver · bc · british columbia · canada")
    }

    @Test("a city whose places disagree lends nothing — no guessing")
    func ambiguousCityDoesNot() {
        // Same name, same country, different provinces.
        let lendable = PlaceTerms.lendableSubdivisions(from: [
            place("Richmond", "BC", "Canada"), place("Richmond", "ON", "Canada"),
        ])
        #expect(PlaceTerms.borrowingSubdivision(for: place("Richmond", nil, "Canada"), from: lendable) == nil)
    }

    @Test("a different country is a different city")
    func countryMatters() {
        let lendable = PlaceTerms.lendableSubdivisions(from: [place("Vancouver", "WA", "United States")])
        #expect(PlaceTerms.borrowingSubdivision(for: place("Vancouver", nil, "Canada"), from: lendable) == nil)
    }

    @Test("nothing to lend, nothing borrowed; a place that has one keeps its own")
    func edges() {
        #expect(PlaceTerms.borrowingSubdivision(for: place("Vancouver", nil, "Canada"), from: [:]) == nil)
        let lendable = PlaceTerms.lendableSubdivisions(from: [place("Vancouver", "BC", "Canada")])
        #expect(PlaceTerms.borrowingSubdivision(for: place("Vancouver", "XX", "Canada"), from: lendable) == nil)
        #expect(PlaceTerms.borrowingSubdivision(for: place(nil, nil, "Canada"), from: lendable) == nil)
    }

    @Test("matching ignores case and accents")
    func folded() {
        let lendable = PlaceTerms.lendableSubdivisions(from: [place("Montréal", "QC", "Canada")])
        #expect(PlaceTerms.borrowingSubdivision(for: place("montreal", nil, "canada"), from: lendable)?
            .subdivision == "QC")
    }
}

@Suite struct SubdivisionBorrowingStoreTests {
    private func store() throws -> WorkoutStore {
        try inMemoryStore()
    }

    private func ingested(_ id: String) -> IngestedWorkout {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return IngestedWorkout(
            workout: Workout(id: id, kind: .cycling, start: start, end: start.addingTimeInterval(1800), duration: 1800),
            series: WorkoutSeries(workoutID: id))
    }

    private let canada = "Canada"

    @Test("the UBC ride borrows BC from a Vancouver ride, whichever resolved first")
    func ubcBorrowsBC() async throws {
        let store = try store()
        try await store.upsert([ingested("UBC"), ingested("KITS")])
        // UBC resolves first, with what MapKit actually gives it: a city and a country.
        try await store.setPlace(label: "Vancouver", parts: PlaceDescription(
            city: "Vancouver", subdivision: nil, country: canada, countryCode: "CA"), for: "UBC")
        #expect(try await store.borrowMissingSubdivisions() == 0, "nothing to borrow from yet")

        try await store.setPlace(label: "Vancouver BC", parts: PlaceDescription(
            city: "Vancouver", subdivision: "BC", country: canada, countryCode: "CA"), for: "KITS")
        #expect(try await store.borrowMissingSubdivisions() == 1)

        let ubc = try #require(try await store.item(id: "UBC"))
        #expect(ubc.placeLabel == "Vancouver BC", "the bare-city label gains the province")
        for search in ["BC", "British Columbia", "Canada"] {
            #expect(ubc.matches(searchText: search), "\(search) should find the UBC ride")
        }
        #expect(try await store.borrowMissingSubdivisions() == 0, "idempotent")
    }

    @Test("a label MapKit composed itself is kept when a subdivision is borrowed")
    func composedLabelKept() async throws {
        let store = try store()
        try await store.upsert([ingested("A"), ingested("B")])
        try await store.setPlace(label: "Somewhere special", parts: PlaceDescription(
            city: "Vancouver", subdivision: nil, country: canada, countryCode: "CA"), for: "A")
        try await store.setPlace(label: "Vancouver BC", parts: PlaceDescription(
            city: "Vancouver", subdivision: "BC", country: canada, countryCode: "CA"), for: "B")
        try await store.borrowMissingSubdivisions()
        let a = try #require(try await store.item(id: "A"))
        #expect(a.placeLabel == "Somewhere special")
        #expect(a.matches(searchText: "British Columbia"))
    }
}
