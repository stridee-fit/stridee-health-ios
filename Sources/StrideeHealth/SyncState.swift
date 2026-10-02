import Foundation
import HealthKit

/// What the SDK remembers between launches. Small and non-secret, so
/// `UserDefaults`; the token lives in the Keychain and uploads in
/// ``UploadQueue``.
struct SyncState {
    private let defaults: UserDefaults
    private static let prefix = "fit.stridee.health."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ name: String) -> String { Self.prefix + name }

    /// This device is connected and should sync.
    var isConnected: Bool {
        get { defaults.bool(forKey: key("connected")) }
        nonmutating set { defaults.set(newValue, forKey: key("connected")) }
    }

    /// A disconnect that could not reach the API, to retry at the next launch.
    var pendingRemoteDisconnect: Bool {
        get { defaults.bool(forKey: key("pendingRemoteDisconnect")) }
        nonmutating set { defaults.set(newValue, forKey: key("pendingRemoteDisconnect")) }
    }

    var lastSyncDate: Date? {
        get { date("lastSyncDate") }
        nonmutating set { setDate(newValue, "lastSyncDate") }
    }

    /// Wellness has been collected up to here. The next sync re-collects from a
    /// couple of days before it, because a watch writes yesterday late.
    var wellnessCollectedThrough: Date? {
        get { date("wellnessCollectedThrough") }
        nonmutating set { setDate(newValue, "wellnessCollectedThrough") }
    }

    /// When a sync last found new data in HealthKit, per data type. What an
    /// app reads to tell "connected and working" from "connected, but HealthKit
    /// is handing us nothing" — which, since iOS never reports a denied read,
    /// is the only sign of one.
    var lastDataFound: [HealthSync.DataType: Date] {
        get {
            let raw = defaults.dictionary(forKey: key("lastDataFound")) as? [String: Double] ?? [:]
            var out: [HealthSync.DataType: Date] = [:]
            for (name, seconds) in raw {
                if let type = HealthSync.DataType(rawValue: name) {
                    out[type] = Date(timeIntervalSince1970: seconds)
                }
            }
            return out
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
            defaults.set(raw, forKey: key("lastDataFound"))
        }
    }

    /// The workout `HKQueryAnchor`, archived. Advanced only once every workout
    /// it covers is in the upload queue.
    var workoutAnchor: HKQueryAnchor? {
        get {
            guard let data = defaults.data(forKey: key("workoutAnchor")) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
        nonmutating set {
            guard let newValue,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true)
            else {
                defaults.removeObject(forKey: key("workoutAnchor"))
                return
            }
            defaults.set(data, forKey: key("workoutAnchor"))
        }
    }

    /// Adopt an anchor an app archived itself before using the SDK, then remove
    /// it from where it was. Removed so it is adopted exactly once: after a
    /// disconnect the SDK forgets its own anchor, and a reconnect has to start
    /// from the full history rather than from a stale import.
    func importWorkoutAnchor(fromUserDefaultsKey legacyKey: String) {
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return }
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }
        guard defaults.data(forKey: key("workoutAnchor")) == nil,
              (try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)) != nil
        else { return }
        defaults.set(data, forKey: key("workoutAnchor"))
    }

    /// The workouts this device has scheduled on the watch, by WorkoutKit plan
    /// id. How the next sync tells its own plans from ones the app scheduled
    /// itself, and an unchanged workout from an edited one.
    var managedPlans: [UUID: ManagedPlan] {
        get {
            guard let data = defaults.data(forKey: key("managedPlans")),
                  let raw = try? JSONDecoder().decode([String: ManagedPlan].self, from: data)
            else { return [:] }
            var out: [UUID: ManagedPlan] = [:]
            for (id, plan) in raw {
                if let uuid = UUID(uuidString: id) { out[uuid] = plan }
            }
            return out
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            if raw.isEmpty {
                defaults.removeObject(forKey: key("managedPlans"))
            } else if let data = try? JSONEncoder().encode(raw) {
                defaults.set(data, forKey: key("managedPlans"))
            }
        }
    }

    /// The scheduling authorization the API was last told about, so it is told
    /// again only when it changes.
    var declaredScheduling: String? {
        get { defaults.string(forKey: key("declaredScheduling")) }
        nonmutating set { defaults.set(newValue, forKey: key("declaredScheduling")) }
    }

    /// Forget everything about this device's sync — on disconnect, so the next
    /// connect starts with a full history.
    ///
    /// `managedPlans` is not in the list: those are plans physically on a
    /// watch, and forgetting them before they are removed would leave them
    /// there with nothing that knows they are ours. Whoever removes them
    /// clears it.
    func reset() {
        for name in ["connected", "lastSyncDate", "wellnessCollectedThrough", "workoutAnchor", "lastDataFound", "declaredScheduling"] {
            defaults.removeObject(forKey: key(name))
        }
    }

    private func date(_ name: String) -> Date? {
        let seconds = defaults.double(forKey: key(name))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func setDate(_ date: Date?, _ name: String) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key(name))
        } else {
            defaults.removeObject(forKey: key(name))
        }
    }
}
