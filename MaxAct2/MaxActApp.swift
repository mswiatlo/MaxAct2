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

    /// `--ui-testing-seed <n>` plants n synthetic workouts in the in-memory store. Only honoured
    /// alongside `--ui-testing`, so it can never touch the real database.
    static var uiTestingSeedCount: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-testing-seed"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        return Int(arguments[arguments.index(after: flag)])
    }

    init() {
        if Self.isUITesting {
            let domain = "com.swiatlowski.MaxAct.uitests"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            let settings = AppSettings(defaults: UserDefaults(suiteName: domain) ?? .standard)
            _model = State(initialValue: AppModel.inMemoryFallback(
                settings: settings, seedCount: Self.uiTestingSeedCount
            ))
            return
        }

        let settings = AppSettings()
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
            ContentView(model: model)
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
            SettingsView(settings: model.settings, model: model)
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

        // No Select All here on purpose. The standard `.pasteboard` group already provides
        // Edit ▸ Select All, and SwiftUI wires it to the table's selection binding — ⌘A selects
        // every visible row for free. A second item would mean two ⌘A entries in one menu, where
        // AppKit routes the keystroke to the first and ours would show a shortcut that never
        // fires. (It also had to be ⌘⇧A to avoid that, which Zoom takes globally.)
        CommandGroup(after: .pasteboard) {
            Button("Deselect All") { model.clearSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selection.isEmpty)
        }
    }
}
