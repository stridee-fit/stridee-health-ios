import Foundation
import Security

/// Holds the current device token and asks for the next one.
///
/// Kept in the Keychain rather than in memory alone, because HealthKit wakes the
/// app in the background many times a day and each wake would otherwise cost a
/// round trip to the developer's server. `AfterFirstUnlockThisDeviceOnly`: the
/// background wakes happen while the phone is locked, and a bearer token has no
/// business in a backup restored onto another device.
actor TokenStore {
    private let provider: @Sendable () async throws -> HealthSync.DeviceToken
    private var cached: HealthSync.DeviceToken?
    private var inFlight: Task<HealthSync.DeviceToken, Error>?

    private static let service = "fit.stridee.health"
    private static let account = "device-token"

    /// Renew this long before expiry, so a token never runs out mid-upload.
    private static let renewMargin: TimeInterval = 120

    init(provider: @escaping @Sendable () async throws -> HealthSync.DeviceToken) {
        self.provider = provider
        self.cached = Self.load()
    }

    /// A token good for at least the renewal margin, minting one if needed.
    /// Concurrent callers share one call to the provider.
    func current() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSinceNow > Self.renewMargin {
            return cached.token
        }
        return try await refresh().token
    }

    /// Drop the current token and fetch another. Called after a 401.
    func invalidate() {
        cached = nil
        Self.delete()
    }

    func clear() {
        inFlight?.cancel()
        inFlight = nil
        invalidate()
    }

    private func refresh() async throws -> HealthSync.DeviceToken {
        if let inFlight { return try await inFlight.value }
        let provider = provider
        let task = Task { try await provider() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let token = try await task.value
            cached = token
            Self.save(token)
            return token
        } catch {
            throw HealthSyncError.tokenUnavailable(String(describing: error))
        }
    }

    // MARK: Keychain

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> HealthSync.DeviceToken? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HealthSync.DeviceToken.self, from: data)
    }

    private static func save(_ token: HealthSync.DeviceToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        delete()
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func delete() {
        SecItemDelete(query() as CFDictionary)
    }
}

/// The `/v1/device/*` calls, and nothing else.
///
/// Every request carries a device token. A 401 is retried once with a fresh
/// one — the token may have been revoked or expired early — and anything else
/// is mapped to a ``HealthSyncError`` the caller can act on.
struct APIClient: Sendable {
    let baseURL: URL
    let tokens: TokenStore
    let session: URLSession

    init(baseURL: URL, tokens: TokenStore) {
        self.baseURL = baseURL
        self.tokens = tokens
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    enum Outcome: Equatable {
        case ok
        /// The person is not connected on the server (404 on the connection,
        /// 409 on an upload).
        case notConnected
    }

    func getConnection() async throws -> Outcome {
        try await send("GET", "v1/device/connections/apple", body: nil)
    }

    func putConnection() async throws -> Outcome {
        try await send("PUT", "v1/device/connections/apple", body: nil)
    }

    func deleteConnection() async throws -> Outcome {
        try await send("DELETE", "v1/device/connections/apple", body: nil)
    }

    func uploadWorkout(_ body: Data) async throws -> Outcome {
        try await send("POST", "v1/device/apple/workouts", body: body)
    }

    func uploadWellness(_ body: Data) async throws -> Outcome {
        try await send("POST", "v1/device/apple/wellness", body: body)
    }

    // MARK: Workouts for the watch

    /// What the API lists for the watch, or that this person is not connected.
    enum Schedule: Equatable {
        case workouts([ScheduledItem])
        case notConnected
    }

    /// Say whether this device may add workouts to the Workout app.
    func putWorkoutScheduling(authorization: String) async throws -> Outcome {
        let body = try JSONSerialization.data(withJSONObject: ["authorization": authorization])
        return try await send("PUT", "v1/device/apple/workout-scheduling", body: body)
    }

    func scheduledWorkouts() async throws -> Schedule {
        let response = try await perform("GET", "v1/device/apple/scheduled-workouts", body: nil)
        if try outcome(of: response, path: "v1/device/apple/scheduled-workouts") == .notConnected {
            return .notConnected
        }
        do {
            return .workouts(try JSONDecoder().decode(ScheduledWorkoutsResponse.self, from: response.data).workouts)
        } catch {
            throw HealthSyncError.transport("Unreadable schedule: \(error.localizedDescription)")
        }
    }

    /// Report what happened to one workout.
    ///
    /// A 404 or a 412 is not a failure: the workout was deleted, or edited
    /// since this device read it. Either way there is nothing left to say
    /// about the version this report describes, and the next sync sees the
    /// current one.
    func reportScheduledWorkout(id: String, revision: String, outcome: String, error: String?) async throws -> Outcome {
        var report: [String: Any] = ["revision": revision, "outcome": outcome]
        if let error { report["error"] = error }
        let path = "v1/device/apple/scheduled-workouts/\(id)"
        let response = try await perform("PUT", path, body: try JSONSerialization.data(withJSONObject: report))
        if response.status == 404 || response.status == 412 { return .ok }
        return try self.outcome(of: response, path: path)
    }

    // MARK: Transport

    private struct Response {
        let status: Int
        let data: Data
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Outcome {
        try outcome(of: try await perform(method, path, body: body), path: path)
    }

    /// What a status means, the same for every call.
    private func outcome(of response: Response, path: String) throws -> Outcome {
        switch response.status {
        case 200...299:
            return .ok
        case 404 where path.hasPrefix("v1/device/connections"):
            return .notConnected
        case 409:
            return .notConnected
        case 500...599, 408, 429:
            throw HealthSyncError.transport("HTTP \(response.status)")
        default:
            let message = String(data: response.data, encoding: .utf8) ?? ""
            throw HealthSyncError.rejected(status: response.status, message: message)
        }
    }

    private func perform(_ method: String, _ path: String, body: Data?, retried: Bool = false) async throws -> Response {
        let token = try await tokens.current()

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HealthSyncError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HealthSyncError.transport("No HTTP response")
        }

        if http.statusCode == 401 && !retried {
            await tokens.invalidate()
            return try await perform(method, path, body: body, retried: true)
        }
        return Response(status: http.statusCode, data: data)
    }
}
