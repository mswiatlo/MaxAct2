import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Phase 8: what the sync banner says when a list sync finishes.
@Suite struct SyncStatusTests {
    typealias Status = AppModel.SyncStatus

    @Test("a sync that returns nothing warns and points at Health's sharing settings")
    func nothingReturned() {
        let status = Status.listed(found: 0, unreadable: 0)
        #expect(status.isWarning)
        #expect(status.message == SyncProblem.nothingReturned.message)
    }

    @Test("unreadable workouts are reported, not dropped")
    func unreadable() {
        let some = Status.listed(found: 12, unreadable: 2)
        #expect(some.isWarning)
        #expect(some.message?.contains("2 couldn't be read") == true)

        let all = Status.listed(found: 0, unreadable: 3)
        #expect(all.isWarning)
        #expect(all.message?.contains("None of the 3") == true)
    }

    @Test("a clean sync is a plain success")
    func clean() {
        let status = Status.listed(found: 12, unreadable: 0)
        #expect(!status.isWarning)
        #expect(status.message == "Synced 12 workouts")
        #expect(!status.isRunning)
    }
}
