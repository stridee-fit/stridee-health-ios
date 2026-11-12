import XCTest
@testable import StrideeHealth

final class WorkoutCoachTests: XCTestCase {
    typealias Section = WorkoutRecorder.Section

    private func laps(_ outputs: [WorkoutCoach.Output]) -> [WorkoutRecorder.Lap] {
        outputs.compactMap { if case .lap(let l) = $0 { return l }; return nil }
    }

    private func cues(_ outputs: [WorkoutCoach.Output]) -> [WorkoutRecorder.PaceCue] {
        outputs.compactMap { if case .pace(let c) = $0 { return c }; return nil }
    }

    func testALapEveryKilometreWithItsPaceAndHeartRate() {
        var coach = WorkoutCoach(lapDistance: 1000, sections: [], overallTargetPace: 300)
        var out: [WorkoutCoach.Output] = []
        // 5:00 /km, 3.33 m/s, a reading a second at 150.
        for t in stride(from: 0.0, through: 610, by: 1) {
            out += coach.update(distance: t * 1000 / 300, movingTime: t, pace: 300, heartRate: 150)
        }
        let done = laps(out)
        XCTAssertEqual(done.map(\.number), [1, 2])
        XCTAssertEqual(done[0].pace, 300, accuracy: 1)
        XCTAssertEqual(done[0].averageHeartRate, 150)
        XCTAssertEqual(done[0].paceVsTarget ?? 99, 0, accuracy: 1)
        XCTAssertEqual(done[1].cumulativeDistance, 2000)
    }

    func testOneJumpAcrossTwoLapsSharesItsTime() {
        var coach = WorkoutCoach(lapDistance: 1000, sections: [], overallTargetPace: nil)
        _ = coach.update(distance: 0, movingTime: 0, pace: 0, heartRate: nil)
        let done = laps(coach.update(distance: 2000, movingTime: 600, pace: 300, heartRate: nil))
        XCTAssertEqual(done.map(\.duration), [300, 300])
    }

    func testSectionsAdvanceOnDistanceAndTimeAndParkOnOpen() {
        let sections = [
            Section(name: "Warm-up", kind: "warmup", goal: .time(seconds: 600)),
            Section(name: "Interval", kind: "interval", goal: .distance(meters: 400), targetPace: 240),
            Section(name: "Cool-down", kind: "cooldown", goal: .open),
        ]
        var coach = WorkoutCoach(lapDistance: 1000, sections: sections, overallTargetPace: nil)
        XCTAssertEqual(coach.update(distance: 0, movingTime: 0, pace: 0, heartRate: nil),
                       [.section(current: sections[0], next: sections[1], finished: nil)])
        XCTAssertEqual(coach.sectionRemaining, .time(seconds: 600))
        _ = coach.update(distance: 900, movingTime: 300, pace: 330, heartRate: nil)
        XCTAssertEqual(coach.sectionRemaining, .time(seconds: 300))

        XCTAssertEqual(coach.update(distance: 1800, movingTime: 600, pace: 330, heartRate: nil).last,
                       .section(current: sections[1], next: sections[2], finished: sections[0]))
        XCTAssertEqual(coach.activeTargetPace, 240)
        _ = coach.update(distance: 2000, movingTime: 650, pace: 240, heartRate: nil)
        XCTAssertEqual(coach.sectionRemaining, .distance(meters: 200))

        XCTAssertEqual(coach.update(distance: 2200, movingTime: 700, pace: 240, heartRate: nil).last,
                       .section(current: sections[2], next: nil, finished: sections[1]))
        _ = coach.update(distance: 9000, movingTime: 5000, pace: 330, heartRate: nil)
        XCTAssertEqual(coach.currentSection, sections[2], "an open step has no end to detect")
        XCTAssertNil(coach.activeTargetPace, "a step without a pace target is not nagged")
    }

    func testBehindIsSaidAfterItLastsWithGrowingGapsThenGoesQuiet() {
        var coach = WorkoutCoach(lapDistance: 100_000, sections: [], overallTargetPace: 300)
        var said: [(Double, WorkoutRecorder.PaceCue)] = []
        // On target through the grace minute, then 30 s/km slow for ten minutes.
        for t in stride(from: 0.0, through: 700, by: 1) {
            let pace: Double = t < 90 ? 300 : 330
            for cue in cues(coach.update(distance: t * 3, movingTime: t, pace: pace, heartRate: nil)) {
                said.append((t, cue))
            }
        }
        XCTAssertEqual(said.map(\.0), [105, 195, 375], "after 15 s, then 90 s, then 180 s")
        XCTAssertEqual(said.map(\.1), Array(repeating: .behind(by: 30), count: 3))

        // Back to pace: welcomed back once.
        let back = cues(coach.update(distance: 2200, movingTime: 701, pace: 300, heartRate: nil))
        XCTAssertEqual(back, [.backOnTarget])
    }

    func testAheadIsSaidOnceAndAWobbleNobodyMentionedGetsNoWelcomeBack() {
        var coach = WorkoutCoach(lapDistance: 100_000, sections: [], overallTargetPace: 300)
        var said: [WorkoutRecorder.PaceCue] = []
        for t in stride(from: 0.0, through: 300, by: 1) {
            let pace: Double = t < 100 ? 300 : (t < 105 ? 340 : (t < 120 ? 300 : 260))
            said += cues(coach.update(distance: t * 3, movingTime: t, pace: pace, heartRate: nil))
        }
        XCTAssertEqual(said, [.ahead(by: 40)])
    }

    func testNoCueInTheFirstMinute() {
        var coach = WorkoutCoach(lapDistance: 100_000, sections: [], overallTargetPace: 300)
        var said: [WorkoutRecorder.PaceCue] = []
        for t in stride(from: 0.0, through: 59, by: 1) {
            said += cues(coach.update(distance: t, movingTime: t, pace: 400, heartRate: nil))
        }
        XCTAssertTrue(said.isEmpty)
    }

    func testHeartRateMeasurementParsing() {
        XCTAssertEqual(HeartRateMonitor.parse(Data([0x00, 142])), 142)
        XCTAssertEqual(HeartRateMonitor.parse(Data([0x01, 0x2C, 0x01])), 300)
        XCTAssertNil(HeartRateMonitor.parse(Data([0x01, 0x2C])))
        XCTAssertNil(HeartRateMonitor.parse(Data([0x00])))
    }
}
