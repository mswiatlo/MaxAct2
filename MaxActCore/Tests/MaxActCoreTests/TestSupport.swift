import Foundation

@testable import MaxActCore

/// A fresh, empty store in memory: nothing on disk, nothing shared between tests.
func inMemoryStore() throws -> WorkoutStore {
    WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
}
