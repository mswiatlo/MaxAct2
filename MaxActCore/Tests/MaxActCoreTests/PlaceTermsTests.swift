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
/// on macOS 26. Every input here is a string MapKit actually returned, measured 2026-10-11.
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
