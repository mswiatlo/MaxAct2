import MaxActCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    private var settings: SyncSettings { model.settings }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
        } content: {
            workoutList
                .navigationSplitViewColumnWidth(min: 560, ideal: 820)
        } detail: {
            DetailPane()
        }
        .searchable(text: $model.searchText, prompt: "Activity, place or app")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { syncBanner }
        .task { await model.load() }
    }

    @ViewBuilder
    private var workoutList: some View {
        if model.items.isEmpty && !model.isLoading {
            ContentUnavailableView {
                Label("No Workouts", systemImage: "figure.run")
            } description: {
                Text(settings.isConfigured
                     ? "Sync to import workouts from Health Auto Export on your iPhone."
                     : "Add your iPhone's address in Settings, then sync.")
            } actions: {
                if settings.isConfigured {
                    Button("Sync Now") { model.startSync() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if model.visibleItems.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            WorkoutTable()
                .navigationTitle(model.sidebarSelection?.title ?? "Workouts")
                .navigationSubtitle("\(model.visibleItems.count) workouts")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            WorkoutActions(ids: model.selection)
                .labelStyle(.iconOnly)
                .disabled(model.selection.isEmpty)

            Button {
                model.syncStatus.isRunning ? model.cancelSync() : model.startSync()
            } label: {
                Label(
                    model.syncStatus.isRunning ? "Stop Syncing" : "Sync",
                    systemImage: model.syncStatus.isRunning
                        ? "stop.circle" : "arrow.triangle.2.circlepath"
                )
            }
            .disabled(!settings.isConfigured && !model.syncStatus.isRunning)
            .help(settings.isConfigured
                  ? "Import workouts from Health Auto Export"
                  : "Set your iPhone's address in Settings first")
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
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }

                Text(message).font(.callout).lineLimit(2)
                Spacer()

                if model.syncStatus.isRunning {
                    Button("Stop") { model.cancelSync() }
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
