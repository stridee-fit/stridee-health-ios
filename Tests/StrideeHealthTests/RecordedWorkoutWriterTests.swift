import XCTest
@testable import StrideeHealth

final class RecordedWorkoutWriterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func fix(_ seconds: Double) -> Fix {
        Fix(t: t0.addingTimeInterval(seconds), lat: 46 + seconds * 0.00003, lon: 7, horizontalAccuracy: 4,
            altitude: 500, verticalAccuracy: 3, speed: 3.3, course: 0)
    }

    private func contents(activity: WorkoutRecorder.Activity = .running) -> RecordingLog.Contents {
        var c = RecordingLog.Contents(meta: .init(id: UUID(), activity: activity, startedAt: t0, autoPause: true, savesToHealth: true, lapDistance: 1000, sections: [], targetPace: nil, uploadsToStridee: true))
        for i in 0...200 {
            c.fixes.append(fix(Double(i)))
            c.added.append(i == 0 ? 0 : 3.3)
        }
        c.distance = 660
        c.elevationGain = 12
        c.events = [.init(t: t0.addingTimeInterval(100), kind: .motionPaused), .init(t: t0.addingTimeInterval(110), kind: .motionResumed)]
        c.heartRate = [.init(t: t0.addingTimeInterval(1), bpm: 150)]
        return c
    }

    private func decode(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testPayloadIsTheHealthKitFormatTheAPIReads() throws {
        let uuid = UUID()
        let json = try decode(RecordedWorkoutWriter.payload(
            for: contents(activity: .cycling), uuid: uuid, end: t0.addingTimeInterval(200),
            sourceName: "Rocket", sourceBundleId: "com.example.rocket"
        ))
        XCTAssertEqual(json["format"] as? String, "healthkit.v1")
        XCTAssertEqual(json["uuid"] as? String, uuid.uuidString)
        XCTAssertEqual(json["serverType"] as? String, "CYCLING")
        XCTAssertEqual(json["activityType"] as? Int, 13)   // HKWorkoutActivityType.cycling
        XCTAssertEqual(json["sourceBundleId"] as? String, "com.example.rocket")
        XCTAssertEqual(json["totalDistanceMeters"] as? Double, 660)
        // 200 s, less the 10 s auto-pause.
        XCTAssertEqual(json["duration"] as? Double ?? 0, 190, accuracy: 0.001)
        XCTAssertEqual((json["route"] as? [Any])?.count, 201)
        XCTAssertEqual((json["heartRate"] as? [Any])?.count, 1)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["type"] as? String }, ["motionPaused", "motionResumed"])
    }

    func testRouteTimestampsKeepMilliseconds() throws {
        var c = contents()
        c.fixes = [Fix(t: t0.addingTimeInterval(0.25), lat: 46, lon: 7, horizontalAccuracy: 4, altitude: nil, verticalAccuracy: nil, speed: nil, course: nil)]
        c.added = [0]
        let json = try decode(RecordedWorkoutWriter.payload(for: c, uuid: UUID(), end: t0.addingTimeInterval(1), sourceName: "", sourceBundleId: ""))
        let point = try XCTUnwrap((json["route"] as? [[String: Any]])?.first)
        XCTAssertEqual(point["t"] as? String, "2026-09-21T14:13:20.250Z")
        // Unknown values are left out, not sent as zeros.
        XCTAssertNil(point["speed"])
        XCTAssertNil(point["altitude"])
    }

    func testDistanceIsBucketedByTheMinuteAndNeverAcrossAStop() {
        var c = contents()
        // Fix 120 added nothing: a stop splits the buckets there.
        c.added[120] = 0
        let buckets = RecordedWorkoutWriter.distanceBuckets(c)
        XCTAssertEqual(buckets.map(\.start), [0, 60, 120, 180].map { t0.addingTimeInterval($0) })
        XCTAssertEqual(buckets.last?.end, t0.addingTimeInterval(200))
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.metres }, 3.3 * 199, accuracy: 0.001)
        for (a, b) in zip(buckets, buckets.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "samples must not overlap")
        }
    }
}
