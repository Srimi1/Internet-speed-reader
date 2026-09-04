import Foundation

/// Records the moment the app was last known to be alive, so a crash-orphaned outage
/// can be closed at a truthful time.
public protocol HeartbeatStore: Sendable {
    func lastAlive() -> Date?
    func setLastAlive(_ date: Date)
}

public struct UserDefaultsHeartbeatStore: HeartbeatStore {
    public static let key = "com.srimi.internetspeedreader.lastAlive"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func lastAlive() -> Date? { defaults.object(forKey: Self.key) as? Date }
    public func setLastAlive(_ date: Date) { defaults.set(date, forKey: Self.key) }
}

/// In-memory heartbeat for tests.
public final class MemoryHeartbeatStore: HeartbeatStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    public init(value: Date? = nil) { self.value = value }

    public func lastAlive() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func setLastAlive(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        value = date
    }
}

/// Durable list of outages, plus the heartbeat that keeps a crash from leaving an
/// outage looking like it never ended.
public actor OutageLedger {
    private var records: [OutageRecord] = []
    private let store: AtomicJSONStore<OutageRecord>
    private let minimumDuration: TimeInterval
    private let heartbeatStore: any HeartbeatStore

    public init(
        store: AtomicJSONStore<OutageRecord>,
        minimumDuration: TimeInterval = 3,
        heartbeatStore: any HeartbeatStore = UserDefaultsHeartbeatStore()
    ) {
        self.store = store
        self.minimumDuration = minimumDuration
        self.heartbeatStore = heartbeatStore
    }

    public static func makeDefault() throws -> OutageLedger {
        let url = try AppPaths.applicationSupportDirectory().appendingPathComponent("outages.json")
        return OutageLedger(store: AtomicJSONStore(url: url, cap: 500))
    }

    public func load() {
        records = store.load()
        closeCrashOrphans()
    }

    /// Any record still open at launch belongs to a session that ended abruptly.
    /// Close it at the last heartbeat rather than leaving an eternal ongoing outage.
    private func closeCrashOrphans() {
        let lastAlive = heartbeatStore.lastAlive()
        var changed = false
        for index in records.indices where records[index].isOpen {
            records[index].end = lastAlive ?? records[index].start
            records[index].endReason = .crash
            changed = true
        }
        if changed { persist() }
    }

    public func heartbeat(now: Date) {
        heartbeatStore.setLastAlive(now)
    }

    public func open(_ record: OutageRecord) {
        records.append(record)
        persist()
    }

    public func recordFailure(_ kind: ProbeFailureKind) {
        guard let index = records.lastIndex(where: { $0.isOpen }) else { return }
        if !records[index].failureKinds.contains(kind) {
            records[index].failureKinds.append(kind)
            persist()
        }
    }

    public func markNotified() {
        guard let index = records.lastIndex(where: { $0.isOpen }) else { return }
        records[index].notified = true
        persist()
    }

    /// Closes the open outage. Returns it only if it was long enough to keep:
    /// sub-threshold blips are dropped entirely rather than cluttering the log.
    @discardableResult
    public func close(at date: Date, reason: OutageEnd) -> OutageRecord? {
        guard let index = records.lastIndex(where: { $0.isOpen }) else { return nil }
        records[index].end = date
        records[index].endReason = reason
        let record = records[index]

        if record.duration(now: date) < minimumDuration {
            records.remove(at: index)
            persist()
            return nil
        }
        persist()
        return record
    }

    public func all() -> [OutageRecord] { records }

    public func openRecord() -> OutageRecord? { records.last(where: { $0.isOpen }) }

    public func clear() {
        records.removeAll()
        persist()
    }

    private func persist() {
        do { try store.save(records) } catch {
            Log.outage.error("failed to persist outage ledger: \(error.localizedDescription, privacy: .public)")
        }
    }
}
