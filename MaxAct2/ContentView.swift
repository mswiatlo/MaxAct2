import MaxActCore
import SwiftUI

/// The model is threaded through explicitly rather than via `@Environment`.
///
/// On macOS, AppKit hosts plenty of SwiftUI content in *detached* `NSHostingView`s — table cells,
/// toolbars, menus, popovers — and those do not reliably inherit environment objects injected up
/// the main hierarchy. Relying on the environment crashed this app twice with "No Observable
/// object of type AppModel found": once in the sync popover when the window re-laid out, and once
/// in a table cell while scrolling. Passing the object removes the whole class of failure, and
/// `@Observable` tracking is unaffected because it keys off property access, not off how the
/// reference arrived.
struct ContentView: View {
    @Bindable var model: AppModel

    private var settings: AppSettings { model.settings }

    @State private var newTagName = ""

    /// Whether the pane is closed because the user closed it, as opposed to never having opened.
    ///
    /// An explicit close **sticks**: clicking another row afterwards leaves it closed, the way
    /// Finder and Xcode treat their inspectors. The alternative — reopening on the next selection
    /// — means the close button can't actually be obeyed while a row is selected, which is most of
    /// the time. Now that there's a toolbar toggle and ⌃⌘I, reopening is cheap and visible.
    @State private var hasClosedDetail = false

    /// The sidebar starts **shown**, stated explicitly rather than left to AppKit's saved split-view
    /// state. That state was persisting a *collapse the user never chose*: opening the inspector at
    /// the default width left no room for all three panes, AppKit squeezed the sidebar out, and
    /// then remembered that as the preference — so the next launch opened without a sidebar. UI
    /// tests share the app's defaults, which is how it surfaced: every sidebar test failed after a
    /// real session had saved `…, YES` (collapsed) for the sidebar's frame.
    ///
    /// Stating the visibility also stopped the live squeeze, not just its persistence: with the
    /// inspector open the sidebar keeps its width and the **table** absorbs the loss instead, which
    /// is also what Xcode, Finder and Mail do. Growing the window by the inspector's width was
    /// built and then removed: AppKit's frame autosave made the new width stick, so one selection
    /// would have left the window permanently wider even with the inspector shut. What remains is
    /// a *minimum* width while the inspector is open — see `AppModel.minimumWidthWithInspector`.
    @State private var columns: NavigationSplitViewVisibility = .all

    /// An **inspector**, not a third `NavigationSplitView` column.
    ///
    /// The split view can't express this: `columnVisibility` controls only the *leading* columns,
    /// and `.doubleColumn` on a three-column view hides the **sidebar**. There is no value that
    /// hides the detail. An inspector is the macOS control for a trailing pane that comes and
    /// goes — it has a standard toggle, a resizable width with a real minimum, and the framework
    /// restores whether it was open.
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
        } detail: {
            workoutList
        }
        .inspector(isPresented: systemInspectorPresented) {
            DetailPane(model: model)
        }
        // Lets View ▸ Hide Sidebar read and write the same state the split view uses.
        .focusedSceneValue(\.sidebarVisibility, $columns)
        // Revealed on the first selection, and then left alone. Collapsing it again on every
        // deselect would make the pane flap in and out as someone clicks down a list, and once
        // it's open the user has told us they want it.
        .onChange(of: model.selection.isEmpty) { _, isEmpty in
            if !isEmpty && !hasClosedDetail { model.showsDetail = true }
        }
        // Closing by *any* route — the toolbar toggle, ⌃⌘I, dragging the divider shut — counts as
        // the user closing it; opening by any route clears that.
        .onChange(of: model.showsDetail) { _, isShowing in
            hasClosedDetail = !isShowing
        }
        // "Region" earns its place in the prompt: matching "British Columbia" or "Switzerland"
        // against a label that only says "Greater Vancouver BC" is not something anyone would
        // guess works.
        .searchable(text: $model.searchText, prompt: "Activity, place, region, tag or app")
        // "New Tag…" from the Tags menu. Hosted here because a menu can't contain a text field.
        .alert("New Tag", isPresented: Binding(
            get: { model.newTagTargets != nil },
            set: { if !$0 { model.newTagTargets = nil } }
        )) {
            TextField("Name", text: $newTagName)
            Button("Add") {
                if let targets = model.newTagTargets { model.addTag(newTagName, to: targets) }
                newTagName = ""
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { newTagName = "" }
        } message: {
            Text("Commute, Trainer and Race (runs and rides) are also set on Strava. Other tags stay on this Mac.")
        }

        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                loadErrorBanner
                syncBanner
            }
        }
        .task {
            // A first launch with nothing set up: say what MaxAct needs before anything else. Not
            // shown to anyone already configured, so an update doesn't greet existing users.
            if MaxActApp.showsWelcomeOnFirstLaunch && !settings.hasSeenWelcome && !settings.isConfigured {
                model.isWelcomePresented = true
            }
            await model.load()
        }
        .sheet(isPresented: $model.isWelcomePresented, onDismiss: { settings.hasSeenWelcome = true }) {
            WelcomeSheet(model: model)
        }
    }

    /// The window's real inspector, **kept shut while Statistics is showing** (issue 8a). Beside
    /// statistics it can't be laid out: SwiftUI pins a pure-SwiftUI column's minimum to its current
    /// width when the inspector opens (measured with a layout dump; even a plain colour does it), so
    /// the panes overflowed and the sidebar was cut off. There the same `showsDetail` drives
    /// `StatisticsWithInspector`'s overlay instead (issue 8d), which never enters the split view.
    private var systemInspectorPresented: Binding<Bool> {
        Binding(
            get: { model.showsDetail && model.sidebarSelection != .statistics },
            set: { if model.sidebarSelection != .statistics { model.showsDetail = $0 } }
        )
    }

    @ViewBuilder
    private var workoutList: some View {
        if model.items.isEmpty && !model.isLoading {
            ContentUnavailableView {
                Label("No Workouts", systemImage: "figure.run")
            } description: {
                Text(settings.isConfigured
                     ? "Import your workouts from Health Auto Export on your iPhone."
                     : "MaxAct reads your workouts from Health Auto Export on your iPhone.")
            } actions: {
                // Always an action. The first version showed "Add your iPhone's address in
                // Settings, then sync" with no button and no route to Settings — a dead end.
                Button(settings.isConfigured ? "Sync Now…" : "Set Up Sync…") {
                    model.isSyncPanelPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.sidebarSelection == .statistics {
            StatisticsWithInspector(model: model)
        } else if model.visibleItems.isEmpty {
            emptyList
                .navigationTitle(model.sidebarSelection?.title ?? "Workouts")
        } else {
            WorkoutTable(model: model)
                .navigationTitle(model.sidebarSelection?.title ?? "Workouts")
                .navigationSubtitle("\(model.visibleItems.count) workouts")
        }
    }

    /// An empty list that says what it means. Every empty filter used to show the system's search
    /// placeholder — "No Results for ''" under Upload Failed, with nothing searched — which reads
    /// as a broken search rather than good news.
    @ViewBuilder
    private var emptyList: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch model.sidebarSelection {
            case .filter(.notOnStrava):
                ContentUnavailableView("Everything's on Strava", systemImage: "checkmark.circle",
                    description: Text("Every workout has been uploaded or found already on Strava."))
            case .filter(.uploadFailed):
                ContentUnavailableView("No Failed Uploads", systemImage: "checkmark.circle",
                    description: Text("An upload that fails is listed here with the reason, ready to retry."))
            case .filter(.withRoute):
                ContentUnavailableView {
                    Label("No Routes Yet", systemImage: "map")
                } description: {
                    Text("Routes arrive with each workout's detail. Download it from the Sync panel.")
                } actions: {
                    Button("Open Sync…") { model.isSyncPanelPresented = true }
                }
            case .filter(.indoor):
                ContentUnavailableView("No Indoor Workouts", systemImage: "house",
                    description: Text("Workouts recorded indoors — on a treadmill or trainer, or strength "
                                      + "training — are listed here."))
            case .tag(let name):
                ContentUnavailableView("Nothing Tagged “\(name)”", systemImage: "tag",
                    description: Text("Tag workouts from the Tags menu or by right-clicking them."))
            default:
                ContentUnavailableView("No Workouts", systemImage: "figure.run",
                    description: Text("Nothing here yet."))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Back and Forward through jumps (issue 32), where a browser and Finder put theirs.
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .help("Back to the workout before the last jump")
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .help("Forward again")
                .disabled(!model.canGoForward)
        }

        ToolbarItemGroup {
            WorkoutActions(model: model, ids: model.selection)
                .labelStyle(.iconOnly)
                .disabled(model.selection.isEmpty)

            Button {
                model.isSyncPanelPresented = true
            } label: {
                // Title *and* icon: a bare, permanently-disabled icon told people nothing about
                // what the app wanted from them.
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .help("Import workouts from Health Auto Export on your iPhone")
            .popover(isPresented: $model.isSyncPanelPresented, arrowEdge: .bottom) {
                SyncPanel(model: model)
            }
        }

        // The inspector's only visible control. Until this existed the pane could be opened by
        // selecting a row but closed only from View ▸ Hide Inspector or ⌃⌘I, so it read as a pane
        // that couldn't be dismissed.
        //
        // A `Toggle` rather than a button, so it carries its own on/off state and can't disagree
        // with the menu item: both drive `model.showsDetail`. Trailing, with `sidebar.trailing`, where
        // Finder and Xcode put theirs. A close button inside the pane would be a fair addition but
        // no substitute — it vanishes with the pane, so it can't bring it back.
        ToolbarItem {
            Toggle(isOn: $model.showsDetail) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(model.showsDetail ? "Hide the workout details" : "Show the workout details")
        }
    }

    /// A failure to read or change the library itself. It used to be recorded and never shown, so
    /// a broken database looked like an empty one (Phase 8).
    @ViewBuilder
    private var loadErrorBanner: some View {
        if let error = model.loadError {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error).font(.callout).lineLimit(3)
                    .accessibilityIdentifier("LoadErrorMessage")
                Spacer()
                Button("Dismiss") { model.dismissLoadError() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// A bottom inset rather than an alert: sync takes minutes and must not block the window, and
    /// a failure needs to stay readable rather than being dismissed by a stray return key.
    @ViewBuilder
    private var syncBanner: some View {
        if let message = model.syncStatus.message {
            HStack(spacing: 10) {
                if model.syncStatus.isRunning {
                    ProgressView().controlSize(.small)
                } else if case .failed = model.syncStatus {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if model.syncStatus.isWarning {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }

                // Three lines: a problem's title plus its advice runs to two at typical widths.
                Text(model.isStopping ? "Stopping…" : message).font(.callout).lineLimit(3)
                    .accessibilityIdentifier("SyncBannerMessage")
                Spacer()

                if model.syncStatus.isRunning {
                    Button("Stop") { model.cancelSync() }
                        .disabled(model.isStopping)
                } else {
                    Button("Dismiss") { model.dismissSyncStatus() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

