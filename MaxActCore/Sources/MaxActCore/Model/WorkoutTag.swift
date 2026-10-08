import Foundation

/// A label on a workout: the two Strava flags, or anything the user makes up.
///
/// Tags are **local state**, like Strava status and place names — a re-sync from Health Auto
/// Export never touches them. Only two travel to Strava, because only two exist in its API:
/// measured against the live API on 2026-10-07, `commute` and `trainer` are readable and writable,
/// while the app's Activity Tags ("With Kid", "With Pet", "Recovery"…) appear in neither the
/// activity list nor the full activity record. Everything else stays here.
public enum WorkoutTag {
    public static let commute = "Commute"
    public static let trainer = "Trainer"

    /// The tags that mirror a Strava field, in the order they're offered.
    public static let stravaBacked = [commute, trainer]

    public static func isStravaBacked(_ name: String) -> Bool {
        stravaBacked.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Tidies a typed name: trimmed, inner whitespace collapsed, and spelled like an existing tag
    /// when it differs only in case — so "commute" adds Commute rather than a second tag that
    /// looks identical in a list.
    public static func normalized(_ name: String, existing: [String] = stravaBacked) -> String? {
        let collapsed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return existing.first { $0.caseInsensitiveCompare(collapsed) == .orderedSame } ?? collapsed
    }

    /// Adds or removes the two Strava-backed tags to match Strava's flags, leaving every other tag
    /// alone. Returns the new list, or nil if nothing changed.
    public static func applying(commute: Bool, trainer: Bool, to tags: [String]) -> [String]? {
        var result = tags.filter { !isStravaBacked($0) }
        if commute { result.append(Self.commute) }
        if trainer { result.append(Self.trainer) }
        let changed = Set(result) != Set(tags) || result.count != tags.count
        return changed ? sorted(result) : nil
    }

    /// Strava-backed tags first, in their fixed order, then the rest alphabetically.
    public static func sorted(_ tags: [String]) -> [String] {
        let backed = stravaBacked.filter { tags.contains($0) }
        let rest = tags.filter { !isStravaBacked($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return backed + rest
    }
}
