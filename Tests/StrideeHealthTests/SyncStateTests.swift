import XCTest
@testable import StrideeHealth

final class SyncStateTests: XCTestCase {
    private func makeState() -> SyncState {
        let suite = "SyncStateTests.\(UUID().uuidString)"
        return SyncState(defaults: UserDefaults(suiteName: suite)!)
    }

    func testLastDataFoundRoundTripsPerType() {
        let state = makeState()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        state.lastDataFound = [.workouts: date]

        XCTAssertEqual(state.lastDataFound[.workouts], date)
        XCTAssertNil(state.lastDataFound[.wellness])
    }

    func testResetForgetsEverythingAboutTheConnection() {
        let state = makeState()
        state.isConnected = true
        state.lastSyncDate = Date()
        state.lastDataFound = [.wellness: Date()]

        state.reset()

        XCTAssertFalse(state.isConnected)
        XCTAssertNil(state.lastSyncDate)
        XCTAssertTrue(state.lastDataFound.isEmpty)
    }
}
