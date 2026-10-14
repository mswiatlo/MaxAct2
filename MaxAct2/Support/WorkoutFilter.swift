import Foundation
import MaxActCore

/// A sidebar selection. Filtering happens in memory rather than as a `#Predicate` fetch: the whole
/// corpus is a few thousand rows of value types, which sorts and filters in well under the frame
/// budget (measured at 0.108 s to fetch all 2,867), and it keeps switching filters instant rather
/// than round-tripping the database on every click.
enum WorkoutFilter: String, Hashable, Identifiable, CaseIterable {
    case all
    case notOnStrava
    case uploadFailed
    case withRoute
    case indoor

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Workouts"
        case .notOnStrava: "Not on Strava"
        case .uploadFailed: "Upload Failed"
        case .withRoute: "With Route"
        case .indoor: "Indoor"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "figure.run.square.stack"
        case .notOnStrava: "circle.dashed"
        case .uploadFailed: "exclamationmark.triangle"
        case .withRoute: "map"
        case .indoor: "house"
        }
    }

    func matches(_ item: WorkoutListItem) -> Bool {
        switch self {
        case .all: true
        case .notOnStrava: !item.stravaState.isOnStrava
        case .uploadFailed: item.stravaState.failureReason != nil
        case .withRoute: item.workout.hasRoute
        case .indoor: item.workout.isIndoor == true
        }
    }
}

/// What the sidebar can select: a saved filter, one activity kind, a tag — or the statistics view.
enum SidebarSelection: Hashable {
    case filter(WorkoutFilter)
    case kind(String)   // ActivityKind.storageKey
    case tag(String)
    /// Every workout, summarised rather than listed. It narrows nothing itself: the statistics
    /// view has its own activity picker, since choosing this row deselects any activity row.
    case statistics

    func matches(_ item: WorkoutListItem) -> Bool {
        switch self {
        case .filter(let filter): filter.matches(item)
        case .kind(let key): item.workout.kind.storageKey == key
        case .tag(let name): item.tags.contains(name)
        case .statistics: true
        }
    }

    /// "filter:uploadFailed", "kind:cycling", "tag:Commute", "statistics" — what's remembered
    /// between launches (Phase 8).
    var storageKey: String {
        switch self {
        case .filter(let filter): "filter:\(filter.rawValue)"
        case .kind(let key): "kind:\(key)"
        case .tag(let name): "tag:\(name)"
        case .statistics: "statistics"
        }
    }

    init?(storageKey: String?) {
        guard let storageKey else { return nil }
        if storageKey == "statistics" { self = .statistics; return }
        guard let colon = storageKey.firstIndex(of: ":") else { return nil }
        let value = String(storageKey[storageKey.index(after: colon)...])
        switch storageKey[..<colon] {
        case "filter": guard let filter = WorkoutFilter(rawValue: value) else { return nil }
                       self = .filter(filter)
        case "kind": self = .kind(value)
        case "tag": self = .tag(value)
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .filter(let filter): filter.title
        case .kind(let key): ActivityKind(storageKey: key).displayName
        case .tag(let name): name
        case .statistics: "Statistics"
        }
    }
}

// `matches(searchText:)` and `sourceName` live in `MaxActCore` beside `WorkoutListItem`, so the
// matching rules — folding, and the hidden region/country terms — are covered by `swift test`.

// MARK: - Sort keys

/// `TableColumn(_:value:)` needs a `Comparable` key path, and the optional metrics aren't one.
///
/// Missing values map to `-1` rather than `0` so they stay distinguishable from a genuine zero and
/// always group together at one end: last when sorting largest-first, which is the common case.
extension WorkoutListItem {
    // `nonisolated` so key paths to them are `Sendable`, which `KeyPathComparator` requires in
    // `TableSort`. They only read the value they're called on.
    nonisolated var sortDistance: Double { workout.distanceMeters ?? -1 }
    nonisolated var sortEnergy: Double { workout.activeEnergyKilocalories ?? -1 }
    nonisolated var sortHeartRate: Double { workout.averageHeartRate ?? -1 }
    nonisolated var sortPace: Double { workout.effectiveSpeedMetersPerSecond ?? -1 }
}

/// The table's sort order as remembered between launches (Phase 8): the primary column and its
/// direction, as "distance:desc". `KeyPathComparator` isn't `Codable`, and a secondary sort column
/// is rare enough not to be worth storing.
enum TableSort {
    static let `default` = [KeyPathComparator(\WorkoutListItem.workout.start, order: .reverse)]

    private static func comparator(_ key: String, _ order: SortOrder) -> KeyPathComparator<WorkoutListItem>? {
        switch key {
        case "date": KeyPathComparator(\WorkoutListItem.workout.start, order: order)
        case "activity": KeyPathComparator(\WorkoutListItem.workout.kind.displayName, order: order)
        case "duration": KeyPathComparator(\WorkoutListItem.workout.duration, order: order)
        case "distance": KeyPathComparator(\WorkoutListItem.sortDistance, order: order)
        case "pace": KeyPathComparator(\WorkoutListItem.sortPace, order: order)
        case "energy": KeyPathComparator(\WorkoutListItem.sortEnergy, order: order)
        case "heartRate": KeyPathComparator(\WorkoutListItem.sortHeartRate, order: order)
        default: nil
        }
    }

    private static let keys = ["date", "activity", "duration", "distance", "pace", "energy", "heartRate"]

    static func storageKey(for order: [KeyPathComparator<WorkoutListItem>]) -> String? {
        guard let first = order.first,
              let key = keys.first(where: { comparator($0, .forward)?.keyPath == first.keyPath })
        else { return nil }
        return "\(key):\(first.order == .forward ? "asc" : "desc")"
    }

    static func order(storageKey: String?) -> [KeyPathComparator<WorkoutListItem>]? {
        guard let parts = storageKey?.split(separator: ":"), parts.count == 2,
              let comparator = comparator(String(parts[0]), parts[1] == "asc" ? .forward : .reverse)
        else { return nil }
        return [comparator]
    }
}
