import Foundation

/// Separating real GPS fixes from the receiver's bad ones.
///
/// **Filtering happens on read, never on write.** The stored series stays exactly as the watch
/// recorded it, so the thresholds here can change without re-syncing, and a future TCX export can
/// choose whether to carry the raw or the cleaned track.
///
/// ## The signature, measured rather than guessed
///
/// Across five real workouts (2,824–17,390 m, 544–3,311 points at 1 Hz), every kilometre-scale
/// teleport landed on a point with **no `speedMetersPerSecond` and a horizontal accuracy above
/// ~30 m**. The worst was a 1,826 m jump between two samples one second apart. Points carrying a
/// speed had a median accuracy of 8–16 m; points missing one had a median of 35–39 m. Dropping that
/// combination discards **0.0–0.7%** of a route and takes the worst implied speed from 1,826 m/s
/// down to 51 m/s — the remainder being 30–74 m wobbles, which are too small to distort either the
/// drawn track or the map's framing.
///
/// ## What was tried and rejected
///
/// The obvious detector — flag a point whose implied speed *into and out of* it exceeds a plausible
/// ceiling — does not survive measurement. At 1 Hz sampling the GPS noise floor is itself several
/// metres per second: with a walking ceiling of 3 m/s it fired on **3–5 metre steps**, which is
/// jitter, not teleportation. Raised to a ceiling safe from false positives (5 m/s walking, 30 m/s
/// cycling) it never fired at all on real data. A knob that either misfires or no-ops is worse than
/// no knob, so there isn't one. The accuracy rule alone does the work, and it does it without ever
/// looking at movement — so it cannot mistake genuine speed for an artifact.
///
/// Stuck fixes — runs of near-identical coordinates while time advances — are deliberately **not**
/// filtered. They measured 3–18% of points with runs up to 33 samples, and at a 10 m accuracy floor
/// they are indistinguishable from genuinely standing still. Treating them as artifacts would
/// delete real pauses; ``WorkoutSeries/movingTime(for:)`` handles them as what they are instead.
public enum RouteQuality {
    /// Above this, a fix that also lacks a speed is treated as spurious. 30 m sits well clear of
    /// the 8–16 m median accuracy of good fixes and just under the 34–39 m median of the bad ones;
    /// at 35 m one real teleport survived, and at 25 m nothing extra was caught *in the original
    /// five workouts*. A later ride had a 27 m teleport, which is why ``isExcursion(_:in:)`` exists
    /// rather than this being lowered: a threshold tuned to the one case that got through would be
    /// a guess, while the out-and-back shape is the thing actually wrong.
    public static let accuracyLimitMeters: Double = 30

    /// A gap longer than this is a pause, not a sampling interval.
    ///
    /// Not a delicate boundary: measured pauses ran 9.6 to 51.7 minutes while real sampling
    /// dropouts were seconds. Shared by moving time, splits and chart segmentation so all three
    /// agree on where a workout stopped.
    public static let pauseGapSeconds: TimeInterval = 60

    /// Whether a fix looks like a real position.
    ///
    /// Both conditions are required. A missing speed alone is common and harmless — plenty of
    /// good fixes lack one — and poor accuracy alone still carries usable position.
    public static func isPlausible(_ point: RoutePoint) -> Bool {
        guard point.speedMetersPerSecond == nil else { return true }
        guard let accuracy = point.horizontalAccuracyMeters else { return true }
        return accuracy <= accuracyLimitMeters
    }

    /// A speedless fix this far from *both* neighbours is an excursion, not a position.
    public static let excursionLimitMeters: Double = 100

    /// The route with spurious fixes removed. What should be drawn, measured and exported.
    public static func cleaned(_ route: [RoutePoint]) -> [RoutePoint] {
        let discarded = discardedIndices(route)
        // Almost always a no-op in terms of count, so avoid reallocating when nothing is dropped.
        guard !discarded.isEmpty else { return route }
        return route.indices.filter { !discarded.contains($0) }.map { route[$0] }
    }

    /// How many fixes ``cleaned(_:)`` would drop, so the detail pane can say so rather than
    /// silently changing the numbers.
    public static func discardedCount(_ route: [RoutePoint]) -> Int {
        discardedIndices(route).count
    }

    /// Fixes failing either rule: the accuracy rule in ``isPlausible(_:)``, or the out-and-back
    /// rule in ``isExcursion(_:in:)``.
    static func discardedIndices(_ route: [RoutePoint]) -> Set<Int> {
        Set(route.indices.filter { !isPlausible(route[$0]) || isExcursion($0, in: route) })
    }

    /// Whether the fix at `index` jumps away and straight back: a speedless point more than
    /// ``excursionLimitMeters`` from *both* neighbours, while those neighbours are close to each
    /// other.
    ///
    /// **Added for issue 11, by measurement.** A 2,516 m out-and-back on a 2026-09-21 ride had an
    /// accuracy of **27 m** — just inside ``accuracyLimitMeters`` — so the accuracy rule kept it, and
    /// its phantom 5 km swallowed two kilometres of splits in two seconds. Across all 8 stored routes
    /// (16,699 points) there were exactly 10 out-and-backs over 100 m. **All 10 were speedless**, no
    /// fix carrying a speed ever made one, and 9 already failed the accuracy rule; this was the one
    /// that didn't. So the speedless condition is the reliable half of the signature, and accuracy
    /// was a proxy that was right nine times in ten.
    ///
    /// Not the implied-speed detector rejected above. That one flagged any fast step, and at 1 Hz
    /// fired on 3–5 m of jitter. This needs a point to leave by over 100 m *and return* to where
    /// its neighbours agree it should be — a shape jitter can't make, and a genuine fast section
    /// can't either, since real movement doesn't come back.
    ///
    /// **Neighbours within half the excursion**, not a quarter, which was tried first and missed a
    /// second real case: on the 16:02 ride the same day, a speedless fix went 161 m out and 190 m
    /// back while the rider was stopped, with its neighbours 45 m apart — a ratio of 0.28. A fix
    /// that carries *on* instead puts its neighbours about twice the excursion apart, so half
    /// still leaves a wide margin; measured across the library, loosening it added that one fix
    /// and nothing else.
    static func isExcursion(_ index: Int, in route: [RoutePoint]) -> Bool {
        guard index > 0, index < route.count - 1,
              route[index].speedMetersPerSecond == nil else { return false }
        let before = route[index - 1].coordinate
        let point = route[index].coordinate
        let after = route[index + 1].coordinate
        let excursion = min(WorkoutSplits.distance(from: before, to: point),
                            WorkoutSplits.distance(from: point, to: after))
        return excursion > excursionLimitMeters
            && WorkoutSplits.distance(from: before, to: after) < excursion / 2
    }
}

extension ActivityKind {
    /// Below this speed the athlete is stopped rather than moving, for the purpose of
    /// ``WorkoutSeries/movingTime(for:)``.
    ///
    /// A walking pause is not a cycling pause: a cyclist rolling at 0.6 m/s is stopped at a light,
    /// while a walker at 0.6 m/s is walking. `nil` where the question is meaningless.
    public var stoppedBelowMetersPerSecond: Double? {
        switch self {
        case .walking, .hiking: 0.5
        case .running: 1.0
        case .cycling, .indoorCycling: 1.0
        case .swimming: 0.2
        case .rowing, .elliptical: 0.5
        case .strengthTraining, .functionalTraining, .yoga, .other: nil
        }
    }
}

extension WorkoutSeries {
    /// The route with spurious fixes removed. O(n), so hold the result rather than re-reading it.
    public var cleanedRoute: [RoutePoint] { RouteQuality.cleaned(route) }

    /// Seconds spent actually moving, derived from the cleaned route's own per-point speeds.
    ///
    /// `nil` when there is no route or the activity has no notion of moving — never zero, which
    /// would render as an absurd pace.
    ///
    /// ## Why this is a *refinement*, not the main fix
    ///
    /// Health Auto Export's `duration` already excludes paused time for activities where the watch
    /// auto-pauses. Measured on four rides: durations of 509–2,154 s against wall-clock spans of
    /// 551–6,240 s, and the duration matched a moving time computed here to within 3% every time.
    /// So `distance / duration` is already a moving average for cycling, and this adds little.
    ///
    /// Where it earns its keep is activities the watch doesn't auto-pause. The measured walk had
    /// `duration` exactly equal to its 55.3-minute wall-clock span, while 12.3 minutes of it were
    /// spent standing still — 14:50 /km elapsed against **11:31 /km moving**.
    public func movingTime(for kind: ActivityKind) -> TimeInterval? {
        guard let threshold = kind.stoppedBelowMetersPerSecond else { return nil }
        let points = cleanedRoute
        guard points.count >= 2 else { return nil }

        var moving: TimeInterval = 0
        for (previous, next) in zip(points, points.dropFirst()) {
            let interval = next.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0, interval <= RouteQuality.pauseGapSeconds else { continue }

            // Prefer the receiver's own speed. Deriving it from the step between two fixes
            // overstates it badly at 1 Hz, because the jitter between adjacent samples is metres:
            // summing raw step distances inflated a 3.73 km walk to 5.55 km.
            guard let speed = previous.speedMetersPerSecond else { continue }
            if speed >= threshold { moving += interval }
        }
        return moving > 0 ? moving : nil
    }
}
