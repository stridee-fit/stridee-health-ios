import Foundation
import WorkoutKit
import os

/// Stridee → Apple Watch: the workouts your server pushes, scheduled in the
/// Workout app.
///
/// ```swift
/// // At launch, with the rest of the configuration:
/// HealthSync.configure(.init(tokenProvider: …, schedulesWorkouts: true))
///
/// // When the athlete turns on "Send workouts to my Apple Watch":
/// await HealthSync.shared.requestWorkoutSchedulingAuthorization()
/// ```
///
/// From there your server calls `POST /v1/workouts` as it would for a Garmin,
/// and the workout comes back with an `apple` push that is `pending`. On the
/// next sync — the app coming to the foreground, HealthKit waking it, or your
/// own call to ``HealthSync/syncScheduledWorkouts()`` — the SDK fetches it,
/// schedules it with WorkoutKit, and reports back, which turns the push
/// `synced`. Edits replace the scheduled workout; deletes take it off.
///
/// Apple has no server API for this, which is why it happens here: WorkoutKit
/// runs on the phone, and the Workout app carries what it schedules to the
/// paired watch.
extension HealthSync {

    /// Whether this device can schedule workouts at all. `false` on an iPad
    /// and in the simulator.
    public nonisolated var isWorkoutSchedulingSupported: Bool { WorkoutScheduler.isSupported }

    /// Whether the athlete lets your app add workouts to the Workout app,
    /// asked of WorkoutKit now. Also kept on ``Status/workoutScheduling``.
    @discardableResult
    public func workoutSchedulingAuthorization() async -> WorkoutSchedulingAuthorization {
        let authorization = await Self.schedulingAuthorization()
        status.workoutScheduling.authorization = authorization
        return authorization
    }

    /// Ask the athlete to let your app add workouts to the Workout app.
    ///
    /// iOS shows its own sheet the first time and never again, so call this
    /// from the screen where they turn the feature on, not at launch. Once
    /// they allow it, their Apple connection becomes a device your server can
    /// push workouts to, and anything already pushed is scheduled right away.
    ///
    /// If they refuse, only they can change it, in Settings —
    /// ``HealthSync/openSettings()``.
    @discardableResult
    public func requestWorkoutSchedulingAuthorization() async -> WorkoutSchedulingAuthorization {
        let authorization: WorkoutSchedulingAuthorization
        if WorkoutScheduler.isSupported {
            authorization = Self.map(await WorkoutScheduler.shared.requestAuthorization())
        } else {
            authorization = .unsupported
        }
        status.workoutScheduling.authorization = authorization
        if state.isConnected {
            Task { try? await self.syncScheduledWorkouts() }
        }
        return authorization
    }

    /// Make the watch match what your server has pushed.
    ///
    /// Runs as part of every ``syncNow()``. Call it yourself when you know
    /// something changed — after your server creates a workout for this user,
    /// say, or when a silent push tells the app to look — so the workout is on
    /// the watch now rather than at the next sync. Does nothing unless
    /// ``Configuration/schedulesWorkouts`` is on.
    public func syncScheduledWorkouts() async throws {
        if let error = await runScheduleSync() { throw error }
    }

    // MARK: - The pass

    /// One scheduling pass. Concurrent callers share it.
    func runScheduleSync() async -> HealthSyncError? {
        if let running = scheduleSync { return await running.value }
        let task = Task { await self.performScheduleSync() }
        scheduleSync = task
        let error = await task.value
        scheduleSync = nil
        return error
    }

    private func performScheduleSync() async -> HealthSyncError? {
        guard let configuration, let api else { return .notConfigured }
        guard configuration.schedulesWorkouts else { return nil }
        guard state.isConnected else { return .notConnected }
        guard WorkoutScheduler.isSupported else {
            status.workoutScheduling.authorization = .unsupported
            return nil
        }

        let error = await reconcile(api)
        // Disconnected mid-pass: the status was already reset.
        guard state.isConnected else { return error }
        status.workoutScheduling.lastError = error
        if error == nil { status.workoutScheduling.lastSyncDate = Date() }
        return error
    }

    private func reconcile(_ api: APIClient) async -> HealthSyncError? {
        let scheduler = WorkoutScheduler.shared
        do {
            // Tell the API whether this device can schedule, when that changes.
            // It is what makes the athlete's Apple connection a device your
            // server can push to, and what stops it being one.
            let authorization = Self.map(await scheduler.authorizationState)
            status.workoutScheduling.authorization = authorization
            if state.declaredScheduling != authorization.rawValue {
                if try await api.putWorkoutScheduling(authorization: authorization.rawValue) == .notConnected {
                    markDisconnectedRemotely()
                    return .disconnectedRemotely
                }
                state.declaredScheduling = authorization.rawValue
            }

            let items: [ScheduledItem]
            switch try await api.scheduledWorkouts() {
            case .notConnected:
                markDisconnectedRemotely()
                return .disconnectedRemotely
            case .workouts(let listed):
                items = listed
            }

            guard authorization == .authorized else {
                // Say once, per workout, that it is waiting on the athlete, so
                // the developer reads `not_permitted` rather than a `pending`
                // that never moves.
                for item in items where !(item.status == "failed" && item.reason == "not_permitted") {
                    _ = try await api.reportScheduledWorkout(
                        id: item.id, revision: item.revision, outcome: "not_permitted", error: nil
                    )
                }
                status.workoutScheduling.waitingCount = items.count
                return nil
            }

            var managed = state.managedPlans
            let scheduled = await scheduler.scheduledWorkouts
            let pass = SchedulePlanner.plan(
                items: items,
                managed: managed,
                onWatch: Set(scheduled.map(\.plan.id)),
                capacity: WorkoutScheduler.maxAllowedScheduledWorkoutCount,
                today: Self.dayString(Date())
            )

            // Removals first: they are what makes room for the rest.
            for entry in scheduled where pass.toRemove.contains(entry.plan.id) {
                await scheduler.remove(entry.plan, at: entry.date)
            }
            for id in pass.toRemove { managed[id] = nil }
            state.managedPlans = managed

            // On the watch already, but the API has not heard: a report that
            // did not get through last time.
            for item in pass.inPlace where item.status != "synced" {
                _ = try await api.reportScheduledWorkout(
                    id: item.id, revision: item.revision, outcome: "synced", error: nil
                )
            }

            for item in pass.toSchedule {
                // Whatever is there under this id is an older version, or a copy
                // from before a reinstall. It goes either way.
                for entry in scheduled where entry.plan.id == item.planId {
                    await scheduler.remove(entry.plan, at: entry.date)
                }
                managed[item.planId] = nil
                state.managedPlans = managed

                let plan: WorkoutPlan
                do {
                    plan = try WorkoutPlanBuilder.plan(for: item)
                } catch let refusal as WorkoutPlanBuilder.Unsupported {
                    log.notice("workout \(item.id, privacy: .public) cannot be scheduled: \(refusal.reason, privacy: .public)")
                    _ = try await api.reportScheduledWorkout(
                        id: item.id, revision: item.revision, outcome: "unsupported", error: refusal.reason
                    )
                    continue
                }
                guard let components = Self.scheduleComponents(for: item.scheduledDate) else {
                    _ = try await api.reportScheduledWorkout(
                        id: item.id, revision: item.revision, outcome: "failed",
                        error: "Unreadable date `\(item.scheduledDate)`"
                    )
                    continue
                }

                await scheduler.schedule(plan, at: components)

                // `schedule` returns nothing, so the outcome reported is read
                // back rather than assumed.
                if await scheduler.scheduledWorkouts.contains(where: { $0.plan.id == item.planId }) {
                    managed[item.planId] = ManagedPlan(
                        workoutId: item.id, revision: item.revision, date: item.scheduledDate
                    )
                    state.managedPlans = managed
                    _ = try await api.reportScheduledWorkout(
                        id: item.id, revision: item.revision, outcome: "synced", error: nil
                    )
                } else {
                    log.error("WorkoutKit did not keep workout \(item.id, privacy: .public)")
                    _ = try await api.reportScheduledWorkout(
                        id: item.id, revision: item.revision, outcome: "failed",
                        error: "WorkoutKit did not keep the scheduled workout"
                    )
                }
            }

            status.workoutScheduling.scheduledCount = managed.count
            status.workoutScheduling.waitingCount = pass.waiting.count
            return nil
        } catch let error as HealthSyncError {
            return error
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    /// Take everything this SDK scheduled off the watch — on disconnect, when
    /// the workouts stop being this user's to see.
    func removeScheduledWorkouts() async {
        let managed = state.managedPlans
        guard !managed.isEmpty else { return }
        if WorkoutScheduler.isSupported {
            let scheduler = WorkoutScheduler.shared
            for entry in await scheduler.scheduledWorkouts where managed[entry.plan.id] != nil {
                await scheduler.remove(entry.plan, at: entry.date)
            }
        }
        state.managedPlans = [:]
    }

    // MARK: - Authorization and dates

    static func schedulingAuthorization() async -> WorkoutSchedulingAuthorization {
        guard WorkoutScheduler.isSupported else { return .unsupported }
        return map(await WorkoutScheduler.shared.authorizationState)
    }

    static func map(_ state: WorkoutScheduler.AuthorizationState) -> WorkoutSchedulingAuthorization {
        switch state {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// The athlete's local day, `yyyy-MM-dd` — the form the API lists days in,
    /// so the two compare as strings.
    nonisolated static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// When to schedule a workout listed for `day`.
    ///
    /// The start of that day, in the athlete's own calendar. A workout for
    /// *today* would then be in the past, and WorkoutKit does not surface one
    /// scheduled into the past — so today's is scheduled a couple of minutes
    /// from now instead, which is what puts it on the watch.
    nonisolated static func scheduleComponents(
        for day: String, now: Date = Date(), calendar: Calendar = .current
    ) -> DateComponents? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 0
        components.minute = 0
        guard let start = calendar.date(from: components) else { return nil }
        if start <= now {
            return calendar.dateComponents(fields, from: now.addingTimeInterval(120))
        }
        return calendar.dateComponents(fields, from: start)
    }
}
