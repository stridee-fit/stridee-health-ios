import Foundation
import HealthKit
import CoreLocation

/// Turns a finished recording into what leaves the phone: an `HKWorkout` with
/// its route in Apple Health, and a `healthkit.v1` upload for Stridee — the
/// same payload an Apple Watch workout becomes, so the API turns it into the
/// same FIT file and the same `activity.created`.
enum RecordedWorkoutWriter {

    /// The metadata key that marks a workout this SDK recorded. Its value is
    /// the recording's id.
    static let recordingMetadataKey = "fit.stridee.health.recordingID"

    /// Set on a workout whose app uploads it itself
    /// (``WorkoutRecorder/Options/uploadsToStridee`` off). HealthSync never
    /// sends one, whenever it reads it.
    static let uploadedByAppMetadataKey = "fit.stridee.health.uploadedByApp"

    // MARK: - The upload

    /// The upload for a recording, as JSON.
    ///
    /// - Parameter uuid: The workout's identity on the API. The `HKWorkout`'s
    ///   UUID when it was saved to Apple Health — so a later history sync of
    ///   the same workout is recognised as one already delivered — and the
    ///   recording's own id when it was not.
    static func payload(
        for contents: RecordingLog.Contents,
        uuid: UUID,
        end: Date,
        sourceName: String,
        sourceBundleId: String
    ) -> Data? {
        let activity = contents.meta.activity
        let route = contents.fixes.map { fix in
            WorkoutExporter.RawLocation(
                t: fix.t, lat: fix.lat, lon: fix.lon,
                altitude: fix.altitude, speed: fix.speed, course: fix.course,
                horizontalAccuracy: fix.horizontalAccuracy,
                verticalAccuracy: fix.verticalAccuracy
            )
        }
        let payload = WorkoutExporter.RawPayload(
            uuid: uuid.uuidString,
            activityType: activity.healthKitType.rawValue,
            serverType: WorkoutExporter.sportMapping(activity.healthKitType),
            sourceName: sourceName,
            sourceBundleId: sourceBundleId,
            deviceName: "iPhone",
            startDate: contents.meta.startedAt,
            endDate: end,
            duration: contents.movingTime(until: end),
            totalDistanceMeters: contents.distance,
            totalEnergyKcal: nil,
            workoutPlanId: nil,
            heartRate: contents.heartRate.map { .init(t: $0.t, v: $0.bpm) },
            runningPower: [],
            cyclingPower: [],
            cyclingCadence: [],
            route: route,
            events: contents.events.map { .init(t: $0.t, type: $0.kind.rawValue) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithMilliseconds
        return try? encoder.encode(payload)
    }

    // MARK: - Apple Health

    /// What the recorder asks to write. Read access to the same types is the
    /// HealthSync side's business.
    static var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        let ids: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .heartRate]
        for id in ids {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// Whether the athlete lets this app save the workout itself. Unlike
    /// reading, iOS does say.
    static func canSave(_ store: HKHealthStore) -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") != nil else {
            return false
        }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    /// Save the recording to Apple Health, with its route, distance samples,
    /// pauses and heart rate. Returns the workout, or throws what stopped it.
    ///
    /// The route is optional to the athlete's permissions: a workout saved
    /// without one is still a workout, and the Stridee upload carries the
    /// route either way.
    static func save(
        _ contents: RecordingLog.Contents, end: Date, store: HKHealthStore,
        routeError: ((Error) -> Void)? = nil
    ) async throws -> HKWorkout {
        let activity = contents.meta.activity
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.healthKitType
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: contents.meta.startedAt)

        var samples: [HKSample] = distanceSamples(contents, activity: activity)
        if store.authorizationStatus(for: HKQuantityType(.heartRate)) == .sharingAuthorized {
            let unit = HKUnit.count().unitDivided(by: .minute())
            samples += contents.heartRate.map {
                HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: unit, doubleValue: $0.bpm), start: $0.t, end: $0.t)
            }
        }
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }

        let events = contents.events.map { event -> HKWorkoutEvent in
            let type: HKWorkoutEventType
            switch event.kind {
            case .pause: type = .pause
            case .resume: type = .resume
            case .motionPaused: type = .motionPaused
            case .motionResumed: type = .motionResumed
            }
            return HKWorkoutEvent(type: type, dateInterval: DateInterval(start: event.t, duration: 0), metadata: nil)
        }
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }

        var metadata: [String: Any] = [
            HKMetadataKeyIndoorWorkout: false,
            recordingMetadataKey: contents.meta.id.uuidString,
        ]
        if !contents.meta.uploadsToStridee {
            metadata[uploadedByAppMetadataKey] = true
        }
        if contents.elevationGain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: contents.elevationGain)
        }
        try await builder.addMetadata(metadata)

        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw WorkoutRecorderError.healthKit("HealthKit returned no workout")
        }

        if !contents.fixes.isEmpty, store.authorizationStatus(for: HKSeriesType.workoutRoute()) == .sharingAuthorized {
            // The workout is saved by now. A route that fails to attach does
            // not undo it — and the Stridee upload carries the route anyway.
            do {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                let locations = contents.fixes.map(\.location)
                // In chunks: one insert of a long ride's every second is slow
                // and memory-hungry for no gain.
                var offset = 0
                while offset < locations.count {
                    let chunk = Array(locations[offset..<min(offset + 1000, locations.count)])
                    try await routeBuilder.insertRouteData(chunk)
                    offset += 1000
                }
                try await routeBuilder.finishRoute(with: workout, metadata: nil)
            } catch {
                routeError?(error)
            }
        }
        return workout
    }

    /// Distance as HealthKit wants it: samples over the time it was covered,
    /// one per minute of movement at most. What fills the workout's total, and
    /// the athlete's daily distance in Apple Health.
    static func distanceSamples(_ contents: RecordingLog.Contents, activity: WorkoutRecorder.Activity) -> [HKQuantitySample] {
        let type = HKQuantityType(activity == .cycling ? .distanceCycling : .distanceWalkingRunning)
        return distanceBuckets(contents).map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: $0.metres), start: $0.start, end: $0.end)
        }
    }

    struct Bucket: Equatable {
        var start: Date
        var end: Date
        var metres: Double
    }

    /// Consecutive counted steps, grouped into stretches of up to a minute. A
    /// stretch never spans a pause: each step runs from the fix before it.
    static func distanceBuckets(_ contents: RecordingLog.Contents, maxLength: TimeInterval = 60) -> [Bucket] {
        var buckets: [Bucket] = []
        var current: Bucket?
        for index in contents.fixes.indices where index > 0 {
            let added = contents.added[index]
            guard added > 0 else {
                if let c = current { buckets.append(c); current = nil }
                continue
            }
            let from = contents.fixes[index - 1].t
            let to = contents.fixes[index].t
            guard to > from else { continue }
            if var c = current, c.end == from, to.timeIntervalSince(c.start) <= maxLength {
                c.end = to
                c.metres += added
                current = c
            } else {
                if let c = current { buckets.append(c) }
                current = Bucket(start: from, end: to, metres: added)
            }
        }
        if let c = current { buckets.append(c) }
        return buckets
    }
}

extension Fix {
    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altitude ?? 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: altitude == nil ? -1 : (verticalAccuracy ?? 10),
            course: course ?? -1,
            speed: speed ?? -1,
            timestamp: t
        )
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// ISO-8601 with milliseconds — what the API's `DateTime<Utc>` reads,
    /// without collapsing fixes a second apart onto the same instant.
    static var iso8601WithMilliseconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
    }
}
