import MaxActCore
import SwiftUI

@main
struct MaxActApp: App {
    @State private var model: AppModel
    @State private var startupError: String?

    /// UI tests drive the real UI, so they must not drive the real *data*. Under this flag the
    /// app uses a throwaway defaults domain and an in-memory database, which also makes the tests
    /// deterministic instead of depending on whatever happens to be synced.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        if Self.isUITesting {
            let domain = "com.swiatlowski.MaxAct.uitests"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            let settings = SyncSettings(defaults: UserDefaults(suiteName: domain) ?? .standard)
            _model = State(initialValue: AppModel.inMemoryFallback(settings: settings))
            return
        }

        let settings = SyncSettings()
        // The stores are the app's foundation. If they can't open there is no useful degraded
        // mode, so fall back to memory and say so plainly rather than crashing at launch.
        do {
            let seriesStore = try SeriesStore()
            _model = State(initialValue: AppModel(
                store: WorkoutStore(modelContainer: try WorkoutStore.container()),
                seriesStore: seriesStore,
                thumbnails: try RouteThumbnailRenderer(seriesStore: seriesStore),
                settings: settings
            ))
        } catch {
            _model = State(initialValue: AppModel.inMemoryFallback(settings: settings))
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .alert(
                    "MaxAct couldn't open its database",
                    isPresented: .constant(startupError != nil)
                ) {
                    Button("Continue Anyway") { startupError = nil }
                } message: {
                    Text((startupError ?? "") + "\n\nWorkouts synced now will not be saved.")
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands { MaxActCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Menu-bar commands.
///
/// Every action in the toolbar and the context menu also appears here with a shortcut. That's Mac
/// convention, and it's also what makes actions discoverable and reachable from the keyboard.
struct MaxActCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // Opens the panel rather than starting immediately: how much history to import is a
            // per-sync choice, and starting a multi-hour job from a keystroke with no visible
            // range would be a trap.
            Button("Sync from iPhone…") { model.isSyncPanelPresented = true }
                .keyboardShortcut("r", modifiers: .command)

            Button("Stop Syncing") { model.cancelSync() }
                .disabled(!model.syncStatus.isRunning)

            Button("Download Detail for Selection") {
                model.startDetailFetch(for: model.selectedItems)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selection.isEmpty || model.syncStatus.isRunning
                      || !model.settings.isConfigured)
        }

        CommandGroup(after: .pasteboard) {
            Button("Select All Visible") { model.selectAllVisible() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Deselect All") { model.clearSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selection.isEmpty)
        }
    }
}
