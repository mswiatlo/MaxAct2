import MaxActCore
import SwiftUI

/// The colours of a coloured route (issue 31): the ramp runs blue → green → yellow → red, low to
/// high (for pace, faster is hotter); heart-rate zones use the zones chart's own colours, so Zone 5
/// is the same red everywhere; anything without a value is grey.
extension RouteShade {
    var color: Color {
        switch self {
        case .ramp(let step): Self.ramp[min(max(step, 0), Self.ramp.count - 1)]
        case .zone(let zone): zone.color
        case .missing: .gray
        }
    }

    /// Strava-like stops, chosen to read over both light and dark map tiles.
    private static let stops: [(red: Double, green: Double, blue: Double)] = [
        (0.10, 0.45, 0.95), (0.20, 0.78, 0.35), (0.98, 0.82, 0.15), (0.93, 0.20, 0.15),
    ]

    /// `RouteGradient.steps` colours, evenly along the stops.
    static let ramp: [Color] = (0..<RouteGradient.steps).map { step in
        let position = Double(step) / Double(RouteGradient.steps - 1) * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let t = position - Double(index)
        let a = stops[index], b = stops[index + 1]
        return Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                     blue: a.blue + (b.blue - a.blue) * t)
    }
}
