import Foundation
import Testing

@testable import MaxActCore

@Suite struct StatisticsFormattingTests {
    private let locale = Locale(identifier: "en_US")

    @Test("totals read at a glance, and zero is a number rather than a dash")
    func totals() {
        #expect(WorkoutFormatting.total(0, .distance, locale: locale) == "0.0 km")
        #expect(WorkoutFormatting.total(86_440, .distance, locale: locale) == "86.4 km")
        #expect(WorkoutFormatting.total(1_234_560, .distance, locale: locale) == "1,235 km")
        #expect(WorkoutFormatting.total(0, .duration, locale: locale) == "0 min")
        #expect(WorkoutFormatting.total(45 * 60, .duration, locale: locale) == "45 min")
        #expect(WorkoutFormatting.total(112 * 3600 + 5 * 60, .duration, locale: locale) == "112 h 05 min")
        #expect(WorkoutFormatting.total(12_345.4, .elevation, locale: locale) == "12,345 m")
        #expect(WorkoutFormatting.total(23_456, .energy, locale: locale) == "23,456 kcal")
        #expect(WorkoutFormatting.total(1_204, .count, locale: locale) == "1,204")
    }

    @Test("charts plot in kilometres and hours")
    func chartUnits() {
        #expect(StatisticsMetric.distance.chartValue(12_500) == 12.5)
        #expect(StatisticsMetric.duration.chartValue(5_400) == 1.5)
        #expect(StatisticsMetric.elevation.chartValue(300) == 300)
    }
}
