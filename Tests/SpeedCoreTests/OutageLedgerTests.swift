import Foundation
import Testing
@testable import SpeedCore

private func tempStore() -> AtomicJSONStore<OutageRecord> {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("isr-tests-\(UUID().uuidString)")
        .appendingPathComponent("outages.json")
    return AtomicJSONStore(url: url, cap: 500)
}



@Suite("Outage ledger")
struct OutageLedgerTests {
    @Test("Outages survive a reload")
    func persistsAcrossReload() async throws {
        let store = tempStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let ledger = OutageLedger(store: store, heartbeatStore: MemoryHeartbeatStore())
        await ledger.open(OutageRecord(start: start, cause: .probeFailed))
        await ledger.close(at: start.addingTimeInterval(60), reason: .recovered)

        let reloaded = OutageLedger(store: store, heartbeatStore: MemoryHeartbeatStore())
        await reloaded.load()
        let all = await reloaded.all()
        #expect(all.count == 1)
        #expect(all[0].duration() == 60)
    }

    @Test("Blips shorter than the threshold are dropped instead of cluttering the log")
    func dropsShortOutages() async {
        let ledger = OutageLedger(store: tempStore(), minimumDuration: 3, heartbeatStore: MemoryHeartbeatStore())
        let start = Date()
        await ledger.open(OutageRecord(start: start, cause: .probeFailed))
        let kept = await ledger.close(at: start.addingTimeInterval(1.5), reason: .recovered)
        #expect(kept == nil)
        let all = await ledger.all()
        #expect(all.isEmpty)
    }

    @Test("A crash-orphaned outage is closed at the last heartbeat, not left running forever")
    func closesCrashOrphans() async {
        let store = tempStore()
        let heartbeat = MemoryHeartbeatStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let lastAlive = start.addingTimeInterval(120)

        let first = OutageLedger(store: store, heartbeatStore: heartbeat)
        await first.open(OutageRecord(start: start, cause: .probeFailed))
        await first.heartbeat(now: lastAlive)

        // Simulate a relaunch after a force quit: the record is still open on disk.
        let second = OutageLedger(store: store, heartbeatStore: heartbeat)
        await second.load()
        let all = await second.all()
        #expect(all.count == 1)
        #expect(all[0].end == lastAlive)
        #expect(all[0].endReason == .crash)
    }

    @Test("An unknown schema version is moved aside rather than crashing the app")
    func unknownVersionMovedAside() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isr-tests-\(UUID().uuidString)")
            .appendingPathComponent("outages.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version": 99, "records": []}"#.data(using: .utf8)!.write(to: url)

        let store = AtomicJSONStore<OutageRecord>(url: url, currentVersion: 1)
        #expect(store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
