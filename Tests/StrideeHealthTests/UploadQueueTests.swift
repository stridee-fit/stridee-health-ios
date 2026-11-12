import XCTest
@testable import StrideeHealth

final class UploadQueueTests: XCTestCase {
    private func makeQueue() -> UploadQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return UploadQueue(directory: dir)
    }

    func testOldestFirstAndKindRoundTrip() {
        let queue = makeQueue()
        XCTAssertTrue(queue.enqueue(Data("a".utf8), kind: .workout, key: "A-1"))
        Thread.sleep(forTimeInterval: 0.002)
        XCTAssertTrue(queue.enqueue(Data("b".utf8), kind: .wellness, key: "B-2"))

        let items = queue.items()
        XCTAssertEqual(items.map(\.kind), [.workout, .wellness])
        XCTAssertEqual(queue.body(of: items[0]), Data("a".utf8))
    }

    func testSameWorkoutIsQueuedOnce() {
        let queue = makeQueue()
        XCTAssertTrue(queue.enqueue(Data("x".utf8), kind: .workout, key: "SAME-UUID"))
        XCTAssertFalse(queue.enqueue(Data("x".utf8), kind: .workout, key: "SAME-UUID"))
        XCTAssertEqual(queue.count, 1)
    }

    func testRemove() {
        let queue = makeQueue()
        queue.enqueue(Data("x".utf8), kind: .workout, key: "K")
        queue.remove(queue.items()[0])
        XCTAssertEqual(queue.count, 0)
    }

    func testADisconnectKeepsRecordings() {
        let queue = makeQueue()
        let recording = UUID().uuidString
        queue.enqueue(Data("w".utf8), kind: .workout, key: "W")
        queue.enqueue(Data("h".utf8), kind: .wellness, key: "H")
        queue.enqueue(Data("r".utf8), kind: .recording, key: recording)

        queue.removeAll(except: [.recording])

        XCTAssertEqual(queue.items().map(\.kind), [.recording])
        XCTAssertTrue(queue.items()[0].url.lastPathComponent.hasSuffix("-recording-\(recording).json"))
    }
}
