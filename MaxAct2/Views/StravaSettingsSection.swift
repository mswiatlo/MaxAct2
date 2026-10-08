import AuthenticationServices
import MaxActCore
import SwiftUI

/// Settings → Strava: the user's own API application, and connecting their account to it.
///
/// Their own application rather than one shipped with MaxAct, because Strava's OAuth has no PKCE —
/// the client secret is needed for every token exchange, and one baked into the app would be
/// extractable and would share a single rate-limit budget between everyone.
struct StravaSettingsSection: View {
    let model: AppModel

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        Section {
            if model.isStravaConnected {
                LabeledContent("Connected as", value: model.stravaAthlete ?? "")
                Toggle("Mute uploaded activities", isOn: Binding(
                    get: { model.settings.muteStravaUploads },
                    set: { model.settings.muteStravaUploads = $0 }
                ))
                .help("Keeps uploads off followers' home feeds — useful when uploading old workouts in bulk")
                Button("Check for Workouts Already on Strava") { model.startStravaCheck() }
                    .disabled(model.syncStatus.isRunning)
                    .help("Matches by time, so it finds workouts the watch uploaded, not only MaxAct's")
                Button("Disconnect", role: .destructive) {
                    Task { await model.disconnectStrava() }
                }
            } else {
                TextField("Client ID", text: $clientID, prompt: Text("12345"))
                SecureField("Client secret", text: $clientSecret)
                Button(isWorking ? "Connecting…" : "Connect to Strava…") {
                    Task { await connect() }
                }
                .disabled(isWorking || clientID.trimmingCharacters(in: .whitespaces).isEmpty
                          || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("Strava")
        } footer: {
            if !model.isStravaConnected {
                Text("""
                    MaxAct uploads through your own Strava API application. Create one at \
                    strava.com/settings/api, set its **Authorization Callback Domain** to \
                    **localhost**, then paste its client ID and secret here. Both are kept in \
                    your Keychain.

                    When Strava asks, leave "Upload your activities" ticked.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .task { await model.refreshStravaConnection() }
    }

    private func connect() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await model.saveStravaCredentials(clientID: clientID, clientSecret: clientSecret)
            guard let request = await model.stravaAuthorizationRequest() else { return }
            let callback = try await webAuthenticationSession.authenticate(
                using: request.url, callbackURLScheme: AppModel.stravaCallbackScheme
            )
            try await model.completeStravaConnection(callback: callback, expectedState: request.state)
            clientSecret = ""
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the browser is a choice, not an error.
        } catch let error as StravaError {
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }
}
