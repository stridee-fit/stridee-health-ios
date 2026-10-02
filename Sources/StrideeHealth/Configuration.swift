import Foundation

extension HealthSync {

    /// A device token, as your server minted it with `POST /v1/device-tokens`.
    ///
    /// Return one from ``Configuration/tokenProvider``. Pass the `expires_at`
    /// the API gave you, so the SDK can ask for the next one before this one
    /// runs out rather than after a refused upload.
    public struct DeviceToken: Sendable, Codable, Equatable {
        public let token: String
        public let expiresAt: Date

        public init(token: String, expiresAt: Date) {
            self.token = token
            self.expiresAt = expiresAt
        }
    }

    /// What the SDK reads from HealthKit and sends.
    public enum DataType: String, Sendable, CaseIterable, Codable {
        /// Workouts with their route and heart-rate, power and cadence streams.
        /// Delivered to you as FIT files on `activity.created`.
        case workouts
        /// Daily totals, sleep, HRV, VO₂max, respiration, blood oxygen, body
        /// composition, blood pressure and wrist temperature. Delivered as
        /// `wellness.created` / `wellness.updated`.
        case wellness
    }

    public struct Configuration: Sendable {
        /// Fetches a fresh device token from **your** server.
        ///
        /// Your server authenticates your user however it already does, then
        /// calls `POST /v1/device-tokens` with your id for them and returns the
        /// result. Called when there is no token yet, when the current one is
        /// about to expire, and once after the API refuses one. May be called
        /// in the background when HealthKit wakes your app — it should not
        /// need UI.
        ///
        /// If it throws, nothing is lost: uploads stay queued on disk and go
        /// out on the next sync.
        public var tokenProvider: @Sendable () async throws -> DeviceToken

        /// What to sync. Both by default. The HealthKit permission sheet asks
        /// only for what this needs.
        public var dataTypes: Set<DataType>

        /// Workouts written by these apps are not sent.
        ///
        /// Defaults to Garmin Connect and Wahoo, whose workouts reach the
        /// Stridee platform natively — with richer files — when the athlete
        /// connects those providers. Mirrored into HealthKit, they would
        /// arrive twice. Set to `[]` if you do not use those integrations.
        public var excludedSourceBundleIDs: Set<String>

        /// How many days of wellness history the first sync sends. Workouts
        /// always send their full history.
        public var wellnessHistoryDays: Int

        /// The Stridee API. Change it only to point at a staging deployment.
        public var baseURL: URL

        /// Put the workouts your server pushes on the athlete's Apple Watch.
        ///
        /// Off by default. When on, every sync fetches the workouts you
        /// created with `POST /v1/workouts` for this user and schedules them
        /// in the Workout app with WorkoutKit — the only way onto an Apple
        /// Watch, since Apple has no server API for it. The athlete has to
        /// allow it once: call
        /// ``HealthSync/requestWorkoutSchedulingAuthorization()`` from the
        /// screen where they turn it on.
        public var schedulesWorkouts: Bool

        /// If your app synced HealthKit workouts before adopting this SDK and
        /// kept its `HKQueryAnchor` in `UserDefaults.standard`, name the key
        /// here. The first sync resumes from it instead of re-sending the
        /// whole history. Read once; ignored when the SDK already has an
        /// anchor of its own.
        public var importWorkoutAnchorFromUserDefaultsKey: String?

        public init(
            tokenProvider: @escaping @Sendable () async throws -> DeviceToken,
            dataTypes: Set<DataType> = Set(DataType.allCases),
            excludedSourceBundleIDs: Set<String> = Configuration.defaultExcludedSourceBundleIDs,
            wellnessHistoryDays: Int = 90,
            baseURL: URL = URL(string: "https://api.stridee.com")!,
            importWorkoutAnchorFromUserDefaultsKey: String? = nil,
            schedulesWorkouts: Bool = false
        ) {
            self.tokenProvider = tokenProvider
            self.dataTypes = dataTypes
            self.excludedSourceBundleIDs = excludedSourceBundleIDs
            self.wellnessHistoryDays = max(1, wellnessHistoryDays)
            self.baseURL = baseURL
            self.importWorkoutAnchorFromUserDefaultsKey = importWorkoutAnchorFromUserDefaultsKey
            self.schedulesWorkouts = schedulesWorkouts
        }

        public static let defaultExcludedSourceBundleIDs: Set<String> = [
            "com.garmin.connect.mobile",
            "com.wahoofitness.fitness",
            "com.wahoofitness.bolt",
        ]
    }

    /// How far the HealthKit permission flow has got.
    ///
    /// There is deliberately no `granted` or `denied`: iOS never tells an app
    /// whether the user allowed it to *read* health data, because a denial
    /// would itself say something about their health. `requested` means the
    /// user has answered the sheet for every type — not that they said yes.
    /// To tell whether data is actually flowing, read
    /// ``Status/lastDataFound``.
    public enum AuthorizationStatus: Sendable, Equatable {
        /// HealthKit does not exist on this device (an iPad without Health).
        case unavailable
        /// The permission sheet would appear: at least one type has never been
        /// asked about.
        case notRequested
        /// The user has answered for every type. Whether they allowed reading
        /// is theirs to know.
        case requested
    }

    /// Whether the athlete lets your app add workouts to the Workout app.
    ///
    /// Unlike reading health data, iOS does say: `denied` is a real answer,
    /// and the one to show a Settings button for.
    public enum WorkoutSchedulingAuthorization: String, Sendable, Equatable {
        /// This device cannot schedule workouts — an iPad, or the simulator.
        case unsupported
        /// They have not been asked. ``HealthSync/requestWorkoutSchedulingAuthorization()`` asks.
        case notDetermined = "not_determined"
        /// They said no, or turned it off. Only they can turn it back on, in
        /// Settings: ``HealthSync/openSettings()``.
        case denied
        /// The device does not let them choose — a managed phone.
        case restricted
        case authorized
    }

    /// Where the workouts for the watch stand.
    public struct WorkoutScheduling: Sendable, Equatable {
        public internal(set) var authorization: WorkoutSchedulingAuthorization = .notDetermined
        /// Workouts from your server now in the Workout app.
        public internal(set) var scheduledCount: Int = 0
        /// Workouts your server has pushed that are not on the watch yet: the
        /// athlete has not allowed scheduling, or the Workout app is holding
        /// as many as it takes and these are further out.
        public internal(set) var waitingCount: Int = 0
        /// When the watch was last made to match your server.
        public internal(set) var lastSyncDate: Date?
        /// Why the last attempt stopped short, if it did.
        public internal(set) var lastError: HealthSyncError?
    }

    /// Where syncing stands, for your UI.
    public struct Status: Sendable, Equatable {
        /// Where the permission flow stands. Refreshed at launch and after
        /// every ``HealthSync/requestAuthorization(for:)`` and
        /// ``HealthSync/connect(requestingAuthorization:)``.
        public internal(set) var authorization: AuthorizationStatus = .notRequested
        /// When a sync last found new data in HealthKit, per data type.
        ///
        /// The closest thing to a permission check iOS allows. Connected for a
        /// few days with nothing here for `.workouts`, from a user you know
        /// trains, usually means they left the switches off — show them
        /// ``HealthSync/openSettings()``.
        public internal(set) var lastDataFound: [DataType: Date] = [:]
        /// This device is connected and syncing in the background.
        public internal(set) var isConnected: Bool = false
        public internal(set) var isSyncing: Bool = false
        /// When a sync last finished with everything uploaded.
        public internal(set) var lastSyncDate: Date?
        /// Why the last sync stopped short, if it did. Cleared by the next
        /// sync that completes.
        public internal(set) var lastError: HealthSyncError?
        /// Workouts and wellness batches waiting to upload.
        public internal(set) var pendingUploads: Int = 0
        /// While a sync is uploading: how far through it is.
        public internal(set) var progress: Progress?
        /// The workouts your server pushed for the watch. Only moves when
        /// ``Configuration/schedulesWorkouts`` is on.
        public internal(set) var workoutScheduling = WorkoutScheduling()

        public struct Progress: Sendable, Equatable {
            public let done: Int
            public let total: Int
        }
    }
}

/// Everything that can stop a connect or a sync.
public enum HealthSyncError: Error, Sendable, Equatable, LocalizedError {
    /// HealthKit is not available on this device (an iPad without Health).
    case healthDataUnavailable
    /// ``HealthSync/configure(_:)`` has not been called.
    case notConfigured
    /// This device is not connected. Call ``HealthSync/connect()``.
    case notConnected
    /// The Stridee API no longer has this user connected — your server
    /// disconnected them, or the athlete did from another device. Syncing has
    /// stopped; ``HealthSync/connect()`` starts it again.
    case disconnectedRemotely
    /// Your ``HealthSync/Configuration/tokenProvider`` threw.
    case tokenUnavailable(String)
    /// The API refused a request. `message` is the API's own sentence.
    case rejected(status: Int, message: String)
    /// The network or the API was unreachable. Retried on the next sync.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable: return "Health data isn't available on this device."
        case .notConfigured: return "HealthSync.configure(_:) has not been called."
        case .notConnected: return "Apple Health is not connected."
        case .disconnectedRemotely: return "Apple Health was disconnected."
        case .tokenUnavailable(let why): return "Could not get a device token: \(why)"
        case .rejected(let status, let message): return "The Stridee API refused the request (\(status)): \(message)"
        case .transport(let why): return "Could not reach the Stridee API: \(why)"
        }
    }
}
