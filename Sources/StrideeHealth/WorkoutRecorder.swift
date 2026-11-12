import Foundation
import CoreLocation
import CoreMotion
import HealthKit
import os

/// GPS workout recording on the iPhone — runs, rides, walks and hikes —
/// delivered to Apple Health and to Stridee when it finishes.
///
/// ```swift
/// let recorder = WorkoutRecorder.shared
///
/// // Once, before the first workout: location, then Apple Health.
/// await recorder.requestAuthorization()
///
/// try recorder.start(.running)
/// recorder.pause()
/// recorder.resume()
/// let workout = try await recorder.finish()
/// ```
///
/// Observe it for a live screen: ``state``, ``metrics`` (distance, moving
/// time, speed and pace, elevation gain), ``route`` to draw, and
/// ``gpsAccuracy`` for a "waiting for GPS" indicator.
///
/// When it finishes, the workout is saved to Apple Health with its route, and
/// queued for upload to Stridee through ``HealthSync`` — the same
/// `activity.created` and FIT file your backend gets for an Apple Watch
/// workout, with nothing to build on your side. If the athlete has not let
/// your app write to Apple Health, it is uploaded all the same.
///
/// Nothing is lost to a crash. Every fix is on disk the moment it arrives, and
/// a recording the app was killed in the middle of is restored, paused, the
/// next time ``shared`` is first used — ``wasRecovered`` says so. Touch it at
/// launch to restore it before the athlete sees your home screen.
///
/// Your app needs, in `Info.plist`:
/// - `NSLocationWhenInUseUsageDescription` (required)
/// - `UIBackgroundModes` with `location`, so recording carries on with the
///   screen locked — the reason to record on a phone at all
/// - `NSHealthUpdateUsageDescription`, to save to Apple Health
/// - `NSMotionUsageDescription`, optional, for barometric elevation —
///   GPS altitude is used without it
@MainActor
public final class WorkoutRecorder: NSObject, ObservableObject {
    public static let shared = WorkoutRecorder()

    // MARK: - Public types

    /// What is being recorded. Decides the Apple Health workout type, the
    /// Stridee sport, and how quickly a stop counts as one.
    public enum Activity: String, Sendable, Codable, CaseIterable {
        case running
        case cycling
        case walking
        case hiking

        /// Auto-lap distance unless ``Options/lapDistance`` says otherwise:
        /// every kilometre on foot, every 5 km on a bike.
        public var defaultLapDistance: Double { self == .cycling ? 5000 : 1000 }

        var healthKitType: HKWorkoutActivityType {
            switch self {
            case .running: return .running
            case .cycling: return .cycling
            case .walking: return .walking
            case .hiking: return .hiking
            }
        }
    }

    public struct Options: Sendable, Equatable {
        /// Stop the clock when the athlete stops moving, and start it again
        /// when they go. On by default.
        public var autoPause: Bool
        /// Save the workout to Apple Health. On by default; it needs
        /// `NSHealthUpdateUsageDescription` and the athlete's permission, and
        /// without either the workout still reaches Stridee.
        public var savesToHealth: Bool
        /// Metres per auto-lap. `nil` is the activity's
        /// ``Activity/defaultLapDistance``.
        public var lapDistance: Double?
        /// A structured workout to follow: ``WorkoutRecorder/currentSection``
        /// moves through these as their distance or time is done.
        public var sections: [Section]
        /// Seconds per kilometre to hold, for pace cues on a run without
        /// sections. A section's own target wins over it.
        public var targetPace: TimeInterval?
        /// Upload the workout to Stridee when it finishes. On by default.
        ///
        /// Off only when your app sends recordings to your backend some other
        /// way — ``FinishedWorkout`` carries the route and heart rate for it.
        /// The Apple Health copy is then marked so ``HealthSync`` never sends
        /// it either, and the workout cannot arrive twice.
        public var uploadsToStridee: Bool

        public init(
            autoPause: Bool = true,
            savesToHealth: Bool = true,
            lapDistance: Double? = nil,
            sections: [Section] = [],
            targetPace: TimeInterval? = nil,
            uploadsToStridee: Bool = true
        ) {
            self.autoPause = autoPause
            self.savesToHealth = savesToHealth
            self.lapDistance = lapDistance
            self.sections = sections
            self.targetPace = targetPace
            self.uploadsToStridee = uploadsToStridee
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case recording
        /// Paused by ``pause()``. GPS is off to save battery.
        case paused
        /// The athlete stopped moving. GPS stays on to notice them start again.
        case autoPaused

        public var isActive: Bool { self != .idle }
    }

    /// The numbers for a live screen. Updated with every fix and once a second.
    public struct Metrics: Sendable, Equatable {
        /// Metres.
        public internal(set) var distance: Double = 0
        /// Seconds the clock has run: elapsed time less every pause.
        public internal(set) var movingTime: TimeInterval = 0
        /// Seconds since ``WorkoutRecorder/start(_:options:)``.
        public internal(set) var elapsedTime: TimeInterval = 0
        /// Metres per second over the last half minute. 0 when stopped or unknown.
        public internal(set) var currentSpeed: Double = 0
        /// Metres per second over the moving time. 0 for the first 50 m,
        /// where it would be a division by GPS noise.
        public internal(set) var averageSpeed: Double = 0
        /// Metres climbed.
        public internal(set) var elevationGain: Double = 0

        /// Seconds per kilometre now, or `nil` when standing still.
        public var currentPace: TimeInterval? { Self.pace(currentSpeed) }
        /// Seconds per kilometre over the moving time, or `nil` before 50 m.
        public var averagePace: TimeInterval? { Self.pace(averageSpeed) }

        static func pace(_ speed: Double) -> TimeInterval? {
            // Slower than an hour a kilometre is standing still, not a pace.
            speed > 1000.0 / 3600 ? 1000 / speed : nil
        }
    }

    // MARK: - Published state

    @Published public private(set) var state: State = .idle
    @Published public private(set) var activity: Activity?
    @Published public private(set) var metrics = Metrics()
    /// The route so far, thinned to a point every few metres — for a map.
    @Published public private(set) var route: [CLLocationCoordinate2D] = []
    /// The last accepted fix.
    @Published public private(set) var lastLocation: CLLocation?
    /// Horizontal accuracy of the latest fix in metres, or `nil` with no lock.
    /// Live during ``warmUpGPS()`` too, for a start screen that waits for GPS.
    @Published public private(set) var gpsAccuracy: Double?
    @Published public private(set) var locationAuthorization: CLAuthorizationStatus
    /// This recording was restored after the app was killed. It lands paused:
    /// ``resume()`` carries on, ``finish()`` saves it as it is.
    @Published public private(set) var wasRecovered = false
    /// When recording started, while one is.
    @Published public private(set) var startedAt: Date?
    /// Auto-laps completed so far.
    @Published public private(set) var laps: [Lap] = []
    /// The structured-workout step running now, and the one after it. `nil`
    /// without ``Options/sections``.
    @Published public private(set) var currentSection: Section?
    @Published public private(set) var nextSection: Section?
    /// What is left of ``currentSection``, counting down.
    @Published public private(set) var sectionRemaining: Section.Goal?
    /// The latest heart rate, from ``HeartRateMonitor`` or ``addHeartRate(_:at:)``.
    @Published public private(set) var heartRate: Int?

    /// Laps, section changes, pace cues, auto-pauses and every GPS sample, as
    /// they happen — what a voice coach, haptics or a live broadcast hangs off.
    /// Called on the main actor.
    public var onEvent: ((Event) -> Void)?

    // MARK: - Internals

    private let manager = CLLocationManager()
    private let store = HKHealthStore()
    private let altimeter = CMAltimeter()
    private let log: RecordingLog
    private let logger = Logger(subsystem: "fit.stridee.health", category: "recorder")

    private var meta: RecordingLog.Meta?
    private var tracker: RouteTracker?
    private var coach: WorkoutCoach?
    private var options = Options()
    private var isWarmingUp = false
    private var ticker: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    /// Moving time banked before the current stretch, and when the current
    /// stretch began. `movingSince == nil` while paused.
    private var movingBanked: TimeInterval = 0
    private var movingSince: Date?
    /// How the clock was stopped, so the resume that starts it matches.
    private var stoppedBy: RecordingLog.Event.Kind?

    /// Barometric altitude, relative to where updates began, and the offset
    /// that turns it into metres above sea level — taken from the first GPS
    /// altitude worth trusting, so the elevation is real and every change in
    /// it comes from the barometer.
    private var relativeAltitude: Double?
    private var altitudeOffset: Double?
    private var altimeterRunning = false

    init(log: RecordingLog = RecordingLog()) {
        self.log = log
        self.locationAuthorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        // Every fix, about one a second: a full-resolution route, and a phone
        // standing still keeps reporting so auto-pause can see it.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        restore()
    }

    // MARK: - Permissions

    /// Ask for location while in use, then for Apple Health write access to
    /// workouts, routes, distance and heart rate. Each sheet appears once,
    /// ever; calling this again returns at once.
    ///
    /// Returns where location stands. Recording needs it; Apple Health is
    /// optional.
    @discardableResult
    public func requestAuthorization() async -> CLAuthorizationStatus {
        let location = await requestLocationAuthorization()
        if HKHealthStore.isHealthDataAvailable(),
           Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") != nil {
            do {
                try await store.requestAuthorization(toShare: RecordedWorkoutWriter.shareTypes, read: [])
            } catch {
                logger.error("Apple Health authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return location
    }

    /// Ask for location while in use. "While in use" is all recording needs:
    /// with the `location` background mode, a recording started in the
    /// foreground carries on with the screen locked.
    @discardableResult
    public func requestLocationAuthorization() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined, Self.hasInfoKey("NSLocationWhenInUseUsageDescription") else {
            return manager.authorizationStatus
        }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - GPS warm-up

    /// Start GPS on a start screen, before recording, so ``gpsAccuracy`` can
    /// show the lock tightening. Starting a recording takes over from it.
    public func warmUpGPS() {
        guard state == .idle, isAuthorized, !isWarmingUp else { return }
        isWarmingUp = true
        manager.startUpdatingLocation()
    }

    /// Stop the warm-up, when the start screen goes away without recording.
    public func coolDownGPS() {
        guard isWarmingUp else { return }
        isWarmingUp = false
        guard state == .idle else { return }
        manager.stopUpdatingLocation()
        gpsAccuracy = nil
    }

    // MARK: - Recording

    /// Start recording.
    ///
    /// Recording is entirely on the phone and needs no network: a run with no
    /// signal records the same and uploads later. If location has never been
    /// asked about, the sheet appears and recording begins with the first fix
    /// after the athlete allows it.
    public func start(_ activity: Activity, options: Options = Options()) throws {
        guard state == .idle else { throw WorkoutRecorderError.alreadyRecording }
        guard Self.hasInfoKey("NSLocationWhenInUseUsageDescription") else {
            throw WorkoutRecorderError.missingInfoPlistKey("NSLocationWhenInUseUsageDescription")
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: throw WorkoutRecorderError.locationDenied
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }

        let now = Date()
        let meta = RecordingLog.Meta(
            id: UUID(), activity: activity, startedAt: now,
            autoPause: options.autoPause, savesToHealth: options.savesToHealth,
            lapDistance: options.lapDistance ?? activity.defaultLapDistance,
            sections: options.sections, targetPace: options.targetPace,
            uploadsToStridee: options.uploadsToStridee
        )
        log.begin(meta)
        self.meta = meta
        self.options = options
        self.activity = activity
        tracker = RouteTracker(tuning: .for(activity, barometric: false), autoPause: options.autoPause)
        metrics = Metrics()
        route = []
        lastLocation = nil
        wasRecovered = false
        startedAt = now
        movingBanked = 0
        movingSince = now
        stoppedBy = nil
        coach = WorkoutCoach(lapDistance: meta.lapDistance, sections: meta.sections, overallTargetPace: meta.targetPace)
        laps = []

        state = .recording
        isWarmingUp = false
        startLocation()
        startAltimeter()
        startHeartRate()
        startTicker()
        // Announces the first section.
        driveCoach(now: now)
        logger.notice("recording \(activity.rawValue, privacy: .public)")
    }

    /// Pause by hand. The clock stops and GPS goes off until ``resume()``.
    public func pause() {
        guard state == .recording || state == .autoPaused else { return }
        let now = Date()
        if state == .recording {
            stopClock(at: now, by: .pause)
        }
        // From auto-pause the clock is already stopped; the resume will
        // answer that motion pause.
        tracker?.pause()
        state = .paused
        manager.stopUpdatingLocation()
        refreshMetrics(now: now)
    }

    /// Carry on after a pause, or after a recording was restored.
    public func resume() {
        guard state == .paused else { return }
        let now = Date()
        startClock(at: now)
        tracker?.resume()
        state = .recording
        wasRecovered = false
        startLocation()
        startAltimeter()
        refreshMetrics(now: now)
    }

    /// Stop recording and deliver the workout: to Apple Health, when allowed,
    /// and to Stridee — whether or not this user connected Apple Health sync,
    /// since recording it is the consent. Offline, it waits on disk and goes
    /// on the next launch or foreground.
    ///
    /// Throws ``WorkoutRecorderError/nothingRecorded`` without stopping when
    /// GPS never found the athlete; ``discard()`` throws the attempt away.
    @discardableResult
    public func finish() async throws -> FinishedWorkout {
        guard state != .idle else { throw WorkoutRecorderError.notRecording }
        guard var contents = log.load(), !contents.fixes.isEmpty else {
            throw WorkoutRecorderError.nothingRecorded
        }

        let end = Date()
        if state == .recording {
            // The clock is running; close it so Apple Health and the FIT file
            // agree with what the athlete saw.
            stopClock(at: end, by: .pause)
        }
        stopEverything()
        log.flush()
        contents = log.load() ?? contents

        let meta = contents.meta
        let movingTime = contents.movingTime(until: end)
        let sync = HealthSync.shared

        // Apple Health first: its UUID becomes the workout's identity on
        // Stridee too, so a later history sync of the same workout is one the
        // API already has.
        var saved: HKWorkout?
        if meta.savesToHealth, RecordedWorkoutWriter.canSave(store) {
            // Marked before saving: HealthKit tells HealthSync about the new
            // workout as soon as it exists, and it must find it marked. (One
            // your app uploads itself is marked in its own metadata instead.)
            if meta.uploadsToStridee { sync.state.recordedWorkouts.insert(meta.id.uuidString) }
            do {
                saved = try await RecordedWorkoutWriter.save(contents, end: end, store: store) { [logger] error in
                    logger.error("workout saved without its route: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                logger.error("could not save to Apple Health: \(error.localizedDescription, privacy: .public)")
                sync.state.recordedWorkouts.remove(meta.id.uuidString)
            }
        }

        // Queued on disk, and uploaded with the full route this recorder kept.
        var queued = false
        if meta.uploadsToStridee {
            let uuid = saved?.uuid ?? meta.id
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            let snapshot = contents
            let body = await Task.detached {
                RecordedWorkoutWriter.payload(for: snapshot, uuid: uuid, end: end, sourceName: name, sourceBundleId: bundleId)
            }.value
            if let body {
                queued = sync.queueRecordedWorkout(body, key: uuid.uuidString)
            } else {
                logger.error("could not serialise the recording")
            }
        }

        let finished = FinishedWorkout(
            id: saved?.uuid ?? meta.id,
            recordingID: meta.id,
            activity: meta.activity,
            startDate: meta.startedAt,
            endDate: end,
            distance: contents.distance,
            movingTime: movingTime,
            elevationGain: contents.elevationGain,
            healthKitWorkout: saved,
            delivery: !meta.uploadsToStridee ? .byYourApp : (queued ? .uploading : .notDelivered),
            laps: coach?.laps ?? laps,
            route: contents.samples,
            heartRate: contents.heartRate.map { HeartRateSample(date: $0.t, beatsPerMinute: $0.bpm) }
        )
        log.clear()
        reset()
        return finished
    }

    /// Throw the recording away. Nothing is saved or sent.
    public func discard() {
        guard state != .idle else { return }
        stopEverything()
        log.clear()
        reset()
    }

    /// Add a heart-rate reading from a strap your app is connected to. Kept
    /// while the clock runs, and delivered with the workout.
    public func addHeartRate(_ beatsPerMinute: Double, at date: Date = Date()) {
        guard state.isActive, beatsPerMinute > 0, beatsPerMinute < 260 else { return }
        heartRate = Int(beatsPerMinute.rounded())
        // Live on screen whatever the state; kept only while the clock runs,
        // so the average is the workout's and not the standing around.
        guard state == .recording else { return }
        log.append(.heartRate(.init(t: date, bpm: beatsPerMinute)))
    }

    // MARK: - Clock

    private func stopClock(at date: Date, by kind: RecordingLog.Event.Kind) {
        if let since = movingSince {
            movingBanked += max(0, date.timeIntervalSince(since))
        }
        movingSince = nil
        stoppedBy = kind
        log.append(.event(.init(t: date, kind: kind)))
    }

    private func startClock(at date: Date) {
        guard movingSince == nil else { return }
        movingSince = date
        let kind: RecordingLog.Event.Kind = stoppedBy == .motionPaused ? .motionResumed : .resume
        stoppedBy = nil
        log.append(.event(.init(t: date, kind: kind)))
    }

    private func refreshMetrics(now: Date) {
        guard let tracker else { return }
        var m = metrics
        m.distance = tracker.distance
        m.elevationGain = tracker.elevationGain
        m.movingTime = movingBanked + (movingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        m.elapsedTime = startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        m.currentSpeed = state == .recording ? tracker.currentSpeed : 0
        m.averageSpeed = tracker.distance >= 50 && m.movingTime > 0 ? tracker.distance / m.movingTime : 0
        if m != metrics { metrics = m }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick(now: Date())
            }
        }
    }

    private func tick(now: Date) {
        if state == .recording, case .stopped(let since)? = tracker?.tick(now: now) {
            stopClock(at: since, by: .motionPaused)
            state = .autoPaused
            onEvent?(.autoPaused)
        }
        refreshMetrics(now: now)
        // Off the clock too, so a time-based section ends on time even when
        // GPS is sparse.
        if state == .recording { driveCoach(now: now) }
    }

    /// Feed the coach the latest totals and pass on what it decided.
    private func driveCoach(now: Date) {
        guard var coach else { return }
        let pace = Metrics.pace(metrics.currentSpeed) ?? 0
        let outputs = coach.update(distance: metrics.distance, movingTime: metrics.movingTime, pace: pace, heartRate: heartRate)
        self.coach = coach
        if coach.laps.count != laps.count { laps = coach.laps }
        if currentSection != coach.currentSection { currentSection = coach.currentSection }
        if nextSection != coach.nextSection { nextSection = coach.nextSection }
        if sectionRemaining != coach.sectionRemaining { sectionRemaining = coach.sectionRemaining }
        for output in outputs {
            switch output {
            case .lap(let lap): onEvent?(.lap(lap))
            case let .section(current, next, finished): onEvent?(.section(current: current, next: next, finished: finished))
            case .pace(let cue): onEvent?(.pace(cue))
            }
        }
    }

    // MARK: - Fixes

    fileprivate func received(_ locations: [CLLocation]) {
        if let last = locations.last {
            gpsAccuracy = last.horizontalAccuracy >= 0 ? last.horizontalAccuracy : nil
        }
        guard state == .recording || state == .autoPaused, tracker != nil else { return }
        for location in locations {
            guard let fix = ingest(location) else { continue }
            let now = Date()
            refreshMetrics(now: now)
            if state == .recording { driveCoach(now: now) }
            onEvent?(.sample(Sample(
                date: fix.t, latitude: fix.lat, longitude: fix.lon, altitude: fix.altitude,
                speed: fix.speed, horizontalAccuracy: fix.horizontalAccuracy,
                distance: metrics.distance, movingTime: metrics.movingTime, isMoving: state == .recording
            )))
        }
    }

    /// Record one fix. Returns it when it was kept.
    private func ingest(_ location: CLLocation) -> Fix? {
        // A cached fix from before the recording began is not part of it.
        guard let startedAt, location.timestamp >= startedAt.addingTimeInterval(-2) else { return nil }
        let fix = Fix(
            t: location.timestamp,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: altitude(for: location),
            verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil
        )
        guard var tracker else { return nil }
        let result = tracker.ingest(fix)
        self.tracker = tracker
        guard result.accepted else { return nil }

        if result.motion == .moving, state == .autoPaused {
            startClock(at: fix.t)
            state = .recording
            onEvent?(.autoResumed)
        }
        log.append(.fix(fix, added: result.addedDistance, distance: tracker.distance, elevationGain: tracker.elevationGain))

        lastLocation = location
        if let last = route.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            if location.distance(from: previous) >= 3 { route.append(location.coordinate) }
        } else {
            route.append(location.coordinate)
        }
        return fix
    }

    /// Barometric when there is a barometer reading and a GPS altitude to
    /// anchor it to; GPS altitude otherwise.
    private func altitude(for location: CLLocation) -> Double? {
        let gps = location.verticalAccuracy >= 0 && location.verticalAccuracy <= 30 ? location.altitude : nil
        if let relative = relativeAltitude {
            if altitudeOffset == nil, let gps {
                altitudeOffset = gps - relative
            }
            if let offset = altitudeOffset { return offset + relative }
        }
        return gps
    }

    // MARK: - Sensors

    private func startLocation() {
        if Self.hasBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        } else {
            // Setting allowsBackgroundLocationUpdates without the mode crashes.
            logger.error("UIBackgroundModes has no `location`: recording stops when the screen locks")
        }
        manager.startUpdatingLocation()
    }

    private func startAltimeter() {
        guard !altimeterRunning, CMAltimeter.isRelativeAltitudeAvailable(),
              Self.hasInfoKey("NSMotionUsageDescription"),
              CMAltimeter.authorizationStatus() != .denied, CMAltimeter.authorizationStatus() != .restricted
        else { return }
        altimeterRunning = true
        relativeAltitude = nil
        altitudeOffset = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.relativeAltitude == nil {
                    // The barometer drifts far less than GPS: smaller climbs are real.
                    self.tracker?.useBarometricElevation()
                }
                self.relativeAltitude = data.relativeAltitude.doubleValue
            }
        }
    }

    /// Readings from a paired strap go into the workout by themselves.
    private func startHeartRate() {
        let monitor = HeartRateMonitor.shared
        monitor.activateIfPaired()
        monitor.recorderSink = { [weak self] date, bpm in
            self?.addHeartRate(Double(bpm), at: date)
        }
    }

    private func stopEverything() {
        HeartRateMonitor.shared.recorderSink = nil
        ticker?.cancel()
        ticker = nil
        manager.stopUpdatingLocation()
        if Self.hasBackgroundLocationMode { manager.allowsBackgroundLocationUpdates = false }
        backgroundSession?.invalidate()
        backgroundSession = nil
        if altimeterRunning {
            altimeter.stopRelativeAltitudeUpdates()
            altimeterRunning = false
        }
        relativeAltitude = nil
        altitudeOffset = nil
    }

    private func reset() {
        state = .idle
        activity = nil
        meta = nil
        tracker = nil
        metrics = Metrics()
        route = []
        lastLocation = nil
        startedAt = nil
        wasRecovered = false
        movingBanked = 0
        movingSince = nil
        stoppedBy = nil
        gpsAccuracy = nil
        coach = nil
        laps = []
        currentSection = nil
        nextSection = nil
        sectionRemaining = nil
        heartRate = nil
    }

    // MARK: - Recovery

    /// Pick up a recording the app was killed in the middle of. It lands
    /// paused, with its distance, time and route as they were.
    private func restore() {
        guard let contents = log.load() else { return }
        let meta = contents.meta
        let lastSeen = contents.fixes.last?.t ?? meta.startedAt
        if !contents.endsPaused {
            // The app died with the clock running; it stopped when the last
            // fix arrived.
            log.append(.event(.init(t: lastSeen, kind: .pause)))
        }

        self.meta = meta
        activity = meta.activity
        options = Options(
            autoPause: meta.autoPause, savesToHealth: meta.savesToHealth, lapDistance: meta.lapDistance,
            sections: meta.sections, targetPace: meta.targetPace, uploadsToStridee: meta.uploadsToStridee
        )
        tracker = {
            var t = RouteTracker(
                tuning: .for(meta.activity, barometric: false), autoPause: meta.autoPause,
                distance: contents.distance, elevationGain: contents.elevationGain
            )
            t.pause()
            return t
        }()
        startedAt = meta.startedAt
        movingBanked = contents.movingTime(until: lastSeen)
        movingSince = nil
        stoppedBy = .pause
        route = contents.fixes.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        lastLocation = contents.fixes.last?.location

        // Laps and the section cursor rebuilt by replaying the run, quietly:
        // nothing already said is said again.
        var coach = WorkoutCoach(lapDistance: meta.lapDistance, sections: meta.sections, overallTargetPace: meta.targetPace)
        for (fix, distance) in zip(contents.fixes, contents.distances) {
            _ = coach.update(distance: distance, movingTime: contents.movingTime(until: fix.t), pace: 0, heartRate: nil)
        }
        self.coach = coach
        laps = coach.laps
        currentSection = coach.currentSection
        nextSection = coach.nextSection
        sectionRemaining = coach.sectionRemaining

        state = .paused
        wasRecovered = true
        refreshMetrics(now: Date())
        startHeartRate()
        startTicker()
        logger.notice("restored a \(meta.activity.rawValue, privacy: .public) recording")
    }

    // MARK: - Info.plist

    private var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    private static func hasInfoKey(_ key: String) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    private static var hasBackgroundLocationMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutRecorder: CLLocationManagerDelegate {
    // The manager was created on the main thread, so it calls back there.
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.received(locations) }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let status = manager.authorizationStatus
            self.locationAuthorization = status
            guard status != .notDetermined else { return }
            let waiters = self.authorizationWaiters
            self.authorizationWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: status) }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` is transient: CoreLocation keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        MainActor.assumeIsolated {
            self.logger.error("location failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Results and errors

/// A recording, finished and on its way.
public struct FinishedWorkout: Sendable {
    /// The workout's identity on Stridee — the `HKWorkout`'s UUID when it was
    /// saved to Apple Health. `activity.created` carries it as the
    /// activity's external id.
    public let id: UUID
    /// The recording's own id, fixed from the moment it started — a key for
    /// your own upload that a retry cannot duplicate.
    public let recordingID: UUID
    public let activity: WorkoutRecorder.Activity
    public let startDate: Date
    public let endDate: Date
    /// Metres.
    public let distance: Double
    /// Seconds, pauses excluded.
    public let movingTime: TimeInterval
    /// Metres climbed.
    public let elevationGain: Double
    /// The workout in Apple Health, when it was saved there.
    public let healthKitWorkout: HKWorkout?
    public let delivery: Delivery
    public let laps: [WorkoutRecorder.Lap]
    /// Every recorded fix, in order.
    public let route: [WorkoutRecorder.Sample]
    public let heartRate: [WorkoutRecorder.HeartRateSample]

    public enum Delivery: Sendable, Equatable {
        /// Queued on disk and uploading — now, or when the network is back.
        /// ``HealthSync/status`` follows it.
        case uploading
        /// It could not be serialised, so it was not queued. Logged.
        case notDelivered
        /// ``WorkoutRecorder/Options/uploadsToStridee`` was off: yours to send.
        case byYourApp
    }
}

public enum WorkoutRecorderError: Error, Sendable, Equatable, LocalizedError {
    /// ``WorkoutRecorder/start(_:options:)`` while a recording is active.
    case alreadyRecording
    /// ``WorkoutRecorder/finish()`` with nothing recording.
    case notRecording
    /// The athlete has turned location off for your app. Send them to
    /// ``HealthSync/openSettings()``.
    case locationDenied
    /// Your `Info.plist` is missing a key iOS requires.
    case missingInfoPlistKey(String)
    /// GPS never found the athlete — indoors, or straight after starting.
    /// The recording is still active: carry on, or ``WorkoutRecorder/discard()``.
    case nothingRecorded
    case healthKit(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A workout is already being recorded."
        case .notRecording: return "No workout is being recorded."
        case .locationDenied: return "Location access is off for this app."
        case .missingInfoPlistKey(let key): return "Info.plist is missing \(key)."
        case .nothingRecorded: return "No GPS position was recorded."
        case .healthKit(let why): return "Apple Health: \(why)"
        }
    }
}

// MARK: - HealthSync side

extension HealthSync {
    /// Queue a recorded workout and upload it now.
    func queueRecordedWorkout(_ body: Data, key: String) -> Bool {
        let queued = queue.enqueue(body, kind: .recording, key: key)
        status.pendingUploads = queue.count
        Task { await self.uploadRecordings() }
        return queued
    }
}
