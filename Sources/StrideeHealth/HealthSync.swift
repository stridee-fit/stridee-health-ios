import Foundation
import HealthKit
import UIKit
import os

/// Apple Health → Stridee, from inside your app.
///
/// ```swift
/// // application(_:didFinishLaunchingWithOptions:) — every launch, including
/// // the background ones HealthKit makes to deliver new data.
/// HealthSync.configure(.init(tokenProvider: { try await MyAPI.strideeDeviceToken() }))
///
/// // When the athlete taps "Connect Apple Health":
/// try await HealthSync.shared.connect()
/// ```
///
/// From there it runs itself. HealthKit wakes the app when a workout or a night
/// of sleep is written; the SDK reads what is new, queues it on disk, and
/// uploads it with a device token your server minted. Coming back to the
/// foreground syncs too. Your backend hears about it on its webhook —
/// `activity.created` for workouts, `wellness.created` / `wellness.updated`
/// for the rest — exactly as for any other provider.
///
/// It works the other way too. With ``Configuration/schedulesWorkouts`` on,
/// the workouts your server creates with `POST /v1/workouts` are put on the
/// athlete's Apple Watch — see `WorkoutSchedule.swift`.
@MainActor
public final class HealthSync: ObservableObject {
    public static let shared = HealthSync()

    /// Where syncing stands. Observe it for a settings screen.
    @Published public internal(set) var status = Status()

    /// Configure the SDK. Call it from
    /// `application(_:didFinishLaunchingWithOptions:)` on **every** launch:
    /// HealthKit's background delivery relaunches the app and only delivers to
    /// observers registered before launch finishes.
    public static func configure(_ configuration: Configuration) {
        shared.configure(configuration)
    }

    /// Whether HealthKit exists on this device at all.
    public nonisolated var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let queue = UploadQueue()
    let state = SyncState()
    let log = Logger(subsystem: "fit.stridee.health", category: "sync")

    private(set) var configuration: Configuration?
    private var tokens: TokenStore?
    private(set) var api: APIClient?
    /// The scheduling pass in flight, if any. See `WorkoutSchedule.swift`.
    var scheduleSync: Task<HealthSyncError?, Never>?
    private var observers: [HKObserverQuery] = []
    private var currentSync: Task<HealthSyncError?, Never>?
    private var resyncRequested = false
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    private func configure(_ configuration: Configuration) {
        self.configuration = configuration
        let tokens = TokenStore(provider: configuration.tokenProvider)
        self.tokens = tokens
        self.api = APIClient(baseURL: configuration.baseURL, tokens: tokens)

        if let legacyKey = configuration.importWorkoutAnchorFromUserDefaultsKey {
            state.importWorkoutAnchor(fromUserDefaultsKey: legacyKey)
        }

        status.isConnected = state.isConnected
        status.lastSyncDate = state.lastSyncDate
        status.pendingUploads = queue.count
        status.lastDataFound = state.lastDataFound
        status.workoutScheduling.scheduledCount = state.managedPlans.count
        Task { _ = await self.authorizationStatus() }
        if configuration.schedulesWorkouts {
            Task { await self.workoutSchedulingAuthorization() }
        }

        if state.isConnected {
            // Registered synchronously, before launch finishes — the whole
            // reason `configure` belongs in `didFinishLaunching`.
            startObserving()
            Task { await self.confirmConnection() }
        }

        if state.pendingRemoteDisconnect, let api {
            Task {
                if (try? await api.deleteConnection()) != nil { self.state.pendingRemoteDisconnect = false }
            }
        }

        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state.isConnected else { return }
                    try? await self.syncNow()
                }
            }
        }
    }

    // MARK: - Permissions

    /// Where the permission flow stands, asked of HealthKit now. Also kept on
    /// ``Status/authorization``.
    ///
    /// Never `granted` or `denied` — iOS does not say. See
    /// ``AuthorizationStatus``.
    @discardableResult
    public func authorizationStatus() async -> AuthorizationStatus {
        let result: AuthorizationStatus
        if !isHealthDataAvailable {
            result = .unavailable
        } else if let configuration {
            let types = Self.readTypes(for: configuration.dataTypes)
            let answered: Bool = await withCheckedContinuation { continuation in
                store.getRequestStatusForAuthorization(toShare: [], read: types) { status, _ in
                    continuation.resume(returning: status == .unnecessary)
                }
            }
            result = answered ? .requested : .notRequested
        } else {
            result = .notRequested
        }
        status.authorization = result
        return result
    }

    /// Whether ``connect()`` would show the HealthKit permission sheet.
    ///
    /// `false` once the athlete has answered for every type this configuration
    /// reads — in this install or a previous one.
    public func needsAuthorization() async -> Bool {
        await authorizationStatus() != .requested
    }

    /// Show the HealthKit permission sheet without connecting.
    ///
    /// For an app that asks during onboarding and connects later, or that
    /// added wellness to ``Configuration/dataTypes`` and needs to ask for the
    /// new types. iOS shows the sheet only for types never asked about, so
    /// calling this again is harmless — it returns at once.
    ///
    /// Returning normally means the user answered, not that they allowed
    /// anything: see ``AuthorizationStatus``.
    ///
    /// - Parameter dataTypes: What to ask for. Defaults to
    ///   ``Configuration/dataTypes``.
    public func requestAuthorization(for dataTypes: Set<DataType>? = nil) async throws {
        guard isHealthDataAvailable else { throw HealthSyncError.healthDataUnavailable }
        guard let configuration else { throw HealthSyncError.notConfigured }
        try await store.requestAuthorization(
            toShare: [], read: Self.readTypes(for: dataTypes ?? configuration.dataTypes)
        )
        await authorizationStatus()
    }

    /// Open your app's page in the Settings app.
    ///
    /// The nearest place iOS lets an app send someone to change its Health
    /// access: there is no link straight to the Health switches. On recent iOS
    /// versions the page lists Health; otherwise the switches are at
    /// Settings → Health → Data Access & Devices → your app. Say which in the
    /// sentence around the button.
    @discardableResult
    public func openSettings() async -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        return await UIApplication.shared.open(url)
    }

    // MARK: - Connecting

    /// Ask for HealthKit access, connect this user, and start syncing.
    ///
    /// Shows the permission sheet for anything not yet asked about, then tells
    /// the API this user is connected — your webhook gets `account.connected`
    /// the first time — and runs the first sync, which sends workout history
    /// in full and ``Configuration/wellnessHistoryDays`` of wellness. Returns
    /// once connected; the first sync carries on in the background.
    ///
    /// - Parameter requestingAuthorization: `false` connects without showing
    ///   the sheet, for an app that already holds HealthKit access and is
    ///   moving onto the SDK. Types never granted simply return no data.
    public func connect(requestingAuthorization: Bool = true) async throws {
        guard isHealthDataAvailable else { throw HealthSyncError.healthDataUnavailable }
        guard let configuration, let api else { throw HealthSyncError.notConfigured }

        if requestingAuthorization {
            try await requestAuthorization(for: configuration.dataTypes)
        }

        _ = try await api.putConnection()

        state.pendingRemoteDisconnect = false
        // A new connection knows nothing about this device: tell it again
        // whether workouts can be scheduled here.
        state.declaredScheduling = nil
        state.isConnected = true
        status.isConnected = true
        status.lastError = nil
        startObserving()

        Task { try? await self.syncNow() }
    }

    /// Stop syncing and disconnect this user.
    ///
    /// Stops observing HealthKit, drops anything still queued, and forgets this
    /// device's progress so a later ``connect()`` starts from the full history.
    /// Workouts this SDK scheduled on the watch are taken off it.
    ///
    /// - Parameter revokeOnServer: `true` (the default) also disconnects the
    ///   user on the Stridee API — your webhook gets `account.disconnected` and
    ///   their device tokens stop working. Pass `false` to stop only this
    ///   device, for example when the user signs out of your app; their
    ///   connection stays, and connecting again later is seamless. A server
    ///   disconnect that cannot reach the API is retried at the next launch.
    public func disconnect(revokeOnServer: Bool = true) async {
        stopObserving()
        currentSync?.cancel()
        scheduleSync?.cancel()
        queue.removeAll()
        state.reset()
        await removeScheduledWorkouts()
        status = Status()

        if revokeOnServer, let api {
            do {
                _ = try await api.deleteConnection()
            } catch {
                state.pendingRemoteDisconnect = true
            }
        }
        await tokens?.clear()
    }

    /// Ask the API whether this user is still connected; stop if not.
    private func confirmConnection() async {
        guard let api, state.isConnected else { return }
        if (try? await api.getConnection()) == .notConnected {
            markDisconnectedRemotely()
        }
    }

    func markDisconnectedRemotely() {
        log.notice("disconnected on the server; stopping")
        stopObserving()
        queue.removeAll()
        state.reset()
        status.isConnected = false
        status.pendingUploads = 0
        status.lastError = .disconnectedRemotely
        // Their workouts stop being ours to keep on the watch.
        Task { await self.removeScheduledWorkouts() }
    }

    // MARK: - Syncing

    /// Read what is new from HealthKit and upload everything queued.
    ///
    /// Safe to call at any time and from anywhere: concurrent calls share one
    /// sync, and a call made while one is running schedules another right after
    /// it. Throws what stopped it, which is also on ``status``.
    public func syncNow() async throws {
        if let running = currentSync {
            resyncRequested = true
            if let error = await running.value { throw error }
            return
        }

        let task = Task { () -> HealthSyncError? in
            var error: HealthSyncError?
            repeat {
                resyncRequested = false
                error = await performSync()
            } while resyncRequested && error == nil && !Task.isCancelled
            return error
        }
        currentSync = task
        let error = await task.value
        currentSync = nil
        if let error { throw error }
    }

    private func performSync() async -> HealthSyncError? {
        guard let configuration, let api else { return .notConfigured }
        guard state.isConnected else { return .notConnected }
        guard isHealthDataAvailable else { return .healthDataUnavailable }

        status.isSyncing = true
        // Finish the upload if the app is backgrounded mid-sync.
        let background = UIApplication.shared.beginBackgroundTask(withName: "StrideeHealth sync")
        defer {
            status.isSyncing = false
            status.progress = nil
            status.pendingUploads = queue.count
            UIApplication.shared.endBackgroundTask(background)
        }

        if configuration.dataTypes.contains(.workouts) {
            await collectWorkouts(configuration)
        }
        if configuration.dataTypes.contains(.wellness) {
            await collectWellness(configuration)
        }

        let error = await drain(api)
        // Disconnected mid-sync: `disconnect` already reset the status.
        guard state.isConnected else { return error }
        if let error {
            status.lastError = error
        } else {
            let now = Date()
            state.lastSyncDate = now
            status.lastSyncDate = now
            status.lastError = nil
        }

        // The other direction, last: nothing here waits on HealthKit, and a
        // failed upload is no reason to leave the watch out of date. Its own
        // failure is kept on `status.workoutScheduling`, not on `lastError`,
        // which is about what was read and sent.
        let scheduleError = configuration.schedulesWorkouts ? await runScheduleSync() : nil
        return error ?? scheduleError
    }

    /// Queue every workout added since the anchor, then advance it. Safe to
    /// advance before uploading: the queue is on disk.
    private func collectWorkouts(_ configuration: Configuration) async {
        let (workouts, anchor) = await fetchWorkouts(after: state.workoutAnchor)
        let exporter = WorkoutExporter(store: store)

        for workout in workouts {
            let source = workout.sourceRevision.source.bundleIdentifier
            if configuration.excludedSourceBundleIDs.contains(source) { continue }
            // Off the main actor: a long ride's route is a lot of JSON.
            let exported = await Task.detached { await exporter.export(workout) }.value
            guard let exported else {
                log.error("could not serialise workout \(workout.uuid, privacy: .public)")
                continue
            }
            // Disconnected while this was exporting: write nothing, or a later
            // connect would resume from an anchor that skips the history.
            guard state.isConnected else { return }
            queue.enqueue(exported.rawData, kind: .workout, key: exported.externalId)
        }
        guard state.isConnected else { return }
        if let anchor { state.workoutAnchor = anchor }
        if !workouts.isEmpty { recordDataFound(.workouts) }
    }

    private func fetchWorkouts(after anchor: HKQueryAnchor?) async -> ([HKWorkout], HKQueryAnchor?) {
        await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(), predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, _ in
                let workouts = (samples as? [HKWorkout] ?? []).sorted { $0.startDate < $1.startDate }
                continuation.resume(returning: (workouts, newAnchor))
            }
            store.execute(query)
        }
    }

    /// Items per wellness upload. Well inside the API's 2,000 and 10 MB.
    private static let wellnessBatchSize = 500

    /// Collect wellness from a little before where the last collection ended,
    /// so the late-arriving tail of yesterday is re-sent.
    ///
    /// Skipped while a wellness batch is still waiting to upload: collecting
    /// again would only queue a second copy of the same days. The window is
    /// remembered, so the next collection after the queue drains covers the gap.
    private func collectWellness(_ configuration: Configuration) async {
        if queue.items().contains(where: { $0.kind == .wellness }) { return }

        let now = Date()
        let calendar = Calendar.current
        let start: Date
        if let through = state.wellnessCollectedThrough {
            start = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: through)) ?? through
        } else {
            start = calendar.date(byAdding: .day, value: -configuration.wellnessHistoryDays, to: now) ?? now
        }

        let collector = WellnessCollector(store: store)
        let items = await Task.detached { await collector.collect(from: start, to: now) }.value
        // Disconnected while collecting: see `collectWorkouts`.
        guard state.isConnected else { return }
        if !items.isEmpty { recordDataFound(.wellness) }

        var offset = 0
        while offset < items.count {
            let batch = Array(items[offset..<min(offset + Self.wellnessBatchSize, items.count)])
            offset += Self.wellnessBatchSize
            let envelope: [String: Any] = ["format": "healthkit.wellness.v1", "items": batch]
            guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
                log.error("could not serialise a wellness batch")
                return
            }
            queue.enqueue(body, kind: .wellness, key: UUID().uuidString)
        }
        state.wellnessCollectedThrough = now
    }

    private func recordDataFound(_ type: DataType) {
        var found = state.lastDataFound
        found[type] = Date()
        state.lastDataFound = found
        status.lastDataFound = found
    }

    /// Upload the queue, oldest first, until it is empty or something stops it.
    ///
    /// A payload the API refuses as invalid (400, 413) is dropped — sending it
    /// again cannot succeed, and keeping it would block everything behind it.
    /// A transport or token failure stops the drain and leaves the rest for the
    /// next sync.
    private func drain(_ api: APIClient) async -> HealthSyncError? {
        let items = queue.items()
        guard !items.isEmpty else { return nil }

        var dropped: HealthSyncError?
        for (index, item) in items.enumerated() {
            status.progress = .init(done: index, total: items.count)
            guard let body = queue.body(of: item) else {
                queue.remove(item)
                continue
            }
            do {
                let outcome: APIClient.Outcome
                switch item.kind {
                case .workout: outcome = try await api.uploadWorkout(body)
                case .wellness: outcome = try await api.uploadWellness(body)
                }
                if outcome == .notConnected {
                    markDisconnectedRemotely()
                    return .disconnectedRemotely
                }
                queue.remove(item)
            } catch let error as HealthSyncError {
                if case .rejected(let code, _) = error, code == 400 || code == 413 {
                    log.error("API refused a queued \(item.kind.rawValue, privacy: .public); dropping it")
                    queue.remove(item)
                    dropped = error
                    continue
                }
                return error
            } catch {
                return .transport(error.localizedDescription)
            }
            status.pendingUploads = queue.count
        }
        return dropped
    }

    // MARK: - Background delivery

    /// Register an observer per type worth waking for, with background delivery.
    ///
    /// Workouts wake immediately. Wellness wakes at most hourly — Apple caps
    /// several of these types there anyway, and a sync re-collects every kind,
    /// so observing sleep, HRV and steps is enough to pick up the rest.
    private func startObserving() {
        guard observers.isEmpty, isHealthDataAvailable, let configuration else { return }

        var watched: [(HKSampleType, HKUpdateFrequency)] = []
        if configuration.dataTypes.contains(.workouts) {
            watched.append((HKObjectType.workoutType(), .immediate))
        }
        if configuration.dataTypes.contains(.wellness) {
            if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { watched.append((t, .hourly)) }
            if let t = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { watched.append((t, .hourly)) }
            if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { watched.append((t, .hourly)) }
        }

        for (type, frequency) in watched {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil, let self else {
                    completion()
                    return
                }
                // HealthKit waits for `completion` before it considers the
                // update delivered, and backs off an app that never calls it.
                Task { @MainActor in
                    try? await self.syncNow()
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: frequency) { [log] ok, error in
                if !ok {
                    log.error("background delivery refused for \(type.identifier, privacy: .public): \(String(describing: error), privacy: .public) — is the HealthKit Background Delivery entitlement set?")
                }
            }
        }
    }

    private func stopObserving() {
        for query in observers { store.stop(query) }
        observers.removeAll()
        store.disableAllBackgroundDelivery { _, _ in }
    }

    // MARK: - What is read

    /// The HealthKit types each data type needs. Read-only: the SDK never
    /// writes to HealthKit.
    static func readTypes(for dataTypes: Set<DataType>) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        func quantity(_ ids: [HKQuantityTypeIdentifier]) {
            for id in ids {
                if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
            }
        }

        if dataTypes.contains(.workouts) {
            types.insert(HKObjectType.workoutType())
            types.insert(HKSeriesType.workoutRoute())
            quantity([
                .heartRate, .activeEnergyBurned,
                .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                .runningPower, .cyclingPower, .cyclingCadence,
            ])
        }

        if dataTypes.contains(.wellness) {
            quantity([
                .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .basalEnergyBurned,
                .flightsClimbed, .appleExerciseTime, .restingHeartRate, .heartRate,
                .heartRateVariabilitySDNN, .vo2Max, .respiratoryRate, .oxygenSaturation,
                .bodyMass, .bodyFatPercentage, .bodyMassIndex,
                .bloodPressureSystolic, .bloodPressureDiastolic,
                .appleSleepingWristTemperature,
            ])
            if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        }

        return types
    }
}
