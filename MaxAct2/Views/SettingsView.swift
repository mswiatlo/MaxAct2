import MaxActCore
import SwiftUI

struct SettingsView: View {
    /// Only the settings object: this is presented in its own scene, which is another detached
    /// hosting context.
    @Bindable var settings: AppSettings

    /// Optional so the scene still builds without it; the data section is omitted when absent.
    var model: AppModel?

    @State private var isConfirmingDelete = false
    @State private var storageDescription = "\u{2014}"

    var body: some View {

        Form {
            Section {
                // Not a sample address: one reads as filled in (see `WelcomeSheet`).
                // A grouped form draws each title as separate text and leaves the control itself
                // unnamed — VoiceOver read the address field as "required" — so name them.
                TextField("iPhone address", text: $settings.host, prompt: Text("required"))
                    .accessibilityLabel("iPhone address")
                    .accessibilityIdentifier("SettingsHost")
                SecureField("Bearer token", text: $settings.token)   // hidden (issue 47)
                    .accessibilityLabel("Bearer token")
                HTTPSFields(settings: settings)
                if let model {
                    ConnectionStatus(model: model)
                }
            } header: {
                Text("Health Auto Export")
            } footer: {
                Text("""
                    Open Health Auto Export on your iPhone, go to the Server screen and start the \
                    server, then copy the address and token shown there. The token can be \
                    regenerated there at any time, and is kept in your Keychain.

                    The app must stay open and in the foreground while syncing, and the phone \
                    unlocked — Apple does not allow health data to be read otherwise.

                    How much history to import is chosen per sync, in the Sync panel.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let model {
                StravaSettingsSection(model: model)
            }

            appearanceSection

            Section {
                HeartRateProfileFields(settings: settings, suggestedMaximum: model?.suggestedMaximumHeartRate)
            } header: {
                Text("Training load")
            } footer: {
                Text("Used for Fitness, Fatigue and Form in Statistics.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let model {
                dataSection(model)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .task {
            if let model { storageDescription = Self.describeBytes(await model.storageBytes()) }
        }
    }

    /// Swatches rather than colour names alone: the names are arbitrary, and the only thing that
    /// matters is what the track will look like.
    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Route colour", selection: $settings.routeColor) {
                ForEach(RouteColor.allCases) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Circle().fill(Color(color))
                    }
                    .tag(color)
                }
            }
            .accessibilityLabel("Route colour")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Used for route tracks on the map and in the list. Thumbnails already drawn are "
                 + "redrawn in the new colour as they come back into view.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Clearing the library is genuinely useful rather than merely tidy: re-testing a 30-day sync
    /// from scratch otherwise means deleting a container by hand.
    @ViewBuilder
    private func dataSection(_ model: AppModel) -> some View {
        Section {
            LabeledContent("Workouts", value: model.items.count.formatted())
            LabeledContent("Routes and heart rate", value: storageDescription)

            Button("Delete All Workouts\u{2026}", role: .destructive) { isConfirmingDelete = true }
                .disabled(model.items.isEmpty || model.syncStatus.isRunning)
        } header: {
            Text("Stored Data")
        } footer: {
            Text("Deletes every workout, route and cached map from this Mac. Your iPhone's "
                 + "address and token are kept, and nothing on your iPhone or Strava is "
                 + "affected \u{2014} everything here can be synced again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Delete all \(model.items.count) workouts?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete All Workouts", role: .destructive) {
                Task {
                    await model.deleteAllData()
                    storageDescription = Self.describeBytes(await model.storageBytes())
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone here, but re-syncing restores everything. Re-downloading "
                 + "detail would take "
                 + SyncEstimate.describe(workoutCount: model.items.count) + ".")
        }
    }

    private static func describeBytes(_ bytes: Int) -> String {
        bytes == 0 ? "None" : ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }
}
