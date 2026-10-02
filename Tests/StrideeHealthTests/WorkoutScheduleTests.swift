import XCTest
@testable import StrideeHealth

final class WorkoutScheduleTests: XCTestCase {

    // MARK: - The document

    private let listing = """
    {
      "workouts": [{
        "id": "7b1f6f0e-52a8-4b53-9a53-0d6f1c7b9e21",
        "plan_id": "7b1f6f0e-52a8-4b53-9a53-0d6f1c7b9e21",
        "revision": "2026-10-02T09:15:04.123456Z",
        "scheduled_date": "2026-10-05",
        "status": "pending",
        "workout": {
          "format": "workoutkit.v1",
          "activity": "running",
          "location": "outdoor",
          "displayName": "6 × 800 m",
          "warmup": { "purpose": "work", "goal": { "type": "time", "seconds": 600 } },
          "blocks": [{
            "iterations": 6,
            "steps": [
              { "purpose": "work",
                "goal": { "type": "distance", "value": 800, "unit": "meters" },
                "alert": { "type": "speedRange", "low": 4.444, "high": 4.762, "metric": "average" },
                "displayName": "Hard" },
              { "purpose": "recovery", "goal": { "type": "open" },
                "alert": { "type": "heartRateZone", "zone": 2 } }
            ]
          }],
          "cooldown": { "purpose": "recovery", "goal": { "type": "energy", "kilocalories": 50 } }
        }
      }]
    }
    """

    func testAListingDecodes() throws {
        let items = try JSONDecoder().decode(ScheduledWorkoutsResponse.self, from: Data(listing.utf8)).workouts
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(item.planId, UUID(uuidString: "7B1F6F0E-52A8-4B53-9A53-0D6F1C7B9E21"))
        // Echoed in the report exactly as it came, so it stays a string.
        XCTAssertEqual(item.revision, "2026-10-02T09:15:04.123456Z")
        XCTAssertNil(item.reason)

        let workout = item.workout
        XCTAssertEqual(workout.warmup?.goal, .time(seconds: 600))
        XCTAssertEqual(workout.cooldown?.goal, .energy(kilocalories: 50))
        XCTAssertEqual(workout.blocks.first?.iterations, 6)

        let hard = try XCTUnwrap(workout.blocks.first?.steps.first)
        XCTAssertEqual(hard.goal, .distance(value: 800, unit: "meters"))
        XCTAssertEqual(hard.alert, .speedRange(low: 4.444, high: 4.762, averaged: true))
        XCTAssertEqual(hard.displayName, "Hard")
        XCTAssertEqual(workout.blocks.first?.steps.last?.alert, .heartRateZone(2))
    }

    func testAKindThisVersionDoesNotKnowDecodesRatherThanFailing() throws {
        let json = """
        { "purpose": "work",
          "goal": { "type": "poolSwimDistanceWithTime", "meters": 100, "seconds": 110 },
          "alert": { "type": "strokeRate", "low": 30, "high": 34 } }
        """
        let step = try JSONDecoder().decode(WorkoutDocument.Step.self, from: Data(json.utf8))
        XCTAssertEqual(step.goal, .unknown("poolSwimDistanceWithTime"))
        XCTAssertEqual(step.alert, .unknown("strokeRate"))
    }

    // MARK: - The pass

    private func item(_ n: Int, on date: String, revision: String = "r1") -> ScheduledItem {
        ScheduledItem(
            id: "w\(n)",
            planId: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            revision: revision,
            scheduledDate: date,
            status: "pending",
            reason: nil,
            workout: WorkoutDocument(
                format: "workoutkit.v1", activity: "running", location: "outdoor",
                displayName: "W\(n)", warmup: nil, blocks: [], cooldown: nil
            )
        )
    }

    private func managed(_ item: ScheduledItem) -> ManagedPlan {
        ManagedPlan(workoutId: item.id, revision: item.revision, date: item.scheduledDate)
    }

    func testTheSoonestWorkoutsTakeTheRoomThereIs() {
        let items = [item(1, on: "2026-10-02"), item(2, on: "2026-10-03"), item(3, on: "2026-10-04")]
        let pass = SchedulePlanner.plan(items: items, managed: [:], onWatch: [], capacity: 2, today: "2026-10-02")

        XCTAssertEqual(pass.toSchedule, [items[0], items[1]])
        XCTAssertEqual(pass.waiting, [items[2]])
        XCTAssertTrue(pass.toRemove.isEmpty)
    }

    func testTheAppsOwnPlansKeepTheirSlots() {
        let items = [item(1, on: "2026-10-02"), item(2, on: "2026-10-03")]
        let theirs = UUID()
        let pass = SchedulePlanner.plan(items: items, managed: [:], onWatch: [theirs], capacity: 2, today: "2026-10-02")

        XCTAssertEqual(pass.toSchedule, [items[0]])
        XCTAssertEqual(pass.waiting, [items[1]])
        XCTAssertFalse(pass.toRemove.contains(theirs))
    }

    func testAnUnchangedWorkoutIsLeftAlone() {
        let a = item(1, on: "2026-10-03")
        let pass = SchedulePlanner.plan(
            items: [a], managed: [a.planId: managed(a)], onWatch: [a.planId], capacity: 5, today: "2026-10-02"
        )
        XCTAssertEqual(pass.inPlace, [a])
        XCTAssertTrue(pass.toSchedule.isEmpty)
    }

    func testAnEditedOrMovedWorkoutIsScheduledAgain() {
        let was = item(1, on: "2026-10-03")
        let edited = item(1, on: "2026-10-03", revision: "r2")
        let moved = item(1, on: "2026-10-04")
        for now in [edited, moved] {
            let pass = SchedulePlanner.plan(
                items: [now], managed: [was.planId: managed(was)], onWatch: [was.planId], capacity: 5, today: "2026-10-02"
            )
            XCTAssertEqual(pass.toSchedule, [now])
        }
    }

    func testWhatIsNoLongerListedComesOffTheWatch() {
        let gone = item(1, on: "2026-10-03")
        let pass = SchedulePlanner.plan(
            items: [], managed: [gone.planId: managed(gone)], onWatch: [gone.planId], capacity: 5, today: "2026-10-02"
        )
        XCTAssertEqual(pass.toRemove, [gone.planId])
    }

    func testAPlanFromBeforeAReinstallIsAdoptedNotCountedAsTheApps() {
        // On the watch under the API's id, but this install has no record of it.
        let a = item(1, on: "2026-10-03")
        let pass = SchedulePlanner.plan(items: [a], managed: [:], onWatch: [a.planId], capacity: 1, today: "2026-10-02")
        XCTAssertEqual(pass.toSchedule, [a])
    }

    func testAPastWorkoutIsKeptIfThereButNeverAddedLate() {
        let yesterday = item(1, on: "2026-10-01")

        let kept = SchedulePlanner.plan(
            items: [yesterday], managed: [yesterday.planId: managed(yesterday)],
            onWatch: [yesterday.planId], capacity: 5, today: "2026-10-02"
        )
        XCTAssertEqual(kept.inPlace, [yesterday])

        let late = SchedulePlanner.plan(items: [yesterday], managed: [:], onWatch: [], capacity: 5, today: "2026-10-02")
        XCTAssertTrue(late.toSchedule.isEmpty && late.waiting.isEmpty)
    }

    func testAFartherWorkoutGivesUpItsSlotToASoonerOne() {
        let far = item(2, on: "2026-10-09")
        let soon = item(1, on: "2026-10-02")
        let pass = SchedulePlanner.plan(
            items: [soon, far], managed: [far.planId: managed(far)], onWatch: [far.planId], capacity: 1, today: "2026-10-02"
        )
        XCTAssertEqual(pass.toSchedule, [soon])
        XCTAssertEqual(pass.toRemove, [far.planId])
        XCTAssertEqual(pass.waiting, [far])
    }

    // MARK: - Dates

    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    func testAFutureDayIsScheduledAtItsStart() throws {
        let now = try XCTUnwrap(zurich.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 30)))
        let components = try XCTUnwrap(HealthSync.scheduleComponents(for: "2026-10-05", now: now, calendar: zurich))
        XCTAssertEqual([components.year, components.month, components.day, components.hour, components.minute], [2026, 10, 5, 0, 0])
    }

    func testTodayIsScheduledAMomentFromNowSoTheWatchShowsIt() throws {
        let now = try XCTUnwrap(zurich.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 30)))
        let components = try XCTUnwrap(HealthSync.scheduleComponents(for: "2026-10-02", now: now, calendar: zurich))
        XCTAssertEqual([components.year, components.month, components.day, components.hour, components.minute], [2026, 10, 2, 14, 32])
        XCTAssertEqual(HealthSync.dayString(now, calendar: zurich), "2026-10-02")
    }

    func testAnUnreadableDayIsRefused() {
        XCTAssertNil(HealthSync.scheduleComponents(for: "next tuesday"))
    }

    // MARK: - What is remembered

    func testManagedPlansSurviveAResetUntilTheyAreRemoved() {
        let state = SyncState(defaults: UserDefaults(suiteName: "WorkoutScheduleTests.\(UUID().uuidString)")!)
        let a = item(1, on: "2026-10-03")
        state.managedPlans = [a.planId: managed(a)]
        state.declaredScheduling = "authorized"

        state.reset()

        // Still on a watch, so still known; the declaration belongs to the
        // connection that just ended.
        XCTAssertEqual(state.managedPlans, [a.planId: managed(a)])
        XCTAssertNil(state.declaredScheduling)

        state.managedPlans = [:]
        XCTAssertTrue(state.managedPlans.isEmpty)
    }
}
