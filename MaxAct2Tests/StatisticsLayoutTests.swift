import AppKit
import Foundation
import MaxActCore
import SwiftUI
import Testing

@testable import MaxAct2

/// Issue 8b: every statistics section must reflow down to `StatisticsView.minimumWidth`.
///
/// A section that can't — a fixed-width row, a year of heat-map squares — sets a minimum for the
/// whole view, and with the inspector open that minimum is what pushed the panes past the window.
/// Measured here by asking each section for its size at a 1pt-wide proposal: what comes back is
/// the narrowest it can be. No window and no mouse, so it runs with the unit tests.
@MainActor @Suite struct StatisticsLayoutTests {
    private func narrowest(_ view: some View) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 1, height: 100_000)).width
    }

    @Test func theWholeViewReflowsToTheMinimumWidth() async {
        let model = AppModel.inMemoryFallback(
            settings: AppSettings(defaults: UserDefaults(suiteName: "StatisticsLayoutTests") ?? .standard),
            seedCount: 400, resolvesPlaces: false, stravaSecrets: InMemorySecretStore()
        )
        await model.load()
        model.sidebarSelection = .statistics
        let view = StatisticsView(model: model)
        let narrowest = narrowest(view)
        print("STATISTICS VIEW (\(model.items.count) items): narrowest \(narrowest), "
              + "ideal \(NSHostingView(rootView: view).fittingSize.width)")
        let content = ContentView(model: model)
        print("CONTENT VIEW: narrowest \(self.narrowest(content)), ideal \(NSHostingView(rootView: content).fittingSize.width)")
        #expect(narrowest <= StatisticsView.minimumWidth)
    }

    @Test func everySectionReflowsToTheMinimumWidth() {
        let workouts = SampleData.workouts(count: 400)
        let calendar = WorkoutStatistics.trainingCalendar()
        let now = workouts.map(\.start).max() ?? .now
        let model = AppModel.inMemoryFallback(
            settings: AppSettings(defaults: UserDefaults(suiteName: "StatisticsLayoutTests") ?? .standard),
            resolvesPlaces: false, stravaSecrets: InMemorySecretStore()
        )
        let kinds = Array(Set(workouts.map(\.kind))).sorted { $0.displayName < $1.displayName }

        let sections: [(String, AnyView)] = [
            ("totals", AnyView(TotalsSection(workouts: workouts, metrics: StatisticsMetric.allCases,
                                             now: now, calendar: calendar))),
            ("history", AnyView(HistorySection(
                buckets: WorkoutStatistics.byPeriod(.week, of: workouts, through: now, calendar: calendar),
                period: .constant(.week), metric: .distance, calendar: calendar))),
            ("year", AnyView(YearSection(
                years: WorkoutStatistics.yearProgression(workouts, metric: .distance, now: now, calendar: calendar),
                metric: .distance, today: WorkoutStatistics.referenceDate(for: now, calendar: calendar)))),
            ("consistency", AnyView(ConsistencySection(workouts: workouts, now: now, calendar: calendar))),
            ("bests", AnyView(BestsSection(model: model, workouts: workouts, kinds: kinds))),
        ]
        for (name, view) in sections {
            let width = narrowest(view)
            print("STATISTICS SECTION \(name): narrowest \(width), ideal \(NSHostingView(rootView: view).fittingSize.width)")
            #expect(width <= StatisticsView.minimumWidth - 48,  // the view's own padding is 2 × 24
                    "The \(name) section can't get narrower than \(width)pt.")
        }
    }
}
