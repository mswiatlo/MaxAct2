import Foundation
import MaxActCore

/// A sidebar selection. Filtering happens in memory rather than as a `#Predicate` fetch: the whole
/// corpus is a few thousand rows of value types, which sorts and filters in well under the frame
/// budget (measured at 0.108 s to fetch all 2,867), and it keeps switching filters instant rather
/// than round-tripping the database on every click.
enum WorkoutFilter: Hashable, Identifiable, CaseIterable {
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

/// What the sidebar can select: a saved filter, or one activity kind.
enum SidebarSelection: Hashable {
    case filter(WorkoutFilter)
    case kind(String)   // ActivityKind.storageKey

    func matches(_ item: WorkoutListItem) -> Bool {
        switch self {
        case .filter(let filter): filter.matches(item)
        case .kind(let key): item.workout.kind.storageKey == key
        }
    }

    var title: String {
        switch self {
        case .filter(let filter): filter.title
        case .kind(let key): ActivityKind(storageKey: key).displayName
        }
    }
}

extension WorkoutListItem {
    /// Free-text match over the fields a person would plausibly type: activity, place, source.
    /// Deliberately not the id — nobody searches for a UUID.
    func matches(searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        let needle = searchText.lowercased()
        if workout.kind.displayName.lowercased().contains(needle) { return true }
        if let placeLabel, placeLabel.lowercased().contains(needle) { return true }
        if let sourceName, sourceName.lowercased().contains(needle) { return true }
        return false
    }

    var sourceName: String? { workout.sourceName }
}

// MARK: - Sort keys

/// `TableColumn(_:value:)` needs a `Comparable` key path, and the optional metrics aren't one.
///
/// Missing values map to `-1` rather than `0` so they stay distinguishable from a genuine zero and
/// always group together at one end: last when sorting largest-first, which is the common case.
extension WorkoutListItem {
    var sortDistance: Double { workout.distanceMeters ?? -1 }
    var sortEnergy: Double { workout.activeEnergyKilocalories ?? -1 }
    var sortHeartRate: Double { workout.averageHeartRate ?? -1 }
    var sortPace: Double { workout.effectiveSpeedMetersPerSecond ?? -1 }
}
