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

    /// Rough duration, from the measured ~2.4 s per workout at ~1.1 workouts a day. Sync is slow
    /// in a way that surprises people, so say so before they commit to it.
    var estimate: String {
        let seconds = years * 365 * 1.12 * 2.4
        if seconds < 90 { return "about \(Int(seconds.rounded())) seconds" }
        if seconds < 5400 { return "about \(Int((seconds / 60).rounded())) minutes" }
        return "about \(String(format: "%.1f", seconds / 3600)) hours"
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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var range: SyncRange = .month

    var body: some View {
        @Bindable var settings = model.settings

        VStack(alignment: .leading, spacing: 14) {
            Text("Sync from iPhone")
                .font(.headline)

            if model.syncStatus.isRunning {
                running
            } else {
                connection(host: $settings.host, token: $settings.token)
                Divider()
                importControls(isReady: model.settings.isConfigured)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    // MARK: - Connection

    @ViewBuilder
    private func connection(host: Binding<String>, token: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In Health Auto Export on your iPhone, open the **Server** screen and start the "
                 + "server. It shows an address and a token — copy both here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("iPhone address") {
                // No placeholder that looks like a real value: the previous prompt read
                // "10.0.0.158", which is indistinguishable from a filled-in field at a glance,
                // so the host stayed empty and nothing said so.
                TextField("", text: host, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Token") {
                TextField("", text: token, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let missing = missingFieldDescription {
                Label(missing, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var missingFieldDescription: String? {
        let host = model.settings.host.trimmingCharacters(in: .whitespaces)
        let token = model.settings.token.trimmingCharacters(in: .whitespaces)
        switch (host.isEmpty, token.isEmpty) {
        case (true, true): return "Enter the address and token shown on the Server screen."
        case (true, false): return "The iPhone address is still empty."
        case (false, true): return "The token is still empty."
        case (false, false): return nil
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
        .disabled(!isReady)

        Text(isReady
             ? "Takes \(range.estimate). Keep Health Auto Export open and in the foreground with "
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
                model.startSync(from: range.startDate())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isReady)
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var running: some View {
        if case .running(let completed, let total, let found) = model.syncStatus {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text("Week \(completed) of \(total) · \(found) workouts imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Keep Health Auto Export in the foreground until this finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Stop Syncing") { model.cancelSync() }
        }
    }
}
