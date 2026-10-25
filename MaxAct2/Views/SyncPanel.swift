import MaxActCore
import SwiftUI

/// How far back a sync reaches.
///
/// Lives with the sync action rather than in Settings: it's a decision made *per sync* — a daily
/// top-up wants a week, the initial import wants everything — not a preference you set once.
enum SyncRange: String, CaseIterable, Identifiable {
    case week, month, threeMonths, year, everything
    /// One chosen calendar month (issue 17) — e.g. to fetch a race month for checking Strava's
    /// race flag, without re-syncing everything since.
    case specificMonth

    var id: Self { self }

    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .threeMonths: "Last 3 months"
        case .year: "Last year"
        case .everything: "Everything"
        case .specificMonth: "A specific month…"
        }
    }

    /// How far back, for the estimate and the start date. "Everything" has no fixed span (issue
    /// 24) and syncs through `startSyncEverything`, so its value here only sizes nothing.
    var years: Double {
        switch self {
        case .week: 7.0 / 365
        case .month: 30.0 / 365
        case .threeMonths: 0.25
        case .year: 1
        case .everything: 0
        case .specificMonth: 31.0 / 365   // the picked month's own length is used where it matters
        }
    }

    func startDate(from end: Date = .now) -> Date {
        end.addingTimeInterval(-years * 365 * 24 * 3600)
    }

    /// Rough duration. The per-workout cost lives in `SyncEstimate`, shared with the detail
    /// backfill so the two can't drift apart.
    var estimate: String {
        SyncEstimate.describe(SyncEstimate.seconds(forDays: years * 365))
    }
}

/// The sync control, shown as a popover from the toolbar.
///
/// **Everything needed to run a sync is in here, including the connection fields.** Two earlier
/// attempts both dead-ended:
///
/// 1. No affordance at all — the empty state said "add your iPhone's address in Settings" with no
///    button, and the toolbar icons were unlabelled and disabled.
/// 2. This panel, but sending people to Settings to type the address. That's four hops (Sync →
///    Settings → type → close → Sync again) with nothing bringing you back, and in practice the
///    host silently stayed empty while the token got filled in, so pressing Sync just re-opened
///    Settings for ever.
///
/// So the fields are here, the panel says which one is missing, and one press of Sync reaches a
/// running sync. Settings keeps the same fields for later editing.
struct SyncPanel: View {
    /// Passed in rather than read from the environment. A popover is a separate `NSWindow`, and
    /// its content does **not** reliably inherit `.environment(...)` — when the main window
    /// re-laid out (which pressing Start Sync causes, since the progress banner appears) the
    /// popover's body was re-evaluated without it and the app trapped with "No Observable object
    /// of type AppModel found". An explicit dependency cannot fail that way, and `@Observable`
    /// still tracks it because tracking keys off property access, not off how the reference
    /// arrived.
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var range: SyncRange = .month
    @State private var chosenMonth = Calendar.current.component(.month, from: .now)
    @State private var chosenYear = Calendar.current.component(.year, from: .now)

    /// The chosen month, in local time; `nil` for one that hasn't started yet.
    private var chosenInterval: DateInterval? {
        SyncPlanner.month(chosenMonth, of: chosenYear, calendar: .current)
    }

    /// What Start Sync will import, or `nil` if the choice can't be imported.
    private var importInterval: DateInterval? {
        switch range {
        case .specificMonth: chosenInterval
        // No fixed start: the walk finds it (issue 24). The span is only a placeholder.
        case .everything: DateInterval(start: BackfillWalker.floor, end: .now)
        default: DateInterval(start: range.startDate(), end: .now)
        }
    }
    @State private var backfillScope: AppModel.BackfillScope = .everything

    var body: some View {
        @Bindable var settings = model.settings

        return VStack(alignment: .leading, spacing: 14) {
            Text("Sync from iPhone")
                .font(.headline)

            if model.syncStatus.isRunning {
                running
            } else {
                connection
                Divider()
                importControls(isReady: model.settings.isConfigured)
                Divider()
                backfillControls(isReady: model.settings.isConfigured)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    // MARK: - Connection

    @ViewBuilder
    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In Health Auto Export on your iPhone, open the **Server** screen and start the "
                 + "server. Copy the address and token it shows. The IP alone is enough — "
                 + "`10.0.0.158` — but a full URL works too.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ConnectionFields(model: model)
        }
    }

    // MARK: - Import

    @ViewBuilder
    private func importControls(isReady: Bool) -> some View {
        Picker("Import", selection: $range) {
            ForEach(SyncRange.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        // A menu picker's title is separate text; without this the pop-up itself is unnamed and
        // VoiceOver reads only its value.
        .accessibilityLabel("Import")
        .disabled(!isReady)

        if range == .specificMonth {
            HStack {
                Picker("Month", selection: $chosenMonth) {
                    ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                }
                .accessibilityLabel("Month")
                Picker("Year", selection: $chosenYear) {
                    // Back to Health's launch. ("Everything" reaches further, for imported histories.)
                    let thisYear = Calendar.current.component(.year, from: .now)
                    ForEach((2014...thisYear).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }
                // `labelsHidden` keeps the title for accessibility; adding a label as well made
                // VoiceOver say "Year, Year".
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!isReady)
            if chosenInterval == nil {
                Label("That month hasn't started yet.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Text(isReady
             ? "\(estimate). Keep Health Auto Export open and in the foreground with "
               + "the phone unlocked. You can stop at any point and resume later — finished weeks "
               + "are kept."
             : "Health Auto Export must stay open and in the foreground while syncing, with the "
               + "phone unlocked.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            SettingsLink { Text("Settings…") }
            Spacer()
            Button("Start Sync") {
                guard let interval = importInterval else { return }
                if range == .everything {
                    model.startSyncEverything()
                } else {
                    model.startSync(from: interval.start, to: interval.end)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isReady || importInterval == nil)
        }
    }

    private var estimate: String {
        if range == .everything {
            // The length of a history isn't known until the walk finds its start.
            return "Goes back until there's nothing older, at about "
                + "\(SyncEstimate.secondsPerWorkout.formatted(.number.precision(.fractionLength(1)))) s per workout — "
                + "hours for a long history"
        }
        guard let interval = importInterval else { return "Takes " + range.estimate }
        return "Takes " + SyncEstimate.describe(SyncEstimate.seconds(forDays: interval.duration / 86_400))
    }

    // MARK: - Detail backfill

    /// Fills in routes and second-resolution series for workouts that only have summaries.
    ///
    /// Lives here rather than in the toolbar because it shares everything with Start Sync: the
    /// same precondition (HAE open and foregrounded), the same progress banner, the same stop
    /// control. The toolbar already carries four controls.
    ///
    /// The count and the estimate are in the button itself, so the cost is visible *before*
    /// committing to it — a full backlog is hours of foregrounded phone.
    @ViewBuilder
    private func backfillControls(isReady: Bool) -> some View {
        let count = model.backlogCount(backfillScope)

        VStack(alignment: .leading, spacing: 8) {
            Text("Missing Detail")
                .font(.headline)

            Text("A sync fetches summaries only. Routes and second-by-second heart rate are "
                 + "downloaded separately, one workout at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Only worth offering a scope when the current filter actually narrows things.
            if model.backlogCount(.visible) != model.backlogCount(.everything) {
                Picker("Fill in", selection: $backfillScope) {
                    Text("All workouts (\(model.backlogCount(.everything)))")
                        .tag(AppModel.BackfillScope.everything)
                    Text("Current filter (\(model.backlogCount(.visible)))")
                        .tag(AppModel.BackfillScope.visible)
                }
                .pickerStyle(.radioGroup)
            }

            Button {
                model.startDetailBackfill(scope: backfillScope)
                dismiss()
            } label: {
                if count == 0 {
                    Text("Everything Is Downloaded")
                } else {
                    Text("Download \(count) Workout\(count == 1 ? "" : "s") — "
                         + SyncEstimate.describe(workoutCount: count))
                }
            }
            .disabled(!isReady || count == 0)
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var running: some View {
        if case .running(let activity, let completed, let total, let found) = model.syncStatus {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                if case .listingEverything(let reachedBack) = activity {
                    // No "n of m" and no time left: how far back the history goes isn't known
                    // until the walk gets there.
                    Text("Back to \(reachedBack.formatted(.dateTime.month(.wide).year())) · \(found) workouts imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SyncEverythingProgress")
                } else {
                    Text(activity == .listing
                         ? "Week \(completed) of \(total) · \(found) workouts imported"
                         : "Workout \(completed) of \(total) · \(found) downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // The remaining cost, kept live, since a backfill can run for hours.
                    Text("\(SyncEstimate.describe(workoutCount: max(total - completed, 0))) remaining")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Keep Health Auto Export in the foreground until this finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Stop Syncing") { model.cancelSync() }
        }
    }
}
