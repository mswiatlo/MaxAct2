import Foundation

/// The structured pieces of a coarse place, as a geocoder gives them.
///
/// Transient: only the derived search string is stored. Deliberately holds nothing finer than a
/// city — no street, no postal code — so the privacy rule that governs ``PlaceGrid`` survives the
/// trip through here.
public struct PlaceDescription: Hashable, Sendable {
    /// "Vancouver", "Greater Vancouver", "Genève".
    public let city: String?
    /// Whatever the geocoder calls the primary subdivision. **Not consistently a code**: measured,
    /// Canada gives "BC", the US "CO", Switzerland "GE" — but the UK gives "Scotland".
    public let subdivision: String?
    /// "Canada", "Switzerland", "United Kingdom".
    public let country: String?
    /// ISO 3166-1 alpha-2, used to disambiguate the subdivision table — "WA" is Washington in the
    /// US and Western Australia in Australia.
    public let countryCode: String?

    public init(city: String?, subdivision: String?, country: String?, countryCode: String?) {
        self.city = city
        self.subdivision = subdivision
        self.country = country
        self.countryCode = countryCode
    }

    public var isEmpty: Bool {
        city == nil && subdivision == nil && country == nil
    }
}

/// Builds the hidden text that makes a workout findable by region and country.
///
/// The visible Place column stays short — "Greater Vancouver BC" — while search also matches
/// "British Columbia", "Canada" and, for a ride in Geneva, "Switzerland".
public enum PlaceTerms {
    /// Bumped when the terms' *content* changes, so stored strings rebuild themselves. Records
    /// below this version are re-resolved by ``WorkoutStore/itemsNeedingPlace(limit:)``, which
    /// costs one geocoder request per distinct place rather than per workout.
    public static let version = 1

    /// Case- and diacritic-folded, so "geneve" finds "Genève" and "bc" finds "BC".
    ///
    /// Terms are stored already folded: they are never displayed, so there is nothing to preserve,
    /// and folding once at resolve time beats folding every row on every keystroke.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// The searchable string for a place, folded, or `nil` if there is nothing to say.
    ///
    /// Includes the subdivision **both as given and expanded** — "BC" and "British Columbia" —
    /// since either is a reasonable thing to type.
    ///
    /// Excludes the ISO country code: "CA", "IN" and "US" are short enough to turn up inside
    /// unrelated words under a substring match, and the country *name* already covers the intent.
    public static func searchTerms(for place: PlaceDescription) -> String? {
        var parts: [String] = []
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            let folded = folded(value)
            if !parts.contains(folded) { parts.append(folded) }
        }

        add(place.city)
        add(place.subdivision)
        if let subdivision = place.subdivision {
            add(subdivisionName(subdivision, countryCode: place.countryCode))
        }
        add(place.country)

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Expands a subdivision code to its full name — "BC" → "British Columbia".
    ///
    /// Returns `nil` when there's nothing to add, which covers both an unknown code and a value
    /// that is already a name ("Scotland"). Foundation has no equivalent of
    /// `Locale.localizedString(forRegionCode:)` for subdivisions, hence the table.
    ///
    /// Covers the countries whose geocoder output is an abbreviation *and* that this app is
    /// plausibly used in. Anywhere else the raw value is still stored and still searchable — it is
    /// usually already a full name.
    public static func subdivisionName(_ subdivision: String, countryCode: String?) -> String? {
        guard let countryCode, subdivision.count <= 3 else { return nil }
        return subdivisions["\(countryCode.uppercased())-\(subdivision.uppercased())"]
    }

    /// Whether `text` contains `needle`, both folded. The one comparison search uses, so that
    /// every field matches by the same rules.
    static func contains(_ text: String, foldedNeedle needle: String) -> Bool {
        folded(text).contains(needle)
    }

    /// The subdivision inside MapKit's formatted `cityWithContext(.full)`: what's left once the
    /// city is removed from the front and the country from the end.
    ///
    /// **Why parse a string.** On macOS 26 there is no supported structured source: MapKit's
    /// address representations expose no subdivision (`regionCode` is documented but absent from
    /// the SDK, `regionName` is the country), and both `CLGeocoder` and `MKMapItem.placemark` —
    /// which do carry `administrativeArea` — are deprecated. The formatted string is the
    /// replacement Apple points to, and measured across ten places it is regular:
    /// "Vancouver BC Canada", "North Vancouver BC, Canada", "Seattle, WA United States",
    /// "Edinburgh, Scotland" (country "United Kingdom", so nothing trails), "Geneva, Switzerland"
    /// (nothing left: correctly no subdivision).
    ///
    /// Returns `nil` when nothing is left, or when the string doesn't start with the city — in
    /// which case it isn't safe to guess where the city ends.
    public static func subdivision(inCityContext context: String?, city: String?, country: String?) -> String? {
        guard var rest = context?.trimmingCharacters(in: .whitespaces), let city, !city.isEmpty,
              rest.hasPrefix(city) else { return nil }
        rest = String(rest.dropFirst(city.count))
        if let country, !country.isEmpty, rest.hasSuffix(country) {
            rest = String(rest.dropLast(country.count))
        }
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The ISO 3166-1 code for a country name as MapKit spells it in `locale` — "Canada" → "CA".
    ///
    /// Needed only to key the subdivision table, since MapKit gives the country by name and the
    /// structured `isoCountryCode` lives on the deprecated placemark.
    public static func countryCode(forName name: String?, locale: Locale = .current) -> String? {
        guard let name, !name.isEmpty else { return nil }
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter) else { continue }
            if locale.localizedString(forRegionCode: code)?
                .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return code
            }
        }
        return nil
    }

    /// ISO 3166-2, keyed by country so the collisions resolve: `NT` is Canada's Northwest
    /// Territories and Australia's Northern Territory, `WA` is Washington and Western Australia.
    static let subdivisions: [String: String] = [
        // Canada
        "CA-AB": "Alberta", "CA-BC": "British Columbia", "CA-MB": "Manitoba",
        "CA-NB": "New Brunswick", "CA-NL": "Newfoundland and Labrador",
        "CA-NS": "Nova Scotia", "CA-NT": "Northwest Territories", "CA-NU": "Nunavut",
        "CA-ON": "Ontario", "CA-PE": "Prince Edward Island", "CA-QC": "Quebec",
        "CA-SK": "Saskatchewan", "CA-YT": "Yukon",
        // United States
        "US-AL": "Alabama", "US-AK": "Alaska", "US-AZ": "Arizona", "US-AR": "Arkansas",
        "US-CA": "California", "US-CO": "Colorado", "US-CT": "Connecticut", "US-DE": "Delaware",
        "US-DC": "District of Columbia", "US-FL": "Florida", "US-GA": "Georgia", "US-HI": "Hawaii",
        "US-ID": "Idaho", "US-IL": "Illinois", "US-IN": "Indiana", "US-IA": "Iowa",
        "US-KS": "Kansas", "US-KY": "Kentucky", "US-LA": "Louisiana", "US-ME": "Maine",
        "US-MD": "Maryland", "US-MA": "Massachusetts", "US-MI": "Michigan", "US-MN": "Minnesota",
        "US-MS": "Mississippi", "US-MO": "Missouri", "US-MT": "Montana", "US-NE": "Nebraska",
        "US-NV": "Nevada", "US-NH": "New Hampshire", "US-NJ": "New Jersey", "US-NM": "New Mexico",
        "US-NY": "New York", "US-NC": "North Carolina", "US-ND": "North Dakota", "US-OH": "Ohio",
        "US-OK": "Oklahoma", "US-OR": "Oregon", "US-PA": "Pennsylvania", "US-RI": "Rhode Island",
        "US-SC": "South Carolina", "US-SD": "South Dakota", "US-TN": "Tennessee", "US-TX": "Texas",
        "US-UT": "Utah", "US-VT": "Vermont", "US-VA": "Virginia", "US-WA": "Washington",
        "US-WV": "West Virginia", "US-WI": "Wisconsin", "US-WY": "Wyoming",
        // Australia
        "AU-ACT": "Australian Capital Territory", "AU-NSW": "New South Wales",
        "AU-NT": "Northern Territory", "AU-QLD": "Queensland", "AU-SA": "South Australia",
        "AU-TAS": "Tasmania", "AU-VIC": "Victoria", "AU-WA": "Western Australia",
    ]
}
