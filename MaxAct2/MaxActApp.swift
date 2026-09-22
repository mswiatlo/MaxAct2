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

    /// `--ui-testing-seed=<n>` plants n synthetic workouts in the in-memory store. Only honoured
    /// alongside `--ui-testing`, so it can never touch the real database.
    ///
    /// **The `=` is load-bearing.** Passed as two tokens — `--ui-testing-seed 40` — the app never
    /// opens a window at all when launched by anything other than LaunchServices, which is exactly
    /// how XCUITest launches it. `NSUserDefaults` builds its argument domain by pairing each
    /// `-key` with the *following* token, so it consumes `--ui-testing-seed` as the value of
    /// `-ui-testing` and leaves the bare `40` as a stray argument. AppKit reads a stray argument
    /// as a file to open, and that request — for a document this app can't open, in an app with no
    /// `DocumentGroup` — suppresses `WindowGroup`'s window. `App.body` runs; its content closure
    /// never does. Joining the value into one token leaves nothing stray.
    static var uiTestingSeedCount: Int? {
        let prefix = "--ui-testing-seed="
        guard let argument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return Int(argument.dropFirst(prefix.count))
    }

    init() {
        if Self.isUITesting {
            let domain = "com.swiatlowski.MaxAct.uitests"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            let settings = AppSettings(defaults: UserDefaults(suiteName: domain) ?? .standard)
            _model = State(initialValue: AppModel.inMemoryFallback(
                settings: settings,
                seedCount: Self.uiTestingSeedCount,
                resolvesPlaces: false
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
                // `defaultSize` alone does not take: with no saved frame the window opened at
                // SwiftUI's 700×780 fallback. An ideal width on the content is what the window
                // actually sizes itself to.
                //
                // 1,300 is measured, not derived. Widening in steps and watching when the
                // columns stop sitting at their minimums put the fit between 1,230 (squeezed)
                // and 1,250 (slack); the content's own ideal then settles at 1,300, and asking
                // for less than that is ignored, so the declared value matches what it does.
                //
                // The arithmetic misleads here, which is how an earlier 1,090 shipped too narrow:
                // the sidebar (223) plus the column widths (824) is only 1,047, because a
                // `.inset` table adds roughly 185pt of gutters and insets that the persisted
                // column widths don't include.
                //
                // `minWidth` stays well below: the window should still drag narrow, it just
                // means the table scrolls.
                .frame(minWidth: 1040, idealWidth: 1300, minHeight: 480, idealHeight: 780)
                .alert(
                    "MaxAct couldn't open its database",
                    isPresented: .constant(startupError != nil)
                ) {
                    Button("Continue Anyway") { startupError = nil }
                } message: {
                    Text((startupError ?? "") + "\n\nWorkouts synced now will not be saved.")
                }
        }
        // Sized to hold the table and no more. Measured, not estimated: with the inspector closed
        // the table settles at the sum of its column *minimums*, 824pt including the fixed Route
        // column, and the sidebar takes 223pt. 1,090 leaves ~40pt for the table's own inset and
        // the scroller gutter without leaving a band of empty space to the right.
        //
        // The inspector is deliberately not counted, because it starts closed — opening it widens
        // the window rather than squeezing the list.
        .defaultSize(width: 1300, height: 780)
        .commands {
            MaxActCommands(model: model)
            // View ▸ Show/Hide Inspector with its standard shortcut. The detail pane starts
            // hidden, so there has to be a way to open it that isn't "select something".
            InspectorCommands()
        }

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
