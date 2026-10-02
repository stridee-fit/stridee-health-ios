import Foundation

/// Uploads waiting to go out, one file each, on disk.
///
/// The reason the HealthKit anchor can be advanced the moment a workout is read
/// rather than the moment it is uploaded: once it is in this queue it survives
/// the app being killed, the network being down and the developer's token
/// endpoint failing. The app this replaces kept nothing between runs and
/// re-sent its whole batch after any single failure.
///
/// Files are named `<milliseconds>-<kind>-<key>.json`, so a directory listing
/// sorted by name is oldest first. Protected until first unlock: background
/// delivery wakes the app while the phone is locked, and the queue has to be
/// readable then.
struct UploadQueue {
    enum Kind: String {
        case workout
        case wellness
    }

    struct Item {
        let url: URL
        let kind: Kind
    }

    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrideeHealth", isDirectory: true)
            .appendingPathComponent("Queue", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    /// Add one upload. `key` makes it unique: a workout already queued under
    /// the same key is not queued twice.
    @discardableResult
    func enqueue(_ body: Data, kind: Kind, key: String) -> Bool {
        let suffix = "-\(kind.rawValue)-\(key).json"
        if items().contains(where: { $0.url.lastPathComponent.hasSuffix(suffix) }) {
            return false
        }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        // Zero-padded so a lexical sort is a chronological one.
        let name = String(format: "%015llu", millis) + suffix
        let url = directory.appendingPathComponent(name)
        do {
            try body.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /// Everything queued, oldest first.
    func items() -> [Item] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                let parts = name.split(separator: "-", maxSplits: 2)
                guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])) else { return nil }
                return Item(url: directory.appendingPathComponent(name), kind: kind)
            }
    }

    var count: Int { items().count }

    func body(of item: Item) -> Data? {
        try? Data(contentsOf: item.url)
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
    }

    func removeAll() {
        for item in items() { remove(item) }
    }
}
