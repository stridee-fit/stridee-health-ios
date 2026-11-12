import Foundation

/// One GPS fix, as the recorder keeps it. A plain value rather than a
/// `CLLocation` so the tracking rules can be tested and the log replayed.
struct Fix: Codable, Equatable, Sendable {
    let t: Date
    let lat: Double
    let lon: Double
    /// Metres. Negative means CoreLocation has no horizontal fix.
    let horizontalAccuracy: Double
    /// Metres above sea level — barometric when the recorder had a barometer,
    /// otherwise GPS. `nil` when neither had a reading.
    let altitude: Double?
    let verticalAccuracy: Double?
    /// Metres per second, or `nil` when CoreLocation did not know.
    let speed: Double?
    /// Degrees from true north, or `nil`.
    let course: Double?
}

/// The rules that turn a stream of GPS fixes into distance, speed, elevation
/// gain and auto-pause decisions.
///
/// Ported from the Stridee app's live recorder, where they ran in
/// production, and kept free of CoreLocation and the clock so every rule is
/// tested. The recorder feeds it fixes as they arrive and ``tick(now:)`` once
/// a second.
struct RouteTracker {
    struct Tuning: Equatable {
        /// Fixes less accurate than this are dropped. 65 m is the accuracy
        /// iOS reports for a usable lock; tighter rejects good fixes under
        /// trees and between buildings.
        var maxHorizontalAccuracy: Double = 65
        /// Faster than this between two fixes is a GPS reset, not movement.
        var maxSpeed: Double
        /// Below this speed for ``pauseAfter`` seconds, the recording auto-pauses.
        var pauseBelow: Double
        /// Above this speed, an auto-paused recording resumes.
        var resumeAbove: Double
        var pauseAfter: TimeInterval
        /// Climbs smaller than this are noise. Smaller for a barometer, whose
        /// readings drift far less than GPS altitude does.
        var elevationThreshold: Double

        static func `for`(_ activity: WorkoutRecorder.Activity, barometric: Bool) -> Tuning {
            let climb: Double = barometric ? 1 : 4
            switch activity {
            case .running:
                return Tuning(maxSpeed: 20, pauseBelow: 0.5, resumeAbove: 1.2, pauseAfter: 8, elevationThreshold: climb)
            case .walking:
                return Tuning(maxSpeed: 20, pauseBelow: 0.35, resumeAbove: 0.8, pauseAfter: 10, elevationThreshold: climb)
            case .hiking:
                // A steep climb is slow: resume early, pause late.
                return Tuning(maxSpeed: 20, pauseBelow: 0.25, resumeAbove: 0.6, pauseAfter: 15, elevationThreshold: climb)
            case .cycling:
                return Tuning(maxSpeed: 50, pauseBelow: 1.0, resumeAbove: 2.0, pauseAfter: 5, elevationThreshold: climb)
            }
        }
    }

    /// What ingesting a fix or a tick decided about auto-pause.
    enum MotionChange: Equatable {
        /// The athlete stopped, at `since` — when they slowed down, not when
        /// the stop had lasted long enough to count.
        case stopped(since: Date)
        case moving
    }

    struct Ingested: Equatable {
        /// Kept for the route. Inaccurate fixes are not.
        var accepted: Bool
        /// Metres this fix added to the distance.
        var addedDistance: Double = 0
        var motion: MotionChange?
    }

    private(set) var tuning: Tuning
    var autoPause: Bool

    /// Whether distance and time are counting: not paused by hand, and not
    /// auto-paused. Set by the recorder on a manual pause; auto-pause is
    /// decided here.
    private(set) var isCounting = true
    private(set) var isAutoPaused = false

    private(set) var distance: Double = 0
    private(set) var elevationGain: Double = 0
    /// Metres per second over the last half minute. 0 when unknown.
    private(set) var currentSpeed: Double = 0

    /// Where distance is measured from. Not moved by jitter, so a phone
    /// standing still adds nothing while a slow walk still adds up.
    private var anchor: Fix?
    private var elevationAnchor: Double?
    private var slowSince: Date?
    private var window: [(t: Date, distance: Double)] = []

    /// Below this speed, a step shorter than ``jitterDistance`` is noise.
    static let jitterSpeed: Double = 0.3
    static let jitterDistance: Double = 5
    static let speedWindow: TimeInterval = 30

    init(tuning: Tuning, autoPause: Bool) {
        self.tuning = tuning
        self.autoPause = autoPause
    }

    /// Restore a tracker from a recovered recording. It resumes measuring from
    /// the next fix, as after any pause.
    init(tuning: Tuning, autoPause: Bool, distance: Double, elevationGain: Double) {
        self.init(tuning: tuning, autoPause: autoPause)
        self.distance = distance
        self.elevationGain = elevationGain
    }

    // MARK: - Manual pause

    /// A manual pause. Distance stops, and the next fix after ``resume()`` is a
    /// fresh starting point: what happened during the pause is not distance.
    mutating func pause() {
        isCounting = false
        isAutoPaused = false
        slowSince = nil
        anchor = nil
        elevationAnchor = nil
        currentSpeed = 0
        window.removeAll()
    }

    mutating func resume() {
        isCounting = true
        isAutoPaused = false
        slowSince = nil
        anchor = nil
    }

    // MARK: - Fixes

    mutating func ingest(_ fix: Fix, manuallyPaused: Bool = false) -> Ingested {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= tuning.maxHorizontalAccuracy else {
            return Ingested(accepted: false)
        }
        if manuallyPaused { return Ingested(accepted: true) }

        var result = Ingested(accepted: true)
        let speed = fix.speed ?? 0

        // Auto-pause and resume flip only on sustained signal, so one bad
        // reading does not bounce the state.
        if autoPause {
            if isAutoPaused {
                if speed > tuning.resumeAbove {
                    isAutoPaused = false
                    isCounting = true
                    slowSince = nil
                    result.motion = .moving
                }
            } else if speed < tuning.pauseBelow {
                if slowSince == nil { slowSince = fix.t }
            } else {
                slowSince = nil
            }
        }

        guard isCounting else {
            // Auto-paused: follow the athlete so the first step after resuming
            // is measured from where they stopped, not from where it paused.
            anchor = fix
            return result
        }

        if let from = anchor {
            let step = Self.metres(from: from, to: fix)
            let dt = fix.t.timeIntervalSince(from.t)
            // A long dropout (a tunnel) makes real movement look fast; cap the
            // interval the speed check is judged over.
            let judged = min(max(dt, 0), 30)
            if step > judged * tuning.maxSpeed {
                // GPS reset. Start again from here.
                anchor = fix
            } else if (fix.speed ?? 0) < Self.jitterSpeed && step < Self.jitterDistance {
                // Standing still. Keep the anchor where it is.
            } else {
                distance += step
                result.addedDistance = step
                anchor = fix
            }
        } else {
            anchor = fix
        }

        if let altitude = fix.altitude { climb(to: altitude) }

        window.append((fix.t, distance))
        window.removeAll { fix.t.timeIntervalSince($0.t) > Self.speedWindow }
        if let first = window.first, fix.t > first.t {
            currentSpeed = max(0, (distance - first.distance) / fix.t.timeIntervalSince(first.t))
        }
        return result
    }

    /// Once a second: auto-pause on a stop held long enough.
    mutating func tick(now: Date) -> MotionChange? {
        guard autoPause, isCounting, !isAutoPaused, let slowSince,
              now.timeIntervalSince(slowSince) >= tuning.pauseAfter
        else { return nil }
        isAutoPaused = true
        isCounting = false
        currentSpeed = 0
        window.removeAll()
        self.slowSince = nil
        return .stopped(since: slowSince)
    }

    /// Altitude now comes from a barometer: count smaller climbs, and measure
    /// from the next reading, since the source just changed.
    mutating func useBarometricElevation() {
        tuning.elevationThreshold = Tuning.for(.running, barometric: true).elevationThreshold
        elevationAnchor = nil
    }

    /// Count a climb only once it clears the threshold, so the noise in an
    /// altitude reading is never added up.
    private mutating func climb(to altitude: Double) {
        guard let base = elevationAnchor else {
            elevationAnchor = altitude
            return
        }
        if altitude - base >= tuning.elevationThreshold {
            elevationGain += altitude - base
            elevationAnchor = altitude
        } else if base - altitude >= tuning.elevationThreshold {
            elevationAnchor = altitude
        }
    }

    /// Great-circle distance, the same haversine `CLLocation.distance(from:)`
    /// agrees with to well under a metre at these distances.
    static func metres(from a: Fix, to b: Fix) -> Double {
        let r = 6_371_008.8
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = (b.lat - a.lat) * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
