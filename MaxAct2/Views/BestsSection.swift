import MaxActCore
import SwiftUI

struct BestsSection: View {
    let workouts: [Workout]
    /// In sidebar order: most frequent first.
    let kinds: [ActivityKind]
    /// Shows a best's workout.
    let open: (PersonalBest, ActivityKind) -> Void

    var body: some View {
        let byKind = Dictionary(grouping: workouts, by: \.kind)
        let shown = kinds.filter { byKind[$0] != nil }

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Personal Bests", systemImage: "trophy")

            // A plain grid, not a `LazyVGrid`: lazy cards below the fold don't exist until scrolled
            // to, so VoiceOver and UI tests couldn't reach them. Two to a row when they fit, one
            // when they don't — e.g. beside the inspector.
            ViewThatFits(in: .horizontal) {
                cards(shown, byKind: byKind, perRow: 2)
                cards(shown, byKind: byKind, perRow: 1)
            }

            Footnote(text: "Click a best to show that workout. Fastest is average speed over 1 km or more.")
        }
    }

    private func cards(_ kinds: [ActivityKind], byKind: [ActivityKind: [Workout]], perRow: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: kinds.count, by: perRow)), id: \.self) { index in
                GridRow {
                    ForEach(kinds[index..<min(index + perRow, kinds.count)], id: \.self) { kind in
                        card(kind: kind, bests: WorkoutStatistics.personalBests(byKind[kind] ?? []))
                    }
                }
            }
        }
    }

    private func card(kind: ActivityKind, bests: [PersonalBest]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind.displayName, systemImage: kind.symbolName)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(bests) { best in
                    GridRow {
                        Text(best.title)
                            .foregroundStyle(.secondary)
                        Button(best.formattedValue(for: kind)) { open(best, kind) }
                        .buttonStyle(.link)
                        .monospacedDigit()
                        .help("Show this workout")
                        .accessibilityIdentifier("PersonalBest")
                        Text(best.date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.displayName) personal bests")
    }
}

extension PersonalBest {
    /// "Longest", "Most climbing" — the card's row label and the sheet's heading.
    var title: String {
        switch category {
        case .longestDistance: "Longest"
        case .longestDuration: "Longest time"
        case .mostClimbing: "Most climbing"
        case .fastest: "Fastest"
        case .mostEnergy: "Most energy"
        }
    }

    /// The record itself, in the unit the sport reads in.
    func formattedValue(for kind: ActivityKind) -> String {
        switch category {
        case .longestDistance: WorkoutFormatting.distance(value)
        case .longestDuration: WorkoutFormatting.duration(value)
        case .mostClimbing: WorkoutFormatting.elevationGain(meters: value)
        case .fastest: WorkoutFormatting.paceOrSpeed(metersPerSecond: value, for: kind)
        case .mostEnergy: WorkoutFormatting.energy(kilocalories: value)
        }
    }
}
