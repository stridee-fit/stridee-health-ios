import XCTest
@testable import StrideeHealth

final class RouteTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    /// About 11.1 m of latitude.
    private let step = 0.0001

    private func fix(_ seconds: Double, north: Double, speed: Double? = 3, accuracy: Double = 5, altitude: Double? = nil) -> Fix {
        Fix(t: t0.addingTimeInterval(seconds), lat: 46 + north * step, lon: 7, horizontalAccuracy: accuracy,
            altitude: altitude, verticalAccuracy: altitude == nil ? nil : 3, speed: speed, course: nil)
    }

    private func running(autoPause: Bool = true) -> RouteTracker {
        RouteTracker(tuning: .for(.running, barometric: false), autoPause: autoPause)
    }

    func testAddsUpDistanceAlongTheRoute() {
        var tracker = running()
        for i in 0...10 { _ = tracker.ingest(fix(Double(i) * 4, north: Double(i))) }
        XCTAssertEqual(tracker.distance, 111.2, accuracy: 0.5)
    }

    func testDropsInaccurateFixes() {
        var tracker = running()
        XCTAssertTrue(tracker.ingest(fix(0, north: 0)).accepted)
        XCTAssertFalse(tracker.ingest(fix(4, north: 1, accuracy: 120)).accepted)
        XCTAssertFalse(tracker.ingest(fix(5, north: 1, accuracy: -1)).accepted)
        XCTAssertEqual(tracker.distance, 0)
    }

    func testIgnoresAGPSResetJump() {
        var tracker = running()
        _ = tracker.ingest(fix(0, north: 0))
        // 1.1 km in one second.
        let jump = tracker.ingest(fix(1, north: 100))
        XCTAssertEqual(jump.addedDistance, 0)
        // And measures on from where the fix now is.
        _ = tracker.ingest(fix(5, north: 101))
        XCTAssertEqual(tracker.distance, 11.1, accuracy: 0.2)
    }

    func testAPhoneStandingStillAddsNothing() {
        var tracker = running(autoPause: false)
        _ = tracker.ingest(fix(0, north: 0, speed: 0))
        for i in 1...60 {
            // Jitter of a couple of metres either way.
            _ = tracker.ingest(fix(Double(i), north: i.isMultiple(of: 2) ? 0.2 : -0.2, speed: 0.1))
        }
        XCTAssertEqual(tracker.distance, 0)
    }

    func testASlowWalkStillAddsUp() {
        var tracker = running(autoPause: false)
        // 0.2 m/s reported, but 11 m covered every 50 s: counted once it
        // clears the jitter distance.
        for i in 0...4 { _ = tracker.ingest(fix(Double(i) * 50, north: Double(i), speed: 0.2)) }
        XCTAssertEqual(tracker.distance, 44.5, accuracy: 0.5)
    }

    func testAutoPausesAfterASustainedStopAndResumesOnMovement() {
        var tracker = running()
        _ = tracker.ingest(fix(0, north: 0))
        _ = tracker.ingest(fix(4, north: 1))
        _ = tracker.ingest(fix(5, north: 1, speed: 0.1))
        XCTAssertNil(tracker.tick(now: t0.addingTimeInterval(10)), "not long enough yet")
        XCTAssertEqual(tracker.tick(now: t0.addingTimeInterval(14)), .stopped(since: t0.addingTimeInterval(5)))
        XCTAssertTrue(tracker.isAutoPaused)

        // Drifting while stopped is not distance.
        let before = tracker.distance
        _ = tracker.ingest(fix(20, north: 1.5, speed: 0.4))
        XCTAssertEqual(tracker.distance, before)

        let moving = tracker.ingest(fix(25, north: 2.5, speed: 3))
        XCTAssertEqual(moving.motion, .moving)
        XCTAssertFalse(tracker.isAutoPaused)
        // The step that resumed is measured from where they stopped.
        _ = tracker.ingest(fix(29, north: 3.5, speed: 3))
        XCTAssertEqual(tracker.distance, before + 11.1 * 2, accuracy: 0.5)
    }

    func testOneSlowReadingDoesNotPause() {
        var tracker = running()
        _ = tracker.ingest(fix(0, north: 0))
        _ = tracker.ingest(fix(1, north: 0.3, speed: 0.2))
        _ = tracker.ingest(fix(2, north: 0.6, speed: 3))
        XCTAssertNil(tracker.tick(now: t0.addingTimeInterval(30)))
    }

    func testAutoPauseOffNeverPauses() {
        var tracker = running(autoPause: false)
        _ = tracker.ingest(fix(0, north: 0, speed: 0))
        _ = tracker.ingest(fix(1, north: 0, speed: 0))
        XCTAssertNil(tracker.tick(now: t0.addingTimeInterval(120)))
    }

    func testAManualPauseCountsNothingAndStartsFreshAfter() {
        var tracker = running()
        _ = tracker.ingest(fix(0, north: 0))
        _ = tracker.ingest(fix(4, north: 1))
        tracker.pause()
        XCTAssertEqual(tracker.ingest(fix(60, north: 20), manuallyPaused: true).addedDistance, 0)
        tracker.resume()
        // The first fix after resuming is a starting point, not a 200 m step.
        XCTAssertEqual(tracker.ingest(fix(300, north: 30)).addedDistance, 0)
        _ = tracker.ingest(fix(304, north: 31))
        XCTAssertEqual(tracker.distance, 22.2, accuracy: 0.5)
    }

    func testElevationGainIgnoresNoise() {
        var tracker = running(autoPause: false)
        // ±2 m of GPS noise on flat ground, then a real 20 m climb.
        let altitudes: [Double] = [500, 502, 499, 501, 498, 500, 505, 510, 515, 520]
        for (i, alt) in altitudes.enumerated() {
            _ = tracker.ingest(fix(Double(i) * 4, north: Double(i), altitude: alt))
        }
        XCTAssertEqual(tracker.elevationGain, 20, accuracy: 0.01)
    }

    func testBarometricElevationCountsSmallerClimbs() {
        var tracker = running(autoPause: false)
        tracker.useBarometricElevation()
        for (i, alt) in [100.0, 101.5, 103, 104.5].enumerated() {
            _ = tracker.ingest(fix(Double(i) * 4, north: Double(i), altitude: alt))
        }
        XCTAssertEqual(tracker.elevationGain, 4.5, accuracy: 0.01)
    }

    func testCurrentSpeedFollowsTheLastHalfMinute() {
        var tracker = running(autoPause: false)
        for i in 0...10 { _ = tracker.ingest(fix(Double(i) * 4, north: Double(i))) }
        // 11.1 m every 4 s.
        XCTAssertEqual(tracker.currentSpeed, 2.78, accuracy: 0.05)
    }

    func testPaceIsUnknownWhenStandingStill() {
        var metrics = WorkoutRecorder.Metrics()
        XCTAssertNil(metrics.currentPace)
        metrics.currentSpeed = 1000.0 / 300   // 5:00 /km
        XCTAssertEqual(metrics.currentPace ?? 0, 300, accuracy: 0.001)
    }

    func testCyclingTakesLongerToCallAStopAMoveThanRunning() {
        let bike = RouteTracker.Tuning.for(.cycling, barometric: false)
        let hike = RouteTracker.Tuning.for(.hiking, barometric: false)
        XCTAssertGreaterThan(bike.pauseBelow, hike.pauseBelow)
        XCTAssertGreaterThan(bike.maxSpeed, hike.maxSpeed)
    }
}
