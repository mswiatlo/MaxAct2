import MaxActCore
import SwiftUI

/// The actions available on a selection.
///
/// One definition, used from the toolbar, the context menu and the menu bar. Mac convention is
/// that every action is reachable all three ways, and defining them once is the only way that
/// stays true as actions are added.
struct WorkoutActions: View {
    let ids: Set<String>

    @Environment(AppModel.self) private var model

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
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "syncHost") }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "syncToken") }
    }
    init() {
        host = UserDefaults.standard.string(forKey: "syncHost") ?? ""
        token = UserDefaults.standard.string(forKey: "syncToken") ?? ""
    }

    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    func makeSource() -> HAEWorkoutSource? {
        guard isConfigured else { return nil }
        return HAEWorkoutSource(host: host, token: token)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
