import MaxActCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.sidebarSelection) {
            Section("Library") {
                ForEach(WorkoutFilter.allCases) { filter in
                    row(for: .filter(filter), symbol: filter.symbolName)
                }
            }

            if !model.presentKinds.isEmpty {
                Section("Activities") {
                    ForEach(model.presentKinds, id: \.key) { entry in
                        row(for: .kind(entry.key), symbol: entry.kind.symbolName, count: entry.count)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 300)
    }

    /// Counts are shown for every row. They make "Not on Strava: 0" an answer rather than an empty
    /// list you have to interpret.
    private func row(for selection: SidebarSelection, symbol: String, count: Int? = nil) -> some View {
        let total = count ?? model.count(for: selection)
        return Label(selection.title, systemImage: symbol)
            .badge(total)
            .tag(selection)
            .accessibilityLabel("\(selection.title), \(total) workouts")
    }
}
