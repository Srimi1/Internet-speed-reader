import Testing
@testable import SpeedCore

@Suite("Support layer")
struct SupportTests {
    @Test("Duration converts to seconds with sub-second precision")
    func durationSeconds() {
        #expect(Duration.milliseconds(1500).seconds == 1.5)
        #expect(Duration.seconds(2).seconds == 2.0)
    }

    @Test("RingBuffer keeps only the newest elements")
    func ringBufferEviction() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.count == 3)
        #expect(buffer.last == 5)
    }
}
