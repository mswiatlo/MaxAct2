import Foundation

/// The kind of activity a workout records.
///
/// Health Auto Export identifies activities by **display name** (`"Outdoor Cycling"`), not by an
/// `HKWorkoutActivityType` raw value, so this cannot be a plain enum over integers: an unrecognised
/// name has to survive as itself. (`.hae` files do carry the HealthKit code, but that path isn't
/// the one we ingest — see PLAN.md §2.)
public enum ActivityKind: Hashable, Sendable {
    case running
    case walking
    case hiking
    case cycling
    case indoorCycling
    case swimming
    case rowing
    case elliptical
    case strengthTraining
    case functionalTraining
    case yoga
    case other(String)

    /// Maps an HAE `name` onto a case. Matching is case- and whitespace-insensitive, and tolerates
    /// the `Indoor`/`Outdoor` prefixes HAE applies to some activities.
    public init(haeName: String) {
        let trimmed = haeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        let bare = key
            .replacingOccurrences(of: "outdoor ", with: "")
            .replacingOccurrences(of: "indoor ", with: "")

        if key == "indoor cycling" || key == "cycling indoor" {
            self = .indoorCycling
            return
        }
        switch bare {
        case "running", "run": self = .running
        case "walking", "walk": self = .walking
        case "hiking", "hike": self = .hiking
        case "cycling", "biking", "bike": self = .cycling
        case "swimming", "swim", "open water swim", "pool swim": self = .swimming
        case "rowing", "row": self = .rowing
        case "elliptical": self = .elliptical
        case "traditional strength training", "strength training": self = .strengthTraining
        case "functional strength training": self = .functionalTraining
        case "yoga": self = .yoga
        default: self = .other(trimmed)
        }
    }

    /// Name for display. Unrecognised activities keep whatever HAE called them.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .hiking: "Hiking"
        case .cycling: "Cycling"
        case .indoorCycling: "Indoor Cycling"
        case .swimming: "Swimming"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .strengthTraining: "Strength Training"
        case .functionalTraining: "Functional Training"
        case .yoga: "Yoga"
        case .other(let name): name
        }
    }

    /// SF Symbol for the activity. `figure.mixed.cardio` is the deliberate fallback for unknowns.
    public var symbolName: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling, .indoorCycling: "figure.outdoor.cycle"
        case .swimming: "figure.pool.swim"
        case .rowing: "figure.rower"
        case .elliptical: "figure.elliptical"
        case .strengthTraining: "figure.strengthtraining.traditional"
        case .functionalTraining: "figure.strengthtraining.functional"
        case .yoga: "figure.yoga"
        case .other: "figure.mixed.cardio"
        }
    }

    /// Whether distance and pace are meaningful for this activity, so the UI can show an em dash
    /// rather than `0.00 km` for a strength session.
    public var isDistanceBased: Bool {
        switch self {
        case .running, .walking, .hiking, .cycling, .indoorCycling, .swimming, .rowing, .elliptical:
            true
        case .strengthTraining, .functionalTraining, .yoga, .other:
            false
        }
    }
}
