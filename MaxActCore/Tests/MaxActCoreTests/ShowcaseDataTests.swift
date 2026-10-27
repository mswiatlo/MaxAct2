import Foundation
import Testing

@testable import MaxActCore

/// Issue 36: the README's library must look like real use, and stay the same for a given day.
@Suite struct ShowcaseDataTests {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26
    static let library = ShowcaseData.library(endingAt: now, calendar: Calendar(identifier: .gregorian))

    @Test("every route decodes to a real path of the expected length")
    func routesDecode() {
        let expected = ["adanac-commute": 2.5, "english-bay-walk": 1.95, "false-creek": 3.4, "grouse-grind": 1.9,
                        "kits-jericho": 3.5, "lions-gate-dundarave": 7.3, "stanley-park-seawall": 10.7]
        for (name, kilometres) in expected {
            let points = ShowcaseRoutes.points(name)
            #expect(points.count > 10, "\(name)")
            let length = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
                let lat = pair.0.coordinate.latitude * .pi / 180
                return total + hypot((pair.1.coordinate.latitude - pair.0.coordinate.latitude) * 111_320,
                                     (pair.1.coordinate.longitude - pair.0.coordinate.longitude) * 111_320 * cos(lat))
            }
            #expect(abs(length / 1000 - kilometres) < 0.1, "\(name): \(length / 1000) km")
            #expect(points.allSatisfy { abs($0.coordinate.latitude - 49.3) < 0.15 && abs($0.coordinate.longitude + 123.12) < 0.15 },
                    "\(name) stays in Vancouver")
        }
        let grind = ShowcaseRoutes.points("grouse-grind").map(\.elevation)
        #expect((grind.max() ?? 0) - (grind.min() ?? 0) > 700, "the Grind climbs ~800 m")
    }

    @Test("the same day gives the same library")
    func deterministic() {
        let again = ShowcaseData.library(endingAt: Self.now, calendar: Calendar(identifier: .gregorian))
        #expect(again.map(\.ingested.workout) == Self.library.map(\.ingested.workout))
        #expect(again.map(\.ingested.series) == Self.library.map(\.ingested.series))
    }

    @Test("dated up to yesterday, ten weeks back, with valid ids")
    func dates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let newest = try #require(Self.library.first).ingested.workout.start
        #expect(calendar.isDate(newest, inSameDayAs: Self.now.addingTimeInterval(-86_400)))
        let oldest = try #require(Self.library.last).ingested.workout.start
        #expect(Self.now.timeIntervalSince(oldest) > 60 * 86_400)
        #expect(Self.library.allSatisfy { InputLimits.isValidID($0.ingested.workout.id) })
        #expect(Set(Self.library.map(\.ingested.workout.id)).count == Self.library.count)
    }

    @Test("numbers a person could have produced")
    func plausible() {
        var lines: [String] = []
        for entry in Self.library {
            let workout = entry.ingested.workout, series = entry.ingested.series
            if let distance = workout.distanceMeters, workout.kind.isDistanceBased, workout.duration > 0 {
                let kmh = distance / workout.duration * 3.6
                let range: ClosedRange<Double> = switch workout.kind {
                case .running: 8...14
                case .cycling, .indoorCycling: 15...35
                case .walking: 3.5...6
                case .hiking: 1...5
                default: 0...100
                }
                #expect(range.contains(kmh), "\(workout.kind.displayName) at \(kmh) km/h")
            }
            if let heartRate = workout.averageHeartRate {
                #expect((70...180).contains(heartRate), "\(workout.kind.displayName): \(heartRate) bpm")
                #expect((workout.maximumHeartRate ?? 0) <= ShowcaseData.maximumHeartRate + 5)
            }
            // Every point on the route is within a GPS error of the path.
            if let name = entry.route, !series.route.isEmpty {
                let path = ShowcaseRoutes.points(name).map(\.coordinate)
                let worst = series.route.map { point in
                    zip(path, path.dropFirst()).map { segment(point.coordinate, $0, $1) }.min() ?? 0
                }.max() ?? 0
                #expect(worst < 60, "\(workout.id) strays \(worst) m from \(name)")
            }
            lines.append("\(workout.start.formatted(.iso8601.year().month().day())) \(workout.kind.displayName): "
                         + "\(((workout.distanceMeters ?? 0) / 1000).formatted(.number.precision(.fractionLength(1)))) km, "
                         + "\(Int(workout.duration / 60)) min, HR \(Int(workout.averageHeartRate ?? 0))/\(Int(workout.maximumHeartRate ?? 0)), "
                         + "+\(Int(workout.elevationAscendedMeters ?? 0)) m, \(series.route.count) pts, \(entry.placeLabel ?? "—"), "
                         + "\(entry.tags), strava \(entry.stravaActivityID != nil)")
        }
        print(lines.prefix(16).joined(separator: "\n"))
        print("… \(Self.library.count) workouts")
    }

    @Test("a mix of states: a few list-only, the newest not on Strava, tags")
    func mix() {
        #expect(Self.library.contains { $0.ingested.workout.hasRoute == false && $0.ingested.workout.isIndoor == false })
        #expect(Self.library.prefix(2).allSatisfy { $0.stravaActivityID == nil })
        #expect(Self.library.dropFirst(8).allSatisfy { $0.stravaActivityID != nil })
        #expect(Self.library.contains { $0.tags == ["Commute"] })
        #expect(Self.library.contains { $0.ingested.workout.kind == .hiking })
    }

    /// Distance from `p` to the segment `a`–`b`, in metres.
    private func segment(_ p: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
        let scale = cos(a.latitude * .pi / 180) * 111_320
        let (px, py) = ((p.longitude - a.longitude) * scale, (p.latitude - a.latitude) * 111_320)
        let (bx, by) = ((b.longitude - a.longitude) * scale, (b.latitude - a.latitude) * 111_320)
        let length = bx * bx + by * by
        let t = length == 0 ? 0 : min(max((px * bx + py * by) / length, 0), 1)
        return hypot(px - t * bx, py - t * by)
    }

    private func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat = a.latitude * .pi / 180
        return hypot((b.latitude - a.latitude) * 111_320, (b.longitude - a.longitude) * 111_320 * cos(lat))
    }
}
