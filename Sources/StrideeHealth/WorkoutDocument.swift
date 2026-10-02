import Foundation

/// One workout the API wants on the watch, as
/// `GET /v1/device/apple/scheduled-workouts` lists it.
struct ScheduledItem: Decodable, Equatable {
    /// The workout, as your server's `POST /v1/workouts` returned it. What a
    /// report names.
    let id: String
    /// The id the WorkoutKit plan is scheduled under. The API chooses it, so a
    /// reschedule replaces the plan instead of adding a second one, and a
    /// finished `HKWorkout` can be matched back to this workout.
    let planId: UUID
    /// Which version of the workout this is. Opaque, and echoed in the report,
    /// so a report about a workout that has since been edited is ignored.
    let revision: String
    /// The athlete's calendar day, `yyyy-MM-dd`.
    let scheduledDate: String
    /// Where the API thinks this stands: `pending`, `synced` or `failed`.
    let status: String
    let reason: String?
    let workout: WorkoutDocument

    enum CodingKeys: String, CodingKey {
        case id, revision, status, reason, workout
        case planId = "plan_id"
        case scheduledDate = "scheduled_date"
    }
}

struct ScheduledWorkoutsResponse: Decodable {
    let workouts: [ScheduledItem]
}

/// `workoutkit.v1` — a structured workout in the shape WorkoutKit's
/// `CustomWorkout` takes.
///
/// The API does the translating: which step is the warm-up, what a pace
/// becomes in metres per second, what cannot be expressed at all. This type
/// only carries the result, and ``WorkoutPlanBuilder`` turns it into
/// WorkoutKit's own values without interpreting anything.
///
/// A goal, alert or activity this version of the SDK has never heard of
/// decodes to `.unknown` rather than failing: one new kind on the API must not
/// make an older app unable to read the rest of the schedule.
struct WorkoutDocument: Decodable, Equatable {
    let format: String
    /// An `HKWorkoutActivityType` case, by name.
    let activity: String
    /// `outdoor`, `indoor` or `unknown`.
    let location: String
    let displayName: String
    let warmup: Step?
    let blocks: [Block]
    let cooldown: Step?

    struct Block: Decodable, Equatable {
        let iterations: Int
        let steps: [Step]
    }

    struct Step: Decodable, Equatable {
        /// `work` or `recovery`.
        let purpose: String
        let goal: Goal
        let alert: Alert?
        let displayName: String?
    }

    enum Goal: Decodable, Equatable {
        case open
        case time(seconds: Double)
        /// `unit` is `meters`, `kilometers`, `yards` or `miles`.
        case distance(value: Double, unit: String)
        case energy(kilocalories: Double)
        case unknown(String)

        private enum CodingKeys: String, CodingKey {
            case type, seconds, value, unit, kilocalories
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "open":
                self = .open
            case "time":
                self = .time(seconds: try c.decode(Double.self, forKey: .seconds))
            case "distance":
                self = .distance(
                    value: try c.decode(Double.self, forKey: .value),
                    unit: try c.decode(String.self, forKey: .unit)
                )
            case "energy":
                self = .energy(kilocalories: try c.decode(Double.self, forKey: .kilocalories))
            default:
                self = .unknown(type)
            }
        }
    }

    enum Alert: Decodable, Equatable {
        /// Beats per minute.
        case heartRateRange(low: Double, high: Double)
        case heartRateZone(Int)
        /// Metres per second. `averaged` compares the step's average rather
        /// than the live reading.
        case speedRange(low: Double, high: Double, averaged: Bool)
        /// Watts.
        case powerRange(low: Double, high: Double, averaged: Bool)
        case powerZone(Int)
        /// Per minute.
        case cadenceRange(low: Double, high: Double)
        case unknown(String)

        private enum CodingKeys: String, CodingKey {
            case type, low, high, zone, metric
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            func band() throws -> (Double, Double) {
                (try c.decode(Double.self, forKey: .low), try c.decode(Double.self, forKey: .high))
            }
            func averaged() throws -> Bool {
                try c.decodeIfPresent(String.self, forKey: .metric) == "average"
            }
            switch type {
            case "heartRateRange":
                let (low, high) = try band()
                self = .heartRateRange(low: low, high: high)
            case "heartRateZone":
                self = .heartRateZone(try c.decode(Int.self, forKey: .zone))
            case "speedRange":
                let (low, high) = try band()
                self = .speedRange(low: low, high: high, averaged: try averaged())
            case "powerRange":
                let (low, high) = try band()
                self = .powerRange(low: low, high: high, averaged: try averaged())
            case "powerZone":
                self = .powerZone(try c.decode(Int.self, forKey: .zone))
            case "cadenceRange":
                let (low, high) = try band()
                self = .cadenceRange(low: low, high: high)
            default:
                self = .unknown(type)
            }
        }
    }
}

/// What this device has put on the watch for one workout.
///
/// Kept so the next sync can tell a workout that is already in place from one
/// that changed, without rebuilding and rescheduling everything every time the
/// app is opened.
struct ManagedPlan: Codable, Equatable {
    /// The workout's id on the API.
    let workoutId: String
    /// The revision that was scheduled.
    let revision: String
    /// The day it was scheduled for, `yyyy-MM-dd`.
    let date: String
}

/// What one pass over the schedule should do, decided without touching
/// WorkoutKit so it can be tested.
struct SchedulePass: Equatable {
    /// Already on the watch exactly as listed. Nothing to do but, perhaps,
    /// tell the API so.
    var inPlace: [ScheduledItem] = []
    /// To build and schedule, replacing whatever is there under the same id.
    var toSchedule: [ScheduledItem] = []
    /// Plans this SDK scheduled that should come off the watch.
    var toRemove: Set<UUID> = []
    /// Listed, and there is no room for it yet. Left `pending`; it takes a
    /// slot when an earlier workout's day has passed.
    var waiting: [ScheduledItem] = []
}

enum SchedulePlanner {
    /// Make the watch match the list.
    ///
    /// - Parameters:
    ///   - items: What the API listed, soonest first.
    ///   - managed: What this SDK scheduled before, by plan id.
    ///   - onWatch: The plan ids WorkoutKit holds right now, this app's own
    ///     included.
    ///   - capacity: `WorkoutScheduler.maxAllowedScheduledWorkoutCount`.
    ///   - today: The athlete's local day, `yyyy-MM-dd`.
    ///
    /// The soonest workouts take the room there is. WorkoutKit holds a small
    /// fixed number, shared with anything else the app schedules itself, so a
    /// month of training cannot all go on at once and does not need to.
    static func plan(
        items: [ScheduledItem],
        managed: [UUID: ManagedPlan],
        onWatch: Set<UUID>,
        capacity: Int,
        today: String
    ) -> SchedulePass {
        var pass = SchedulePass()
        let listed = Set(items.map(\.planId))

        // Everything this SDK put there that the API no longer lists: deleted,
        // taken off the calendar, or far enough in the past to have aged out.
        pass.toRemove = Set(managed.keys).subtracting(listed)

        // Plans on the watch that are neither ours nor about to be: the app's
        // own. They keep their slots.
        let foreign = onWatch.subtracting(managed.keys).subtracting(listed).count
        var room = max(0, capacity - foreign)

        for item in items {
            let isThere = onWatch.contains(item.planId)
            let unchanged = managed[item.planId]?.revision == item.revision
                && managed[item.planId]?.date == item.scheduledDate

            if item.scheduledDate < today && !(isThere && unchanged) {
                // WorkoutKit will not surface a workout scheduled into the
                // past, so one that never made it is not added late — and a
                // stale copy of it is not left behind either.
                if isThere { pass.toRemove.insert(item.planId) }
            } else if room == 0 {
                // No room: a sooner workout has the slot. A copy already there
                // comes off rather than holding it, or sitting there stale.
                if isThere { pass.toRemove.insert(item.planId) }
                pass.waiting.append(item)
            } else if isThere && unchanged {
                // Holds its slot, whatever its date: yesterday's session stays
                // visible until the API stops listing it.
                room -= 1
                pass.inPlace.append(item)
            } else {
                room -= 1
                pass.toSchedule.append(item)
            }
        }
        return pass
    }
}
