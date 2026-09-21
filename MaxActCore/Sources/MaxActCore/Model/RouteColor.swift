import Foundation

/// The colour a route track is drawn in, on thumbnails and the detail map.
///
/// **Not the system accent.** The first version used `controlAccentColor`, which was wrong twice
/// over: the accent is a user preference that may legitimately be graphite, and — because this
/// app's `AccentColor` asset was empty — it resolved to grey, so every route rendered grey.
///
/// A track has to stay legible over green parkland, blue water and grey city blocks, in light and
/// dark map tiles alike. That rules out most of the map's own palette and argues for something
/// warm and saturated, which is why route overlays across the industry converge on orange and
/// magenta. All the choices here are picked on that basis, and each is drawn over a dark casing
/// that does the rest of the contrast work.
///
/// Stored as components rather than a `Color` so this stays in the model layer, testable and free
/// of SwiftUI.
public enum RouteColor: String, CaseIterable, Identifiable, Sendable {
    /// Default. A vivid orange-red: maximally distinct from parkland green, water blue and the
    /// greys of streets and buildings, and legible in both map appearances.
    case sunset
    case crimson
    case magenta
    case violet
    case ocean
    case emerald

    public var id: Self { self }

    public static let `default` = RouteColor.sunset

    public var displayName: String {
        switch self {
        case .sunset: "Sunset"
        case .crimson: "Crimson"
        case .magenta: "Magenta"
        case .violet: "Violet"
        case .ocean: "Ocean"
        case .emerald: "Emerald"
        }
    }

    /// sRGB components in 0…1.
    public var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .sunset: (0.98, 0.35, 0.09)     // #FA590F
        case .crimson: (0.87, 0.14, 0.27)    // #DE2345
        case .magenta: (0.85, 0.16, 0.62)    // #D9299E
        case .violet: (0.55, 0.30, 0.92)     // #8C4CEB
        case .ocean: (0.05, 0.55, 0.92)      // #0D8CEB
        case .emerald: (0.05, 0.68, 0.42)    // #0DAD6B
        }
    }

    /// Stable short token for the thumbnail cache filename.
    ///
    /// Thumbnails are cached on disk indefinitely, so the colour has to be part of their identity
    /// — otherwise changing this setting would leave every existing thumbnail drawn in the old
    /// colour until something else invalidated it.
    public var cacheToken: String { rawValue }

    public init(storageKey: String?) {
        self = RouteColor(rawValue: storageKey ?? "") ?? .default
    }
}
