import Foundation
import HealthKit
import CoreLocation
import WorkoutKit

/// Serialises an `HKWorkout` — with its GPS route and sensor sample streams —
/// into a `healthkit.v1` payload for `POST /v1/device/apple/workouts`.
///
/// HealthKit has no native file format, so this JSON *is* the raw data. The
/// server stores it, encodes the `.fit`, and delivers it. Keeping the client
/// thin (no on-device FIT encoding) means an improved encoder can be re-run
/// server-side over every stored payload later.
///
/// Ported from the Stridee app, where it ran in production. The wire format
/// has only ever gained optional fields, so every version's payload is one the
/// API reads.
struct WorkoutExporter {

    /// The JSON payload plus the dedup key (for logging / bookkeeping).
    struct Exported {
        let rawData: Data
        let externalId: String   // HKWorkout.uuid
    }

    let store: HKHealthStore

    /// Build the raw JSON for `workout`. Returns nil only if JSON encoding fails.
    func export(_ workout: HKWorkout) async -> Exported? {
        let mapping = Self.sportMapping(workout.workoutActivityType)
        let start = workout.startDate
        let end = workout.endDate

        async let locations = routeLocations(for: workout)
        async let heart = quantitySamples(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end)
        async let powerRun = quantitySamples(.runningPower, unit: .watt(), start: start, end: end)
        async let powerBike = quantitySamples(.cyclingPower, unit: .watt(), start: start, end: end)
        async let cadenceBike = quantitySamples(.cyclingCadence, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end)

        // The WorkoutKit plan this workout was started from, when it was started
        // from one. For a workout the API scheduled, that id is how the
        // resulting activity names the workout it was done from.
        let planId = (try? await workout.workoutPlan)?.id.uuidString

        let locs = await locations
        let hr = await heart
        let runPower = await powerRun
        let bikePower = await powerBike
        let cadence = await cadenceBike

        func samples(_ a: [(Date, Double)]) -> [RawSample] { a.map { RawSample(t: $0.0, v: $0.1) } }

        let payload = RawPayload(
            uuid: workout.uuid.uuidString,
            activityType: workout.workoutActivityType.rawValue,
            serverType: mapping,
            sourceName: workout.sourceRevision.source.name,
            sourceBundleId: workout.sourceRevision.source.bundleIdentifier,
            deviceName: deviceName(workout),
            startDate: start,
            endDate: end,
            duration: workout.duration,
            totalDistanceMeters: distanceMeters(workout),
            totalEnergyKcal: activeCalories(workout),
            workoutPlanId: planId,
            heartRate: samples(hr),
            runningPower: samples(runPower),
            cyclingPower: samples(bikePower),
            cyclingCadence: samples(cadence),
            route: locs.map {
                RawLocation(
                    t: $0.timestamp,
                    lat: $0.coordinate.latitude,
                    lon: $0.coordinate.longitude,
                    altitude: $0.verticalAccuracy >= 0 ? $0.altitude : nil,
                    speed: $0.speed >= 0 ? $0.speed : nil,
                    course: $0.course >= 0 ? $0.course : nil,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            },
            events: (workout.workoutEvents ?? []).compactMap(Self.pauseEvent)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return nil }
        return Exported(rawData: data, externalId: payload.uuid)
    }

    // MARK: - Raw payload (mirrors the server's `HealthKitWorkoutPayload`)

    struct RawPayload: Codable {
        var format = "healthkit.v1"
        let uuid: String
        let activityType: UInt
        let serverType: String
        let sourceName: String
        let sourceBundleId: String
        let deviceName: String?
        let startDate: Date
        let endDate: Date
        let duration: TimeInterval
        let totalDistanceMeters: Double?
        let totalEnergyKcal: Double?
        let workoutPlanId: String?
        let heartRate: [RawSample]
        let runningPower: [RawSample]
        let cyclingPower: [RawSample]
        let cyclingCadence: [RawSample]
        let route: [RawLocation]
        let events: [RawEvent]
    }
    struct RawSample: Codable { let t: Date; let v: Double }
    struct RawEvent: Codable { let t: Date; let type: String }
    struct RawLocation: Codable {
        let t: Date
        let lat: Double
        let lon: Double
        let altitude: Double?
        let speed: Double?
        let course: Double?
        let horizontalAccuracy: Double?
        let verticalAccuracy: Double?
    }

    // MARK: - Workout-level values

    private func distanceMeters(_ workout: HKWorkout) -> Double? {
        let ids: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        for id in ids {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            if let q = workout.statistics(for: type)?.sumQuantity() {
                return q.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private func activeCalories(_ workout: HKWorkout) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let q = workout.statistics(for: type)?.sumQuantity() else { return nil }
        return q.doubleValue(for: .kilocalorie())
    }

    private func deviceName(_ workout: HKWorkout) -> String? {
        if let name = workout.device?.name, !name.isEmpty { return name }
        if let model = workout.device?.model, !model.isEmpty { return model }
        let src = workout.sourceRevision.source.name
        return src.isEmpty ? nil : src
    }

    /// A pause or resume, the only workout events the server reads. It pairs
    /// them into the FIT file's timer events.
    private static func pauseEvent(_ event: HKWorkoutEvent) -> RawEvent? {
        let type: String
        switch event.type {
        case .pause: type = "pause"
        case .resume: type = "resume"
        case .motionPaused: type = "motionPaused"
        case .motionResumed: type = "motionResumed"
        default: return nil
        }
        return RawEvent(t: event.dateInterval.start, type: type)
    }

    // MARK: - HealthKit queries

    private func quantitySamples(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> [(Date, Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let result: [(Date, Double)] = (samples as? [HKQuantitySample] ?? []).compactMap { sample in
                    guard sample.quantity.is(compatibleWith: unit) else { return nil }
                    return (sample.startDate, sample.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    private func routeLocations(for workout: HKWorkout) async -> [CLLocation] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            store.execute(query)
        }
        guard !routes.isEmpty else { return [] }

        var all: [CLLocation] = []
        for route in routes {
            all.append(contentsOf: await locations(for: route))
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(for route: HKWorkoutRoute) async -> [CLLocation] {
        await withCheckedContinuation { continuation in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                if let locations { collected.append(contentsOf: locations) }
                if done { continuation.resume(returning: collected) }
            }
            store.execute(query)
        }
    }

    // MARK: - Sport mapping

    /// Map HealthKit's activity type to the server discipline code. The server
    /// normalises the string anyway, so unknown types fall back to GENERIC.
    static func sportMapping(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running, .trackAndField: return "RUNNING"
        case .cycling, .handCycling: return "CYCLING"
        case .swimming: return "SWIMMING"
        case .walking: return "WALKING"
        case .hiking: return "HIKING"
        case .rowing: return "ROWING"
        case .crossCountrySkiing: return "CROSS_COUNTRY_SKIING"
        case .downhillSkiing, .snowSports: return "ALPINE_SKIING"
        case .snowboarding: return "SNOWBOARDING"
        case .paddleSports: return "PADDLING"
        case .climbing: return "ROCK_CLIMBING"
        case .elliptical, .stairClimbing, .stepTraining, .highIntensityIntervalTraining,
             .functionalStrengthTraining, .traditionalStrengthTraining, .coreTraining,
             .crossTraining, .mixedCardio:
            return "TRAINING"
        default: return "GENERIC"
        }
    }
}
