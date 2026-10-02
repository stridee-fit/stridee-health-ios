import Foundation
import HealthKit

/// Builds `healthkit.wellness.v1` items from HealthKit for a window of days.
///
/// HealthKit holds samples, not summaries, so this is where "a day" and "a
/// night" are decided. Every item it emits is keyed by its kind and start time
/// on the server, so re-collecting a window that was already sent is safe: an
/// unchanged item is stored as-is and announces nothing. That is what lets a
/// sync simply re-collect the last couple of days every time instead of
/// tracking which samples it has seen.
///
/// Daily totals come from `HKStatisticsCollectionQuery`, never from summing
/// samples: an iPhone and an Apple Watch both record the same steps, and only
/// HealthKit's statistics merge the two sources without double counting.
struct WellnessCollector {
    let store: HKHealthStore
    var calendar: Calendar = .current

    typealias Item = [String: Any]

    /// Every item in `[start, end]`, oldest first within each kind.
    func collect(from start: Date, to end: Date) async -> [Item] {
        let dayStart = calendar.startOfDay(for: start)

        async let daily = dailyItems(from: dayStart, to: end)
        async let sleep = sleepItems(from: dayStart, to: end)
        async let hrv = perDaySampleItems(
            kind: "hrv", .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), scale: 1,
            from: dayStart, to: end
        )
        async let respiration = perDaySampleItems(
            kind: "respiration", .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), scale: 1,
            from: dayStart, to: end
        )
        // HealthKit's percent is a fraction; ours is 0–100.
        async let pulseOx = perDaySampleItems(
            kind: "pulse_ox", .oxygenSaturation, unit: .percent(), scale: 100,
            from: dayStart, to: end
        )
        async let fitness = fitnessItems(from: dayStart, to: end)
        async let body = bodyCompositionItems(from: dayStart, to: end)
        async let pressure = bloodPressureItems(from: dayStart, to: end)
        async let temperature = wristTemperatureItems(from: dayStart, to: end)

        var items: [Item] = []
        items += await daily
        items += await sleep
        items += await hrv
        items += await respiration
        items += await pulseOx
        items += await fitness
        items += await body
        items += await pressure
        items += await temperature
        return items
    }

    // MARK: - Daily totals

    private struct DailyField {
        let id: HKQuantityTypeIdentifier
        let unit: HKUnit
        let options: HKStatisticsOptions
        let read: (HKStatistics, HKUnit) -> [(String, Double)]
    }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    private static let dailyFields: [DailyField] = [
        .init(id: .stepCount, unit: .count(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "steps")
        },
        .init(id: .distanceWalkingRunning, unit: .meter(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "distanceMeters")
        },
        .init(id: .activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "activeKilocalories")
        },
        .init(id: .basalEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "basalKilocalories")
        },
        .init(id: .flightsClimbed, unit: .count(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "flightsClimbed")
        },
        .init(id: .appleExerciseTime, unit: .minute(), options: .cumulativeSum) { s, u in
            WellnessCollector.sum(s, u, "exerciseMinutes")
        },
        .init(id: .restingHeartRate, unit: WellnessCollector.bpm, options: .discreteAverage) { s, u in
            s.averageQuantity().map { [("restingHeartRate", $0.doubleValue(for: u))] } ?? []
        },
        .init(id: .heartRate, unit: WellnessCollector.bpm, options: [.discreteAverage, .discreteMin, .discreteMax]) { s, u in
            var out: [(String, Double)] = []
            if let v = s.averageQuantity() { out.append(("avgHeartRate", v.doubleValue(for: u))) }
            if let v = s.minimumQuantity() { out.append(("minHeartRate", v.doubleValue(for: u))) }
            if let v = s.maximumQuantity() { out.append(("maxHeartRate", v.doubleValue(for: u))) }
            return out
        },
    ]

    private static func sum(_ s: HKStatistics, _ u: HKUnit, _ key: String) -> [(String, Double)] {
        s.sumQuantity().map { [(key, $0.doubleValue(for: u))] } ?? []
    }

    private func dailyItems(from dayStart: Date, to end: Date) async -> [Item] {
        var byDay: [Date: Item] = [:]

        for field in Self.dailyFields {
            for (day, stats) in await dailyStatistics(field, from: dayStart, to: end) {
                for (key, value) in field.read(stats, field.unit) {
                    byDay[day, default: [:]][key] = value
                }
            }
        }

        return byDay.keys.sorted().compactMap { day in
            guard let values = byDay[day], !values.isEmpty,
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            var item = base(kind: "daily", start: day, end: next, calendarDay: day, final: isSettled(dayEnding: next))
            item.merge(values) { _, new in new }
            return item
        }
    }

    private func dailyStatistics(_ field: DailyField, from start: Date, to end: Date) async -> [(Date, HKStatistics)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: field.id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: field.options,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, _ in
                var out: [(Date, HKStatistics)] = []
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    out.append((stats.startDate, stats))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    // MARK: - Sleep

    /// HealthKit's sleep values, by raw value so this compiles the same on
    /// every SDK that knows them: inBed 0, asleepUnspecified 1, awake 2,
    /// asleepCore 3, asleepDeep 4, asleepREM 5.
    private static let stageNames: [Int: String] = [
        0: "inBed", 1: "asleepUnspecified", 2: "awake", 3: "core", 4: "deep", 5: "rem",
    ]

    /// A gap this long between samples ends one night and starts the next.
    private static let sessionGap: TimeInterval = 3 * 3600

    private func sleepItems(from dayStart: Date, to end: Date) async -> [Item] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        // From the evening before the window, so the first night is whole.
        let from = calendar.date(byAdding: .hour, value: -12, to: dayStart) ?? dayStart
        let samples: [HKCategorySample] = await self.samples(type, from: from, to: end)
            .compactMap { $0 as? HKCategorySample }
            .sorted { $0.startDate < $1.startDate }

        // Nights, across every source that wrote one.
        var sessions: [[HKCategorySample]] = []
        for sample in samples {
            if let lastEnd = sessions.last?.map(\.endDate).max(),
               sample.startDate.timeIntervalSince(lastEnd) < Self.sessionGap {
                sessions[sessions.count - 1].append(sample)
            } else {
                sessions.append([sample])
            }
        }

        let now = Date()
        return sessions.compactMap { session in
            // One source per night: the one with the most detail. A watch's
            // stages beat a phone's "in bed", and two sources' overlapping
            // records would otherwise be counted twice.
            let bySource = Dictionary(grouping: session) { $0.sourceRevision.source.bundleIdentifier }
            guard let chosen = bySource.values.max(by: { detail($0) < detail($1) }),
                  let start = chosen.map(\.startDate).min(),
                  let stop = chosen.map(\.endDate).max() else { return nil }

            // Still asleep, or the watch has not written the night yet.
            guard stop < now.addingTimeInterval(-30 * 60) else { return nil }

            let iso = ISO8601DateFormatter()
            let stages: [[String: Any]] = chosen.compactMap { sample in
                guard let name = Self.stageNames[sample.value] else { return nil }
                return ["stage": name, "start": iso.string(from: sample.startDate), "end": iso.string(from: sample.endDate)]
            }
            guard !stages.isEmpty else { return nil }

            var item = base(
                kind: "sleep", start: start, end: stop, calendarDay: stop,
                final: stop < now.addingTimeInterval(-6 * 3600)
            )
            item["stages"] = stages
            item["sourceBundleId"] = chosen.first?.sourceRevision.source.bundleIdentifier
            return item
        }
    }

    /// How much a source said about a night: staged sleep counts most, then
    /// plain "asleep", then "in bed".
    private func detail(_ samples: [HKCategorySample]) -> Int {
        samples.reduce(0) { total, sample in
            switch sample.value {
            case 3, 4, 5: return total + 100
            case 1, 2: return total + 10
            default: return total + 1
            }
        }
    }

    // MARK: - Per-day sample kinds (HRV, respiration, blood oxygen)

    private func perDaySampleItems(
        kind: String,
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        scale: Double,
        from dayStart: Date,
        to end: Date
    ) async -> [Item] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let samples = await self.samples(type, from: dayStart, to: end).compactMap { $0 as? HKQuantitySample }
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.startDate) }
        let iso = ISO8601DateFormatter()

        return byDay.keys.sorted().compactMap { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  let daySamples = byDay[day] else { return nil }
            var item = base(kind: kind, start: day, end: next, calendarDay: day, final: isSettled(dayEnding: next))
            item["samples"] = daySamples
                .sorted { $0.startDate < $1.startDate }
                .map { ["t": iso.string(from: $0.startDate), "v": $0.quantity.doubleValue(for: unit) * scale] }
            return item
        }
    }

    // MARK: - VO₂max

    private func fitnessItems(from dayStart: Date, to end: Date) async -> [Item] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .vo2Max) else { return [] }
        let unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        let samples = await self.samples(type, from: dayStart, to: end).compactMap { $0 as? HKQuantitySample }
        let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.startDate) }

        return byDay.keys.sorted().compactMap { day in
            guard let latest = byDay[day]?.max(by: { $0.startDate < $1.startDate }),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            var item = base(kind: "fitness", start: day, end: nil, calendarDay: day, final: isSettled(dayEnding: next))
            item["vo2Max"] = latest.quantity.doubleValue(for: unit)
            return item
        }
    }

    // MARK: - Body composition

    private func bodyCompositionItems(from dayStart: Date, to end: Date) async -> [Item] {
        let fields: [(HKQuantityTypeIdentifier, HKUnit, Double, String)] = [
            (.bodyMass, .gramUnit(with: .kilo), 1, "weightKg"),
            (.bodyFatPercentage, .percent(), 100, "bodyFatPercent"),
            (.bodyMassIndex, .count(), 1, "bodyMassIndex"),
        ]

        // A smart scale writes weight and body fat as separate samples at the
        // same instant; they are one weigh-in.
        var byMinute: [Date: Item] = [:]
        for (id, unit, scale, key) in fields {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            for sample in await samples(type, from: dayStart, to: end).compactMap({ $0 as? HKQuantitySample }) {
                let minute = Date(timeIntervalSince1970: (sample.startDate.timeIntervalSince1970 / 60).rounded(.down) * 60)
                byMinute[minute, default: [:]][key] = sample.quantity.doubleValue(for: unit) * scale
            }
        }

        return byMinute.keys.sorted().compactMap { minute in
            guard let values = byMinute[minute] else { return nil }
            var item = base(kind: "body_composition", start: minute, end: nil, calendarDay: minute, final: true)
            item.merge(values) { _, new in new }
            return item
        }
    }

    // MARK: - Blood pressure

    private func bloodPressureItems(from dayStart: Date, to end: Date) async -> [Item] {
        guard let type = HKCorrelationType.correlationType(forIdentifier: .bloodPressure),
              let systolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)
        else { return [] }
        let unit = HKUnit.millimeterOfMercury()

        return await samples(type, from: dayStart, to: end)
            .compactMap { $0 as? HKCorrelation }
            .sorted { $0.startDate < $1.startDate }
            .compactMap { reading in
                let value = { (t: HKQuantityType) -> Double? in
                    (reading.objects(for: t).first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                }
                guard let systolic = value(systolicType), let diastolic = value(diastolicType) else { return nil }
                var item = base(
                    kind: "blood_pressure", start: reading.startDate, end: nil,
                    calendarDay: reading.startDate, final: true, id: reading.uuid.uuidString
                )
                item["systolic"] = systolic
                item["diastolic"] = diastolic
                return item
            }
    }

    // MARK: - Wrist temperature

    private func wristTemperatureItems(from dayStart: Date, to end: Date) async -> [Item] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) else { return [] }
        return await samples(type, from: dayStart, to: end)
            .compactMap { $0 as? HKQuantitySample }
            .sorted { $0.startDate < $1.startDate }
            .map { sample in
                var item = base(
                    kind: "skin_temperature", start: sample.startDate, end: sample.endDate,
                    calendarDay: sample.endDate, final: true, id: sample.uuid.uuidString
                )
                item["celsius"] = sample.quantity.doubleValue(for: .degreeCelsius())
                return item
            }
    }

    // MARK: - Helpers

    /// The fields every item carries.
    private func base(
        kind: String,
        start: Date,
        end: Date?,
        calendarDay: Date,
        final: Bool,
        id: String? = nil
    ) -> Item {
        let iso = ISO8601DateFormatter()
        var item: Item = [
            "kind": kind,
            "calendarDate": localDate(calendarDay),
            "startTime": iso.string(from: start),
            "tzOffsetSeconds": calendar.timeZone.secondsFromGMT(for: start),
            "final": final,
        ]
        if let end { item["endTime"] = iso.string(from: end) }
        if let id { item["id"] = id }
        return item
    }

    private func localDate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A day is settled once the day after it is over too: the watch syncs late,
    /// so yesterday's totals can still change this morning.
    private func isSettled(dayEnding dayEnd: Date) -> Bool {
        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        return dayEnd <= yesterday
    }

    private func samples(_ type: HKSampleType, from start: Date, to end: Date) async -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
