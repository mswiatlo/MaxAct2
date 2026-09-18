import SwiftUI

// NOTE: `import MaxActCore` is added once the local package is linked into this target
// (File → Add Package Dependencies… → Add Local → MaxActCore). See PLAN.md, Phase 0.

struct ContentView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Workouts", systemImage: "figure.run")
        } description: {
            Text("Import workouts from Health Auto Export to get started.")
        }
        .navigationTitle("MaxAct")
    }
}

#Preview {
    ContentView()
}
