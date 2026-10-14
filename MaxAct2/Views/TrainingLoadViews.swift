import Charts
import MaxActCore
import SwiftUI

/// Resting and maximum heart rate and the TRIMP curve — in Settings, and inside the statistics'
/// Training Load section until they're set (the user asked to be asked on first use).
struct HeartRateProfileFields: View {
    @Bindable var settings: AppSettings
    let suggestedMaximum: Int?

    var body: some View {
        LabeledContent("Resting heart rate") {
            HStack(spacing: 4) {
                TextField("", value: $settings.restingHeartRate, format: .number, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("bpm").foregroundStyle(.secondary)
            }
        }
        LabeledContent("Maximum heart rate") {
            HStack(spacing: 4) {
                TextField("", value: $settings.maximumHeartRate, format: .number, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("bpm").foregroundStyle(.secondary)
                // The highest a workout reached: a floor, since real maximums are rarely hit in
                // training — offered, not filled in silently.
                if let suggestedMaximum, suggestedMaximum != settings.maximumHeartRate {
                    Button("Use \(suggestedMaximum), your highest recorded") {
                        settings.maximumHeartRate = suggestedMaximum
                    }
                    .buttonStyle(.link)
                }
            }
        }
        Picker("Effort curve", selection: $settings.trimpCurve) {
            Text("Choose…").tag(HeartRateProfile.Curve?.none)
            Text("Male (1.92)").tag(HeartRateProfile.Curve?.some(.male))
            Text("Female (1.67)").tag(HeartRateProfile.Curve?.some(.female))
        }
        Text("Training load uses Banister's TRIMP, which weights effort by how close your heart rate "
             + "gets to maximum. Its two published curves were fitted separately for men and women.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if settings.heartRateProfile == nil, settings.restingHeartRate > 0, settings.maximumHeartRate > 0,
           settings.trimpCurve != nil {
            Label("Maximum must be at least 40 bpm above resting.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// Fitness, Fatigue and Form over the last 90 days (issue 15).
struct TrainingLoadSection: View {
    @Bindable var settings: AppSettings
    let workouts: [Workout]
    let suggestedMaximum: Int?
    let now: Date
    let calendar: Calendar

    /// Long enough to show a training block and its taper; the model itself runs over everything.
    private static let shownDays = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Training Load", systemImage: "waveform.path.ecg")
                .font(.title3.weight(.semibold))

            if let profile = settings.heartRateProfile {
                content(profile)
            } else {
                // Asked here, on first use, rather than buried in Settings.
                Text("Set your heart-rate details to see Fitness, Fatigue and Form.")
                    .foregroundStyle(.secondary)
                Form { HeartRateProfileFields(settings: settings, suggestedMaximum: suggestedMaximum) }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(maxWidth: 520, minHeight: 230)
            }
        }
    }

    @ViewBuilder
    private func content(_ profile: HeartRateProfile) -> some View {
        let model = TrainingLoad.days(workouts, profile: profile, through: now, calendar: calendar)
        let shown = Array(model.days.suffix(Self.shownDays))

        if let today = model.days.last {
            HStack(spacing: 32) {
                stat("Fitness", today.fitness, color: .blue)
                stat("Fatigue", today.fatigue, color: .pink)
                stat("Form", today.form, color: .secondary)
            }

            Chart {
                ForEach(shown) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Form", day.form))
                        .foregroundStyle(by: .value("Measure", "Form"))
                        .opacity(0.45)
                }
                ForEach(shown) { day in
                    LineMark(x: .value("Day", day.day, unit: .day), y: .value("Fitness", day.fitness),
                             series: .value("Measure", "Fitness"))
                        .foregroundStyle(by: .value("Measure", "Fitness"))
                }
                ForEach(shown) { day in
                    LineMark(x: .value("Day", day.day, unit: .day), y: .value("Fatigue", day.fatigue),
                             series: .value("Measure", "Fatigue"))
                        .foregroundStyle(by: .value("Measure", "Fatigue"))
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4))
            }
            .chartForegroundStyleScale(domain: ["Fitness", "Fatigue", "Form"], range: [Color.blue, .pink, .gray])
            .frame(height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Training load, last \(shown.count) days")
            .accessibilityValue("Fitness \(Int(today.fitness.rounded())), fatigue \(Int(today.fatigue.rounded())), "
                                + "form \(Int(today.form.rounded()))")

            Text(footnote(days: model.days.count, uncounted: model.uncounted))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No workouts with heart rate yet.").foregroundStyle(.secondary)
        }
    }

    private func stat(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.palette)
                .tint(color)
            Text("\(Int(value.rounded()))").font(.title3.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func footnote(days: Int, uncounted: Int) -> String {
        var parts = ["Fitness is a 42-day average of daily training load, Fatigue a 7-day one; Form is "
                     + "yesterday's Fitness minus Fatigue — negative while building, positive when fresh. "
                     + "Load is TRIMP from each workout's average heart rate."]
        if days < Int(TrainingLoad.fitnessDays) {
            parts.append("With \(days) days of history Fitness is still building, so it reads low.")
        }
        if uncounted > 0 {
            parts.append("\(uncounted) workout\(uncounted == 1 ? "" : "s") without heart rate aren't counted.")
        }
        return parts.joined(separator: " ")
    }
}
