import MaxActCore
import SwiftUI

/// First-run guidance (Phase 8): what MaxAct needs, where the address and token come from, and a
/// connection test — before anyone commits to a sync that keeps their phone busy for an hour.
/// Shown on a first launch with nothing configured, and from Help ▸ Getting Started.
struct WelcomeSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var connected: Bool { model.connectionCheck?.succeeded == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "figure.run.square.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to MaxAct").font(.title2.weight(.semibold))
                    Text("MaxAct reads your workouts from Health Auto Export on your iPhone, and can "
                         + "upload them to Strava.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            step(1, "What you need") {
                Text("• **Health Auto Export** on your iPhone, with **Premium** — its server is a "
                     + "Premium feature.\n• The iPhone and this Mac on the **same Wi-Fi** network.")
            }
            step(2, "Start the server on your iPhone") {
                Text("In Health Auto Export, open the **Server** screen, turn on **HTTPS** and "
                     + "export its CA certificate, then start the server. It shows an address and a token.")
            }
            step(3, "Enter them here, and test") {
                ConnectionFields(model: model)
            }
            step(4, "Sync") {
                Text("A year of history takes \(SyncEstimate.describe(SyncEstimate.seconds(forDays: 365))); "
                     + "you choose how far back in the Sync panel. Keep Health Auto Export open and "
                     + "in front, with the phone unlocked, until it finishes — you can stop and "
                     + "resume at any point.")
            }

            HStack {
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Sync…") {
                    dismiss()
                    model.isSyncPanelPresented = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.settings.isConfigured)
            }
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityIdentifier("WelcomeSheet")
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(.quaternary, in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
