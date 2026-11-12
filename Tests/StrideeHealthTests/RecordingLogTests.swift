import XCTest
@testable import StrideeHealth

final class RecordingLogTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000.25)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func meta() -> RecordingLog.Meta {
        .init(id: UUID(), activity: .cycling, startedAt: t0, autoPause: true, savesToHealth: true, lapDistance: 1000, sections: [], targetPace: nil, uploadsToStridee: true)
    }

    private func fix(_ seconds: Double) -> Fix {
        Fix(t: t0.addingTimeInterval(seconds), lat: 46.1, lon: 7.2, horizontalAccuracy: 4,
            altitude: 600, verticalAccuracy: 3, speed: 8, course: 90)
    }

    func testNothingOnDiskIsNoRecording() {
        XCTAssertNil(RecordingLog(directory: directory).load())
    }

    func testRoundTripsEverythingWrittenInOrder() {
        let log = RecordingLog(directory: directory)
        let meta = meta()
        log.begin(meta)
        log.append(.fix(fix(0), added: 0, distance: 0, elevationGain: 0))
        log.append(.heartRate(.init(t: t0.addingTimeInterval(0.5), bpm: 140)))
        log.append(.fix(fix(1), added: 8, distance: 8, elevationGain: 1))
        log.append(.event(.init(t: t0.addingTimeInterval(2), kind: .pause)))
        log.flush()

        // A fresh instance, as after a relaunch.
        let contents = RecordingLog(directory: directory).load()
        XCTAssertEqual(contents?.meta, meta)
        XCTAssertEqual(contents?.fixes, [fix(0), fix(1)])
        XCTAssertEqual(contents?.added, [0, 8])
        XCTAssertEqual(contents?.distance, 8)
        XCTAssertEqual(contents?.elevationGain, 1)
        XCTAssertEqual(contents?.heartRate.map(\.bpm), [140])
        XCTAssertEqual(contents?.events.map(\.kind), [.pause])
        XCTAssertTrue(contents?.endsPaused == true)
    }

    func testKeepsSubSecondTimestamps() {
        let log = RecordingLog(directory: directory)
        log.begin(meta())
        log.append(.fix(fix(0.3), added: 0, distance: 0, elevationGain: 0))
        XCTAssertEqual(log.load()?.fixes.first?.t.timeIntervalSince1970 ?? 0, t0.timeIntervalSince1970 + 0.3, accuracy: 0.0001)
    }

    func testAHalfWrittenLastLineDoesNotLoseTheRun() throws {
        let log = RecordingLog(directory: directory)
        log.begin(meta())
        log.append(.fix(fix(0), added: 0, distance: 0, elevationGain: 0))
        log.append(.fix(fix(1), added: 8, distance: 8, elevationGain: 0))
        log.flush()

        // The app died mid-write.
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("log.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"k":"fix","fix":{"t":17900"#.utf8))
        try handle.close()

        let contents = RecordingLog(directory: directory).load()
        XCTAssertEqual(contents?.fixes.count, 2)
        XCTAssertEqual(contents?.distance, 8)
    }

    func testBeginReplacesTheLastRecordingAndClearForgetsIt() {
        let log = RecordingLog(directory: directory)
        log.begin(meta())
        log.append(.fix(fix(0), added: 0, distance: 0, elevationGain: 0))
        let second = meta()
        log.begin(second)
        XCTAssertEqual(log.load()?.meta, second)
        XCTAssertEqual(log.load()?.fixes, [])

        log.clear()
        XCTAssertNil(log.load())
    }

    func testMovingTimeLeavesOutEveryPause() {
        var contents = RecordingLog.Contents(meta: meta())
        contents.events = [
            .init(t: t0.addingTimeInterval(100), kind: .motionPaused),
            .init(t: t0.addingTimeInterval(130), kind: .motionResumed),
            .init(t: t0.addingTimeInterval(200), kind: .pause),
            .init(t: t0.addingTimeInterval(500), kind: .resume),
        ]
        // 100 + 70 + 100
        XCTAssertEqual(contents.movingTime(until: t0.addingTimeInterval(600)), 270, accuracy: 0.001)
        XCTAssertFalse(contents.endsPaused)
    }

    func testAManualPauseDuringAnAutoPauseStopsTheClockOnce() {
        var contents = RecordingLog.Contents(meta: meta())
        contents.events = [
            .init(t: t0.addingTimeInterval(100), kind: .motionPaused),
            .init(t: t0.addingTimeInterval(110), kind: .pause),
            .init(t: t0.addingTimeInterval(200), kind: .motionResumed),
        ]
        XCTAssertEqual(contents.movingTime(until: t0.addingTimeInterval(300)), 200, accuracy: 0.001)
    }
}
