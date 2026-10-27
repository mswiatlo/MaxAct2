import MaxActCore
import SwiftUI
import UniformTypeIdentifiers

/// HTTPS to the phone, and the CA it's pinned to (issue 48). Shared by `ConnectionFields` and
/// Settings.
struct HTTPSFields: View {
    @Bindable var settings: AppSettings

    @State private var isImporting = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use HTTPS", isOn: $settings.usesHTTPS)
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
                Label("Less safe: anyone on this network can read the token and your workouts as they sync.",
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

/// The iPhone address and token, with what they resolve to, what's missing, and Test Connection.
/// Shared by the sync panel and the welcome sheet so the two can't drift apart.
struct ConnectionFields: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("iPhone address") {
                // No placeholder that looks like a real value: the previous prompt read
                // "10.0.0.158", which is indistinguishable from a filled-in field at a glance,
                // so the host stayed empty and nothing said so.
                TextField("", text: $settings.host, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
            }

            // Shows exactly what will be contacted. Whether to include the scheme, port and path
            // was genuinely ambiguous — all four forms are accepted, and echoing the resolved URL
            // answers the question better than any amount of instruction text.
            if let endpoint = settings.endpoint {
                Label("Connects to \(endpoint.description)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HTTPSFields(settings: settings)
            LabeledContent("Token") {
                // Hidden, like the Strava secret (issue 47): it grants your whole Health export.
                SecureField("", text: $settings.token, prompt: Text("required"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let keep = settings.tokenSaveProblem {
                Label("The token couldn't be saved in the Keychain: \(keep)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let missing = missingFieldDescription {
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
        // A result describes the address and token it was run with; editing either makes it stale.
        .onChange(of: settings.host) { model.clearConnectionCheck() }
        .onChange(of: settings.token) { model.clearConnectionCheck() }
        .onChange(of: settings.usesHTTPS) { model.clearConnectionCheck() }
        .onChange(of: settings.pinnedCA) { model.clearConnectionCheck() }
    }

    private var missingFieldDescription: String? {
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        let token = settings.token.trimmingCharacters(in: .whitespaces)
        if host.isEmpty && token.isEmpty {
            return "Enter the address and token shown on the Server screen."
        }
        if host.isEmpty { return "The iPhone address is still empty." }
        if MCPEndpoint(host) == nil {
            return "That address can't be read. Try just the IP, like 192.168.1.20."
        }
        if token.isEmpty { return "The token is still empty." }
        if settings.usesHTTPS && settings.pinnedCA == nil { return "HTTPS needs Health Auto Export's certificate." }
        return nil
    }
}

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
