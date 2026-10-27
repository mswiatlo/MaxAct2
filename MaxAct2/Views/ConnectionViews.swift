import MaxActCore
import SwiftUI
import UniformTypeIdentifiers

/// HTTPS to the phone, and the CA it's pinned to (issue 48). Shared by `ConnectionFields` and
/// Settings. A switch in both, so it looks the same wherever it appears (issue 49).
struct HTTPSFields: View {
    @Bindable var settings: AppSettings

    @State private var isImporting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use HTTPS", isOn: $settings.usesHTTPS)
                .toggleStyle(.switch)
                .accessibilityIdentifier("UseHTTPS")   // in a form, the title is a separate text
                .help("Encrypts the link to the phone. Turn it on in Health Auto Export's server settings too.")
            if settings.usesHTTPS {
                if let ca = settings.pinnedCA {
                    LabeledContent("Trusts") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ca.subjectSummary)
                            Text(ca.fingerprint)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityLabel("SHA-256 fingerprint \(ca.fingerprint)")
                        }
                    }
                    Button("Replace Certificate…") { isImporting = true }
                } else {
                    Button("Load Certificate…") { isImporting = true }
                    Text("In Health Auto Export, turn on HTTPS and export its CA certificate, then load it here. "
                         + "MaxAct trusts it for the phone only, not system-wide.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Names the cause — HTTPS being off — so it can't read as a warning about the toggle.
                Label("HTTPS is off, which is less safe: anyone on this network can read the token and your workouts as they sync.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.x509Certificate, UTType(filenameExtension: "pem") ?? .data]) { result in
            load(result)
        }
    }

    private func load(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            settings.pinnedCA = try PinnedCA(contents: Data(contentsOf: url))
            problem = nil
        } catch let error as PinnedCA.Problem {
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The welcome sheet's address and token fields, with HTTPS and the connection's status.
///
/// Since issue 49 the welcome sheet and Settings are the only places the connection is edited; the
/// sync panel only reports on it. Settings lays the same settings out as form rows.
struct ConnectionFields: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("iPhone address") {
                // No placeholder that looks like a real value: the previous prompt read
                // "10.0.0.158", which is indistinguishable from a filled-in field at a glance,
                // so the host stayed empty and nothing said so.
                TextField("", text: $settings.host, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
            }
            HTTPSFields(settings: settings)
            LabeledContent("Token") {
                // Hidden, like the Strava secret (issue 47): it grants your whole Health export.
                SecureField("", text: $settings.token, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            ConnectionStatus(model: model)
        }
    }
}

/// What the connection settings resolve to, what's missing, and Test Connection. Below the fields
/// in the welcome sheet and in Settings.
struct ConnectionStatus: View {
    let model: AppModel

    private var settings: AppSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Shows exactly what will be contacted. Whether to include the scheme, port and path
            // was genuinely ambiguous — all four forms are accepted, and echoing the resolved URL
            // answers the question better than any amount of instruction text.
            if let endpoint = settings.endpoint {
                Label("Connects to \(endpoint.description)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let keep = settings.tokenSaveProblem {
                Label("The token couldn't be saved in the Keychain: \(keep)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let missing = settings.missingConnectionDescription {
                Label(missing, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button("Test Connection") { Task { await model.checkConnection() } }
                    .disabled(!settings.isConfigured || model.isCheckingConnection || model.syncStatus.isRunning)
                if model.isCheckingConnection {
                    ProgressView().controlSize(.small)
                    Text(model.connectionProgress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let check = model.connectionCheck, !model.isCheckingConnection {
                Label {
                    Text(check.summary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: check.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.succeeded ? .green : .orange)
                }
                .font(.callout)
            }
        }
        // A result describes the settings it was run with; editing any of them makes it stale.
        .onChange(of: settings.host) { model.clearConnectionCheck() }
        .onChange(of: settings.token) { model.clearConnectionCheck() }
        .onChange(of: settings.usesHTTPS) { model.clearConnectionCheck() }
        .onChange(of: settings.pinnedCA) { model.clearConnectionCheck() }
    }
}
