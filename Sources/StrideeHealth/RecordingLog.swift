import Foundation

/// The recording in progress, on disk, written as it happens.
///
/// A run is not something that can be recorded twice, so nothing about it
/// lives only in memory: every accepted fix, pause and heart-rate reading is
/// appended to `log.jsonl` the moment it arrives, and the recording's identity
/// to `meta.json` when it starts. A crash, a force-quit or iOS killing the app
/// in the background loses at most the line being written; the next launch
/// replays the log and the athlete carries on, or finishes.
///
/// Readable while the phone is locked — which it is for most of a run — and
/// so protected until first unlock rather than completely.
final class RecordingLog: @unchecked Sendable {
    struct Meta: Codable, Equatable {
        let id: UUID
        let activity: WorkoutRecorder.Activity
        let startedAt: Date
        let autoPause: Bool
        let savesToHealth: Bool
        let lapDistance: Double
        let sections: [WorkoutRecorder.Section]
        let targetPace: TimeInterval?
        let uploadsToStridee: Bool
    }

    /// A pause or resume, as the FIT file's timer events and HealthKit's
    /// workout events both describe it.
    struct Event: Codable, Equatable {
        enum Kind: String, Codable {
            case pause, resume
            /// Auto-pause: the athlete stopped, nobody pressed anything.
            case motionPaused, motionResumed
        }
        let t: Date
        let kind: Kind
    }

    struct HeartRate: Codable, Equatable {
        let t: Date
        let bpm: Double
    }

    /// One line of the log.
    enum Entry: Codable, Equatable {
        /// A fix kept for the route, with the totals as they stood after it.
        case fix(Fix, added: Double, distance: Double, elevationGain: Double)
        case event(Event)
        case heartRate(HeartRate)

        private enum CodingKeys: String, CodingKey { case k, fix, added, distance, gain, event, hr }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .k) {
            case "fix":
                self = .fix(
                    try c.decode(Fix.self, forKey: .fix),
                    added: try c.decode(Double.self, forKey: .added),
                    distance: try c.decode(Double.self, forKey: .distance),
                    elevationGain: try c.decode(Double.self, forKey: .gain)
                )
            case "event": self = .event(try c.decode(Event.self, forKey: .event))
            case "hr": self = .heartRate(try c.decode(HeartRate.self, forKey: .hr))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .k, in: c, debugDescription: "unknown entry \(other)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .fix(fix, added, distance, gain):
                try c.encode("fix", forKey: .k)
                try c.encode(fix, forKey: .fix)
                try c.encode(added, forKey: .added)
                try c.encode(distance, forKey: .distance)
                try c.encode(gain, forKey: .gain)
            case let .event(event):
                try c.encode("event", forKey: .k)
                try c.encode(event, forKey: .event)
            case let .heartRate(hr):
                try c.encode("hr", forKey: .k)
                try c.encode(hr, forKey: .hr)
            }
        }
    }

    /// Everything on disk about one recording.
    struct Contents: Equatable {
        let meta: Meta
        var fixes: [Fix] = []
        /// Metres each fix added, alongside ``fixes``.
        var added: [Double] = []
        /// The distance after each fix, alongside ``fixes``.
        var distances: [Double] = []
        var events: [Event] = []
        var heartRate: [HeartRate] = []
        var distance: Double = 0
        var elevationGain: Double = 0
    }

    let directory: URL
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }
    private var logURL: URL { directory.appendingPathComponent("log.jsonl") }

    private let io = DispatchQueue(label: "fit.stridee.health.recording", qos: .utility)
    private var handle: FileHandle?

    // Seconds since 1970, fractional: ISO-8601's whole seconds would collapse
    // fixes a second apart.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrideeHealth", isDirectory: true)
            .appendingPathComponent("Recording", isDirectory: true)
    }

    /// Start a new recording, replacing whatever was there.
    func begin(_ meta: Meta) {
        let data = try? Self.encoder.encode(meta)
        io.sync {
            try? handle?.close()
            handle = nil
            let fm = FileManager.default
            try? fm.removeItem(at: directory)
            try? fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try? data?.write(to: metaURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            fm.createFile(
                atPath: logURL.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
    }

    /// Append one entry. Encoded here, written on the log's own queue, in order.
    func append(_ entry: Entry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        io.async { [self] in
            if handle == nil {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: logURL)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: line)
        }
    }

    /// Wait for every append so far to reach the file.
    func flush() {
        io.sync { try? handle?.synchronize() }
    }

    /// The recording on disk, if there is one.
    ///
    /// A line that does not decode — the one being written when the app died —
    /// is skipped, not fatal: everything before it is still the run.
    func load() -> Contents? {
        flush()
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? Self.decoder.decode(Meta.self, from: metaData)
        else { return nil }

        var contents = Contents(meta: meta)
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? Self.decoder.decode(Entry.self, from: Data(line)) else { continue }
            switch entry {
            case let .fix(fix, added, distance, gain):
                contents.fixes.append(fix)
                contents.added.append(added)
                contents.distances.append(distance)
                contents.distance = distance
                contents.elevationGain = gain
            case let .event(event):
                contents.events.append(event)
            case let .heartRate(hr):
                contents.heartRate.append(hr)
            }
        }
        return contents
    }

    /// Forget the recording: it was saved, or thrown away.
    func clear() {
        io.sync {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

extension RecordingLog.Contents {
    /// Seconds spent moving between `startedAt` and `end`: everything except
    /// the stretches between a pause (either kind) and the next resume.
    func movingTime(until end: Date) -> TimeInterval {
        var total: TimeInterval = 0
        var since: Date? = meta.startedAt
        for event in events.sorted(by: { $0.t < $1.t }) {
            switch event.kind {
            case .pause, .motionPaused:
                if let s = since { total += max(0, event.t.timeIntervalSince(s)) }
                since = nil
            case .resume, .motionResumed:
                if since == nil { since = event.t }
            }
        }
        if let s = since { total += max(0, end.timeIntervalSince(s)) }
        return total
    }

    /// Every fix with the totals at it, for ``FinishedWorkout/route``.
    var samples: [WorkoutRecorder.Sample] {
        let sorted = events.sorted { $0.t < $1.t }
        return zip(fixes, distances).map { fix, distance in
            let last = sorted.last { $0.t <= fix.t }
            let moving = last.map { $0.kind == .resume || $0.kind == .motionResumed } ?? true
            return WorkoutRecorder.Sample(
                date: fix.t, latitude: fix.lat, longitude: fix.lon, altitude: fix.altitude, speed: fix.speed,
                horizontalAccuracy: fix.horizontalAccuracy, distance: distance,
                movingTime: movingTime(until: fix.t), isMoving: moving
            )
        }
    }

    /// Whether the last pause, of either kind, has not been resumed.
    var endsPaused: Bool {
        guard let last = events.last else { return false }
        return last.kind == .pause || last.kind == .motionPaused
    }
}
