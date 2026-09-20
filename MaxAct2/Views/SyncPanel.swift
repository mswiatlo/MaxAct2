import MaxActCore
import SwiftUI

/// How far back a sync reaches.
///
/// Lives with the sync action rather than in Settings: it's a decision made *per sync* — a daily
/// top-up wants a week, the initial import wants everything — not a preference you set once.
enum SyncRange: String, CaseIterable, Identifiable {
    case week, month, threeMonths, year, everything

    var id: Self { self }

    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .threeMonths: "Last 3 months"
        case .year: "Last year"
        case .everything: "Everything (7 years)"
        }
    }

    var years: Double {
        switch self {
        case .week: 7.0 / 365
        case .month: 30.0 / 365
        case .threeMonths: 0.25
        case .year: 1
        case .everything: 7
        }
    }

    func startDate(from end: Date = .now) -> Date {
        end.addingTimeInterval(-years * 365 * 24 * 3600)
    }

    /// Roughly how long this will take, from the measured ~2.4 s per workout and ~1.1 workouts a
    /// day. Sync is slow in a way that surprises people, so say so before they commit to it.
    var estimate: String {
        let workouts = years * 365 * 1.12
        let seconds = workouts * 2.4
        if seconds < 90 { return "about \(Int(seconds.rounded())) seconds" }
        if seconds < 5400 { return "about \(Int((seconds / 60).rounded())) minutes" }
        return "about \(String(format: "%.1f", seconds / 3600)) hours"
    }
}

/// The sync control, shown as a popover from the toolbar.
///
/// Exists because the first version had no discoverable way to start a sync at all: the empty
/// state told people to visit Settings but gave them no way to get there, and the toolbar buttons
/// were unlabelled icons that were disabled until configuration existed — so there was nothing to
/// click and nothing to learn from. Everything needed to run a sync is now in one place, including
/// the route to Settings.
struct SyncPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var range: SyncRange = .month

    private var settings: SyncSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync from iPhone")
                .font(.headline)

            if settings.isConfigured {
                configured
            } else {
                notConfigured
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    // MARK: - Ready to sync

    @ViewBuilder
    private var configured: some View {
        Label("Health Auto Export at \(settings.host)", systemImage: "iphone")
            .font(.callout)
            .foregroundStyle(.secondary)

        // The constraint people trip over, stated where they're about to hit it rather than buried
        // in Settings.
        GroupBox {
            Label(
                "Open Health Auto Export on your iPhone and start its server. Keep the app in the "
                + "foreground and the phone unlocked until the sync finishes.",
                systemImage: "exclamationmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        if model.syncStatus.isRunning {
            running
        } else {
            Picker("Import", selection: $range) {
                ForEach(SyncRange.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Text("Takes \(range.estimate). You can stop at any point and resume later — finished "
                 + "weeks are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SettingsLink { Text("Server Settings…") }
                Spacer()
                Button("Start Sync") {
                    model.startSync(from: range.startDate())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var running: some View {
        if case .running(let completed, let total, let found) = model.syncStatus {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("Week \(completed) of \(total) · \(found) workouts imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Stop Syncing") { model.cancelSync() }
        }
    }

    // MARK: - Needs setting up

    @ViewBuilder
    private var notConfigured: some View {
        Text("MaxAct reads your workouts from Health Auto Export on your iPhone, over your local "
             + "network.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 5) {
            step(1, "Open Health Auto Export on your iPhone.")
            step(2, "Go to the Server screen and start the server.")
            step(3, "Copy the address and token it shows into Server Settings.")
        }

        // The fix for the original dead end: an actual route to Settings.
        SettingsLink { Text("Open Server Settings…") }
            .buttonStyle(.borderedProminent)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
