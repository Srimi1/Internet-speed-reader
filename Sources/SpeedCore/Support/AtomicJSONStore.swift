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
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: url, to: backup)
    }
}
