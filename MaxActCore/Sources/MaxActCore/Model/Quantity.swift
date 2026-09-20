import Foundation

/// A unit string we don't recognise, on a field we do.
///
/// Deliberately fatal to the enclosing workout rather than ignorable: silently misreading `kJ` as
/// `kcal` yields a number that looks plausible and is wrong by 4.184×, which is far worse than a
/// visible failure. Imperial units land here by design — MaxAct is metric-only.
public struct UnknownUnitError: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let unit: String
    public let dimension: Units.Dimension

    public init(field: String, unit: String, dimension: Units.Dimension) {
        self.field = field
        self.unit = unit
        self.dimension = dimension
    }

    public var description: String {
        "unsupported unit '\(unit)' for \(dimension.rawValue) field '\(field)'"
    }
}

public enum Units {
    /// The physical dimension a Health Auto Export quantity is expected to have.
    ///
    /// Nested under `Units` because a top-level `Dimension` collides with Foundation's
    /// `NSDimension`, which Swift imports under that name.
    ///
    /// Dimension is decided by the *field*, not by the unit string, because HAE's unit strings are
    /// user preferences and, in at least one case, outright wrong — see the `.speed` arm below.
    public enum Dimension: String, Sendable {
        case energy     // canonical: kilocalories
        case length     // canonical: metres
        case speed      // canonical: metres per second
        case rate       // canonical: counts per minute (bpm)
        case count      // canonical: dimensionless count
        case duration   // canonical: seconds
    }

    /// Converts a Health Auto Export quantity into MaxAct's canonical unit for that dimension.
    ///
    /// - Parameter field: the HAE key this value came from, used only for diagnostics and for the
    ///   `avgSpeed`/`maxSpeed` quirk below.
    public static func value(
        _ qty: Double,
        in unit: String,
        as dimension: Dimension,
        field: String
    ) throws -> Double {
        let unit = unit.trimmingCharacters(in: .whitespaces)
        switch dimension {
        case .energy:
            switch unit {
            case "kcal", "Cal": return qty
            case "kJ": return qty / 4.184
            case "J": return qty / 4184
            case "cal": return qty / 1000
            default: break
            }
        case .length:
            switch unit {
            case "m": return qty
            case "km": return qty * 1000
            case "cm": return qty / 100
            default: break
            }
        case .speed:
            switch unit {
            case "m/s": return qty
            case "km/hr", "km/h": return qty / 3.6
            // HAE labels avgSpeed and maxSpeed "km" — a length unit on a speed quantity. Verified
            // a bug rather than a different measure: for one workout MCP reported avgSpeed
            // 13.501169642707001 "km" while the same workout's .hae measurements block gave
            // averageSpeed 3.750324900751945 m/s, which is 13.501169642707001 km/h exactly.
            // maxSpeed matched the same way. Accepted only for speed-dimension fields, so a real
            // length field carrying "km" is unaffected.
            case "km": return qty / 3.6
            default: break
            }
        case .rate:
            switch unit {
            case "bpm", "count/min": return qty
            default: break
            }
        case .count:
            switch unit {
            case "count", "steps": return qty
            default: break
            }
        case .duration:
            switch unit {
            case "s": return qty
            case "min": return qty * 60
            case "hr", "h": return qty * 3600
            default: break
            }
        }
        throw UnknownUnitError(field: field, unit: unit, dimension: dimension)
    }
}
