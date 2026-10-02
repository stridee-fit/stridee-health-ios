import Foundation
import HealthKit
import WorkoutKit

/// Turns a `workoutkit.v1` document into a WorkoutKit `WorkoutPlan`.
///
/// Apple has no server API for putting a workout on a watch. WorkoutKit, which
/// runs here on the phone, is the only way in, and the Workout app syncs what
/// it schedules to the paired watch on its own.
///
/// The API has already decided what the workout is. What is decided here is
/// what only this device knows: whether its version of iOS supports the
/// activity, each goal and each alert. Anything it does not is refused with a
/// sentence rather than dropped, so the watch never runs a workout that
/// differs from the one that was written.
enum WorkoutPlanBuilder {

    /// Why a workout could not be built. The sentence is reported to the API
    /// and shown to the developer as the push's `error`.
    struct Unsupported: Error, Equatable {
        let reason: String
    }

    static func plan(for item: ScheduledItem) throws -> WorkoutPlan {
        WorkoutPlan(.custom(try workout(from: item.workout)), id: item.planId)
    }

    static func workout(from document: WorkoutDocument) throws -> CustomWorkout {
        guard let activity = activity(named: document.activity) else {
            throw Unsupported(reason: "This version of the Stridee SDK does not know the `\(document.activity)` activity")
        }
        guard CustomWorkout.supportsActivity(activity) else {
            throw Unsupported(reason: "This version of iOS has no custom workout for \(document.activity)")
        }
        let location = location(named: document.location)
        let context = Context(activity: activity, location: location, name: document.activity)

        let blocks = try document.blocks.map { block in
            IntervalBlock(
                steps: try block.steps.map { step in
                    IntervalStep(step.purpose == "recovery" ? .recovery : .work, step: try workoutStep(step, context))
                },
                iterations: max(1, block.iterations)
            )
        }

        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: document.displayName,
            warmup: try document.warmup.map { try workoutStep($0, context) },
            blocks: blocks,
            cooldown: try document.cooldown.map { try workoutStep($0, context) }
        )
    }

    private struct Context {
        let activity: HKWorkoutActivityType
        let location: HKWorkoutSessionLocationType
        let name: String
    }

    private static func workoutStep(_ step: WorkoutDocument.Step, _ context: Context) throws -> WorkoutStep {
        let goal = try makeGoal(step.goal, context)
        let alert: (any WorkoutAlert)? = try step.alert.map { try makeAlert($0, context) }
        // A step's own name reached WorkoutKit in iOS 18. Before that the step
        // is the same step, unnamed.
        if #available(iOS 18.0, *) {
            return WorkoutStep(goal: goal, alert: alert, displayName: step.displayName)
        }
        return WorkoutStep(goal: goal, alert: alert)
    }

    private static func makeGoal(_ goal: WorkoutDocument.Goal, _ context: Context) throws -> WorkoutGoal {
        let built: WorkoutGoal
        switch goal {
        case .open:
            built = .open
        case .time(let seconds):
            built = .time(seconds, .seconds)
        case .distance(let value, let unit):
            guard let unit = lengthUnit(named: unit) else {
                throw Unsupported(reason: "This version of the Stridee SDK does not know the `\(unit)` distance unit")
            }
            built = .distance(value, unit)
        case .energy(let kilocalories):
            built = .energy(kilocalories, .kilocalories)
        case .unknown(let type):
            throw Unsupported(reason: "This version of the Stridee SDK does not know the `\(type)` goal")
        }
        guard CustomWorkout.supportsGoal(built, activity: context.activity, location: context.location) else {
            throw Unsupported(reason: "This version of iOS cannot end a \(context.name) step on \(describe(goal))")
        }
        return built
    }

    private static func makeAlert(_ alert: WorkoutDocument.Alert, _ context: Context) throws -> any WorkoutAlert {
        let built: any WorkoutAlert
        switch alert {
        case .heartRateRange(let low, let high):
            built = HeartRateRangeAlert(target: perMinute(low)...perMinute(max(low, high)))
        case .heartRateZone(let zone):
            built = HeartRateZoneAlert(zone: zone)
        case .speedRange(let low, let high, let averaged):
            built = SpeedRangeAlert(
                target: Measurement(value: low, unit: UnitSpeed.metersPerSecond)
                    ... Measurement(value: max(low, high), unit: UnitSpeed.metersPerSecond),
                metric: averaged ? .average : .current
            )
        case .powerRange(let low, let high, let averaged):
            let target = Measurement(value: low, unit: UnitPower.watts)
                ... Measurement(value: max(low, high), unit: UnitPower.watts)
            if #available(iOS 17.4, *) {
                built = PowerRangeAlert(target: target, metric: averaged ? .average : .current)
            } else if averaged {
                throw Unsupported(reason: "An averaged power target needs iOS 17.4 or later")
            } else {
                built = PowerRangeAlert(target: target)
            }
        case .powerZone(let zone):
            built = PowerZoneAlert(zone: zone)
        case .cadenceRange(let low, let high):
            built = CadenceRangeAlert(target: perMinute(low)...perMinute(max(low, high)))
        case .unknown(let type):
            throw Unsupported(reason: "This version of the Stridee SDK does not know the `\(type)` alert")
        }
        guard CustomWorkout.supportsAlert(built, activity: context.activity, location: context.location) else {
            throw Unsupported(reason: "This version of iOS cannot hold a \(context.name) step to \(describe(alert))")
        }
        return built
    }

    /// Heart rate and cadence are counts per minute, which Foundation has no
    /// unit for; WorkoutKit supplies the one it converts from.
    private static func perMinute(_ value: Double) -> Measurement<UnitFrequency> {
        Measurement(value: value, unit: WorkoutAlertMetric.countPerMinute)
    }

    // MARK: - Names

    static func activity(named name: String) -> HKWorkoutActivityType? {
        switch name {
        case "running": return .running
        case "cycling": return .cycling
        case "swimming": return .swimming
        case "hiking": return .hiking
        case "walking": return .walking
        case "rowing": return .rowing
        case "mixedCardio": return .mixedCardio
        case "highIntensityIntervalTraining": return .highIntensityIntervalTraining
        case "yoga": return .yoga
        case "pilates": return .pilates
        case "other": return .other
        default: return nil
        }
    }

    static func location(named name: String) -> HKWorkoutSessionLocationType {
        switch name {
        case "outdoor": return .outdoor
        case "indoor": return .indoor
        default: return .unknown
        }
    }

    static func lengthUnit(named name: String) -> UnitLength? {
        switch name {
        case "meters": return .meters
        case "kilometers": return .kilometers
        case "yards": return .yards
        case "miles": return .miles
        default: return nil
        }
    }

    private static func describe(_ goal: WorkoutDocument.Goal) -> String {
        switch goal {
        case .open: return "the lap button"
        case .time: return "a time"
        case .distance: return "a distance"
        case .energy: return "calories burned"
        case .unknown(let type): return type
        }
    }

    private static func describe(_ alert: WorkoutDocument.Alert) -> String {
        switch alert {
        case .heartRateRange: return "a heart-rate range"
        case .heartRateZone: return "a heart-rate zone"
        case .speedRange: return "a pace"
        case .powerRange: return "a power range"
        case .powerZone: return "a power zone"
        case .cadenceRange: return "a cadence"
        case .unknown(let type): return type
        }
    }
}
