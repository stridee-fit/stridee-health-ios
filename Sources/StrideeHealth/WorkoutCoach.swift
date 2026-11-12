import Foundation

extension WorkoutRecorder {

    /// One step of a structured workout, in the order the athlete runs it.
    /// Repeats are expanded: four intervals with recoveries between them are
    /// eight sections.
    public struct Section: Sendable, Codable, Hashable {
        public enum Goal: Sendable, Codable, Hashable {
            case distance(meters: Double)
            case time(seconds: Double)
            /// No end the recorder can detect. The workout stays on this step.
            case open

            public var meters: Double? { if case .distance(let m) = self { return m }; return nil }
            public var seconds: Double? { if case .time(let s) = self { return s }; return nil }
        }

        /// Your words for the step ("Warm-up", "Interval 3"). The SDK only
        /// carries it back to you.
        public let name: String
        /// What kind of step it is — `warmup`, `interval`, `recovery`,
        /// `cooldown` — for your own styling.
        public let kind: String
        public let goal: Goal
        /// Seconds per kilometre this step targets, when it targets a pace.
        public let targetPace: TimeInterval?

        public init(name: String, kind: String, goal: Goal, targetPace: TimeInterval? = nil) {
            self.name = name
            self.kind = kind
            self.goal = goal
            self.targetPace = targetPace
        }
    }

    /// A completed auto-lap.
    public struct Lap: Sendable, Codable, Hashable, Identifiable {
        /// 1-based.
        public let number: Int
        /// Metres: the lap distance.
        public let distance: Double
        /// Moving seconds the lap took.
        public let duration: TimeInterval
        /// Seconds per kilometre.
        public let pace: TimeInterval
        /// Beats per minute over the lap, when heart rate was coming in.
        public let averageHeartRate: Int?
        /// Seconds per kilometre slower (positive) or faster (negative) than
        /// the target pace in force during the lap; `nil` without one.
        public let paceVsTarget: TimeInterval?

        public var id: Int { number }
        /// Metres from the start to the end of this lap.
        public var cumulativeDistance: Double { Double(number) * distance }
    }

    /// A moment worth telling the athlete about — by voice, haptics, or on
    /// screen. Each fires once, as it happens.
    public enum PaceCue: Sendable, Equatable {
        /// Slower than the target pace by this many seconds per kilometre, for
        /// long enough to mention. Repeats with growing gaps, then goes quiet.
        case behind(by: TimeInterval)
        /// Faster than the target by this much. Said once per stretch.
        case ahead(by: TimeInterval)
        /// Back on target after a cue said otherwise.
        case backOnTarget
    }

    /// What ``WorkoutRecorder/onEvent`` reports.
    public enum Event: Sendable {
        /// A GPS fix was recorded. For a live map, a broadcast, your own log.
        case sample(Sample)
        case lap(Lap)
        /// A structured workout moved on: `finished` is the step just done
        /// (`nil` for the first), `current` the one now running (`nil` once
        /// the last is done).
        case section(current: Section?, next: Section?, finished: Section?)
        case pace(PaceCue)
        /// The athlete stopped and the clock with them; or started again.
        case autoPaused
        case autoResumed
    }

    /// One recorded GPS fix, with the totals as they stood after it.
    public struct Sample: Sendable, Equatable {
        public let date: Date
        public let latitude: Double
        public let longitude: Double
        /// Metres above sea level — barometric when available.
        public let altitude: Double?
        /// Metres per second, when GPS knew it.
        public let speed: Double?
        public let horizontalAccuracy: Double
        /// Metres from the start, at this fix.
        public let distance: Double
        /// Moving seconds from the start, at this fix.
        public let movingTime: TimeInterval
        /// The clock was running: not paused or auto-paused.
        public let isMoving: Bool
    }

    /// A heart-rate reading delivered with the workout.
    public struct HeartRateSample: Sendable, Equatable {
        public let date: Date
        public let beatsPerMinute: Double
    }
}

/// Auto-laps, the structured-workout cursor and pace-drift cues.
///
/// Ported from the Stridee app's live coach, where it ran in production. Fed
/// the recording's totals on every fix and every second, and measured in
/// moving seconds, so a pause pauses every timer here for free. Returns what
/// happened instead of calling anyone, so it can be tested and replayed.
struct WorkoutCoach {
    enum Output: Equatable {
        case lap(WorkoutRecorder.Lap)
        case section(current: WorkoutRecorder.Section?, next: WorkoutRecorder.Section?, finished: WorkoutRecorder.Section?)
        case pace(WorkoutRecorder.PaceCue)
    }

    let lapDistance: Double
    let sections: [WorkoutRecorder.Section]
    let overallTargetPace: TimeInterval?

    private(set) var laps: [WorkoutRecorder.Lap] = []

    private var lastLapDistance: Double = 0
    private var lastLapSeconds: Double = 0
    private var lapHRSum = 0
    private var lapHRCount = 0

    private var sectionIndex = 0
    private var sectionStartDistance: Double = 0
    private var sectionStartSeconds: Double = 0
    private var sectionEnteredSeconds: Double = 0
    private var announcedFirstSection = false

    private var lastDistance: Double = 0
    private var lastSeconds: Double = 0

    private enum DriftState { case onTarget, behind, ahead, silenced }
    private var driftState: DriftState = .onTarget
    private var driftSince: Double?
    private var lastDriftCue: Double?
    private var behindCount = 0
    private var aheadSaid = false
    private var lastCue: Double = -999

    /// Settle in before any pace cue.
    static let runGrace: Double = 60
    /// And into each section.
    static let sectionGrace: Double = 30
    /// Off target this long before saying so.
    static let sustain: Double = 15
    /// Keep a pace cue clear of another cue.
    static let cueGap: Double = 5
    /// Seconds per km slower than target before "behind".
    static let behindTolerance: Double = 12
    /// Seconds per km faster than target before "ahead".
    static let aheadTolerance: Double = 20
    static let behindCooldowns: [Double] = [45, 90, 180]
    static let maxBehindCues = 3

    init(lapDistance: Double, sections: [WorkoutRecorder.Section], overallTargetPace: TimeInterval?) {
        self.lapDistance = max(lapDistance, 100)
        self.sections = sections
        self.overallTargetPace = overallTargetPace
    }

    var currentSection: WorkoutRecorder.Section? {
        sectionIndex < sections.count ? sections[sectionIndex] : nil
    }

    var nextSection: WorkoutRecorder.Section? {
        sectionIndex + 1 < sections.count ? sections[sectionIndex + 1] : nil
    }

    /// The target in force: the current section's own — none on a step that
    /// targets no pace, so a recovery is not nagged toward race pace — or,
    /// without sections, the overall target.
    var activeTargetPace: TimeInterval? {
        if let section = currentSection {
            if let target = section.targetPace, target > 0 { return target }
            return nil
        }
        if let target = overallTargetPace, target > 0 { return target }
        return nil
    }

    /// What is left of the current section.
    var sectionRemaining: WorkoutRecorder.Section.Goal? {
        guard let section = currentSection else { return nil }
        switch section.goal {
        case .distance(let m): return .distance(meters: max(0, m - (lastDistance - sectionStartDistance)))
        case .time(let s): return .time(seconds: max(0, s - (lastSeconds - sectionStartSeconds)))
        case .open: return .open
        }
    }

    /// - Parameters:
    ///   - pace: Seconds per km now; 0 when unknown.
    mutating func update(distance d: Double, movingTime t: Double, pace: Double, heartRate: Int?) -> [Output] {
        lastDistance = d
        lastSeconds = t
        var out: [Output] = []
        laps(distance: d, seconds: t, heartRate: heartRate, into: &out)
        sections(distance: d, seconds: t, into: &out)
        drift(seconds: t, pace: pace, into: &out)
        return out
    }

    // MARK: Laps

    private mutating func laps(distance d: Double, seconds t: Double, heartRate: Int?, into out: inout [Output]) {
        if let heartRate, heartRate > 0 { lapHRSum += heartRate; lapHRCount += 1 }
        while d - lastLapDistance >= lapDistance {
            let segmentDistance = d - lastLapDistance
            let segmentSeconds = t - lastLapSeconds
            // One jump across several boundaries (a GPS dropout) shares its
            // time between the laps it covers.
            let seconds = segmentDistance > 0 ? segmentSeconds * (lapDistance / segmentDistance) : segmentSeconds
            let pace = seconds > 0 ? seconds / (lapDistance / 1000) : 0
            let lap = WorkoutRecorder.Lap(
                number: laps.count + 1,
                distance: lapDistance,
                duration: seconds,
                pace: pace,
                averageHeartRate: lapHRCount > 0 ? Int((Double(lapHRSum) / Double(lapHRCount)).rounded()) : nil,
                paceVsTarget: activeTargetPace.map { pace - $0 }
            )
            laps.append(lap)
            out.append(.lap(lap))
            lastLapDistance += lapDistance
            lastLapSeconds += seconds
            lapHRSum = 0
            lapHRCount = 0
        }
    }

    // MARK: Sections

    private mutating func sections(distance d: Double, seconds t: Double, into out: inout [Output]) {
        guard !sections.isEmpty else { return }
        if !announcedFirstSection {
            announcedFirstSection = true
            sectionEnteredSeconds = t
            out.append(.section(current: currentSection, next: nextSection, finished: nil))
        }
        while let section = currentSection {
            let done: Bool
            switch section.goal {
            case .distance(let m): done = d - sectionStartDistance >= m
            case .time(let s): done = t - sectionStartSeconds >= s
            case .open: done = false
            }
            guard done else { break }
            sectionIndex += 1
            sectionStartDistance = d
            sectionStartSeconds = t
            sectionEnteredSeconds = t
            resetDrift()
            out.append(.section(current: currentSection, next: nextSection, finished: section))
        }
    }

    // MARK: Pace drift

    private mutating func drift(seconds t: Double, pace: Double, into out: inout [Output]) {
        guard let target = activeTargetPace else { resetDrift(); return }
        guard pace.isFinite, pace > 0, t >= Self.runGrace, t - sectionEnteredSeconds >= Self.sectionGrace else { return }

        let delta = pace - target
        let behind = delta > Self.behindTolerance
        let ahead = delta < -Self.aheadTolerance

        switch driftState {
        case .onTarget:
            if behind { enter(.behind, t) } else if ahead { enter(.ahead, t) }
        case .behind:
            if !behind && !ahead { backOnTarget(t, into: &out) }
            else if ahead { enter(.ahead, t) }
            else if let since = driftSince, t - since >= Self.sustain, t - lastCue >= Self.cueGap {
                if behindCount >= Self.maxBehindCues {
                    driftState = .silenced
                } else {
                    let cooldown = Self.behindCooldowns[min(behindCount, Self.behindCooldowns.count - 1)]
                    if lastDriftCue.map({ t - $0 >= cooldown }) ?? true {
                        out.append(.pace(.behind(by: delta)))
                        behindCount += 1
                        lastDriftCue = t
                        lastCue = t
                    }
                }
            }
        case .ahead:
            if !behind && !ahead { backOnTarget(t, into: &out) }
            else if behind { enter(.behind, t) }
            else if !aheadSaid, let since = driftSince, t - since >= Self.sustain, t - lastCue >= Self.cueGap {
                out.append(.pace(.ahead(by: -delta)))
                aheadSaid = true
                lastDriftCue = t
                lastCue = t
            }
        case .silenced:
            if !behind { backOnTarget(t, into: &out) }
        }
    }

    private mutating func enter(_ state: DriftState, _ t: Double) {
        driftState = state
        driftSince = t
        if state == .behind {
            lastDriftCue = nil
            behindCount = 0
        } else {
            aheadSaid = false
        }
    }

    /// Welcomed back only if a cue said they had drifted: a wobble nobody
    /// mentioned gets no "back on target".
    private mutating func backOnTarget(_ t: Double, into out: inout [Output]) {
        let said = lastDriftCue != nil || aheadSaid || driftState == .silenced
        resetDrift()
        if said {
            out.append(.pace(.backOnTarget))
            lastCue = t
        }
    }

    private mutating func resetDrift() {
        driftState = .onTarget
        driftSince = nil
        lastDriftCue = nil
        behindCount = 0
        aheadSaid = false
    }
}
