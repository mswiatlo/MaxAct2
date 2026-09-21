import MaxActCore
import SwiftUI

/// The actions available on a selection.
///
/// One definition, used from the toolbar, the context menu and the menu bar. Mac convention is
/// that every action is reachable all three ways, and defining them once is the only way that
/// stays true as actions are added.
struct WorkoutActions: View {
    let model: AppModel
    let ids: Set<String>

    private var settings: SyncSettings { model.settings }

    private var items: [WorkoutListItem] {
        model.items.filter { ids.contains($0.id) }
    }

    var body: some View {
        let needingDetail = items.filter { !$0.hasDetail }

        Button {
            model.startDetailFetch(for: needingDetail)
        } label: {
            Label(
                needingDetail.count > 1
                    ? "Download Detail for \(needingDetail.count) Workouts"
                    : "Download Detail",
                systemImage: "arrow.down.circle"
            )
        }
        .disabled(needingDetail.isEmpty || model.syncStatus.isRunning || !settings.isConfigured)
        .help(settings.isConfigured
              ? "Fetch routes and heart rate from your iPhone"
              : "Set your iPhone's address in Settings first")

        // Phase 7 wires this to the real uploader; the state machine behind it already exists.
        Button {
        } label: {
            Label("Upload to Strava", systemImage: "arrow.up.circle")
        }
        .disabled(true)
        .help("Strava upload arrives in Phase 7")
    }
}

/// Connection settings, persisted in `UserDefaults`.
///
/// The bearer token is *not* a long-lived secret — it is regenerated from Health Auto Export's
/// Server screen at will, and only grants access to a server that must be foregrounded on an
/// unlocked phone on the same LAN. Strava's client secret in Phase 8 is a different matter and
/// goes in the Keychain.
@Observable
final class SyncSettings {
    /// Injected rather than reaching for `.standard`, so UI tests can be handed a throwaway
    /// domain. They type into these fields, and one test run overwriting the real token was
    /// enough to make this worth doing properly.
    @ObservationIgnored private let defaults: UserDefaults

    var host: String {
        didSet { defaults.set(host, forKey: "syncHost") }
    }
    var token: String {
        didSet { defaults.set(token, forKey: "syncToken") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: "syncHost") ?? ""
        token = defaults.string(forKey: "syncToken") ?? ""
    }

    /// The address as actually parsed, or `nil` if it can't be. Shown in the UI so there is no
    /// question about what will be contacted.
    var endpoint: MCPEndpoint? { MCPEndpoint(host) }

    var isConfigured: Bool {
        endpoint != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func makeSource() -> HAEWorkoutSource? {
        guard let endpoint, !token.isEmpty else { return nil }
        return HAEWorkoutSource(endpoint: endpoint, token: token.trimmingCharacters(in: .whitespaces))
    }
}

struct SettingsView: View {
    /// Only the settings object: this is presented in its own scene, which is another detached
    /// hosting context.
    @Bindable var settings: SyncSettings

    /// Optional so the scene still builds without it; the data section is omitted when absent.
    var model: AppModel?

    @State private var isConfirmingDelete = false
    @State private var storageDescription = "\u{2014}"

    var body: some View {

        Form {
            Section {
                TextField("iPhone address", text: $settings.host, prompt: Text("10.0.0.158"))
                TextField("Bearer token", text: $settings.token)
            } header: {
                Text("Health Auto Export")
            } footer: {
                Text("""
                    Open Health Auto Export on your iPhone, go to the Server screen and start the \
                    server, then copy the address and token shown there. The token can be \
                    regenerated there at any time.

                    The app must stay open and in the foreground while syncing, and the phone \
                    unlocked — Apple does not allow health data to be read otherwise.

                    How much history to import is chosen per sync, in the Sync panel.
                    """)
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

    /// Clearing the library is genuinely useful rather than merely tidy: re-testing a 30-day sync
    /// from scratch otherwise means deleting a container by hand.
    @ViewBuilder
    private func dataSection(_ model: AppModel) -> some View {
        Section {
            LabeledContent("Workouts", value: model.items.count.formatted())
            LabeledContent("Routes and heart rate", value: storageDescription)

            Button("Delete All Workouts\u{2026}", role: .destructive) { isConfirmingDelete = true }
                .disabled(model.items.isEmpty)
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
