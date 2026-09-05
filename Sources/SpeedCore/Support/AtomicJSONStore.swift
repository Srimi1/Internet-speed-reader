import Foundation

/// Small versioned JSON file store used for the outage ledger and speed test history.
///
/// Versioned so a future schema change cannot crash on old data: an unknown version is
/// moved aside rather than parsed, and the app starts fresh instead of dying at launch.
public struct AtomicJSONStore<Record: Codable & Sendable>: Sendable {
    public struct Envelope: Codable {
        public var version: Int
        public var records: [Record]
    }

    public let url: URL
    public let currentVersion: Int
    public let cap: Int

    public init(url: URL, currentVersion: Int = 1, cap: Int = 500) {
        self.url = url
        self.currentVersion = currentVersion
        self.cap = cap
    }

    public func load() -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == currentVersion else {
                try? moveAside()
                return []
            }
            return envelope.records
        } catch {
            try? moveAside()
            return []
        }
    }

    public func save(_ records: [Record]) throws {
        let trimmed = records.count > cap ? Array(records.suffix(cap)) : records
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: currentVersion, records: trimmed))

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func moveAside() throws {
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.moveItem(at: url, to: backupURL)
    }

    private var backupURL: URL { url.appendingPathExtension("bak") }

    /// Deletes the moved-aside `.bak` sidecar, if one exists. `moveAside` leaves a copy
    /// of the old records behind on a schema bump or a corrupt-file recovery, and those
    /// copies carry the same fields as the live file (for history: provider, location and
    /// server metadata). The user-facing "Clear" actions call this so clearing actually
    /// removes everything rather than leaving stale data in the sidecar.
    public func removeBackup() {
        try? FileManager.default.removeItem(at: backupURL)
    }
}
