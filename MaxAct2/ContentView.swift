import SwiftUI
import MaxActCore

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
