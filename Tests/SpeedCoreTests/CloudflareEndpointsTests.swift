import Foundation
import Testing
@testable import SpeedCore

@Suite("Cloudflare endpoints")
struct CloudflareEndpointsTests {
    @Test("The two hosts are distinct and identify themselves")
    func hosts() {
        #expect(CloudflareEndpoints.h3.host == "https://h3.speed.cloudflare.com")
        #expect(CloudflareEndpoints.h3.displayHost == "h3.speed.cloudflare.com")
        #expect(CloudflareEndpoints.h3.key == .cloudflareH3)
        #expect(CloudflareEndpoints.legacy.host == "https://speed.cloudflare.com")
        #expect(CloudflareEndpoints.legacy.key == .cloudflareLegacy)
    }

    /// v1 sent these headers only with the metadata request. Without them the legacy host
    /// refuses a band of download sizes outright, which is what made larger transfers fail
    /// while smaller ones succeeded.
    @Test("Every request carries the browser headers")
    func allRequestsCarryHeaders() {
        for endpoints in [CloudflareEndpoints.h3, .legacy] {
            let requests = [
                endpoints.metaRequest(),
                endpoints.downloadRequest(bytes: 1024, nonce: "n"),
                endpoints.uploadRequest(bytes: 1024),
            ]
            for request in requests {
                #expect(request.value(forHTTPHeaderField: "Referer") == "\(endpoints.host)/")
                #expect(request.value(forHTTPHeaderField: "Origin") == endpoints.host)
                #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
            }
        }
    }

    @Test("Requests use the right method, path and body length")
    func requestShapes() {
        let endpoints = CloudflareEndpoints.h3
        let download = endpoints.downloadRequest(bytes: 4096, nonce: "abc")
        #expect(download.httpMethod == "GET")
        #expect(download.url?.path == "/__down")
        #expect(download.url?.query?.contains("bytes=4096") == true)
        // A unique nonce per request keeps any cache out of the measurement.
        #expect(download.url?.query?.contains("isr=abc") == true)

        let upload = endpoints.uploadRequest(bytes: 2048)
        #expect(upload.httpMethod == "POST")
        #expect(upload.url?.path == "/__up")
        #expect(upload.value(forHTTPHeaderField: "Content-Length") == "2048")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")

        #expect(endpoints.metaRequest().url?.path == "/meta")
    }
}

@Suite("Chunk ladder refusal band")
struct ChunkLadderRefusalBandTests {
    /// The 16 MiB rung sits inside the range the legacy host refuses, which is why some
    /// runs failed at exactly that size while 8 MiB and 32 MiB succeeded.
    @Test("The ladder never asks for a size the host refuses")
    func avoidsRefusedBand() {
        let ladder = ChunkLadder(refusedRange: ChunkLadder.refusedRange)
        for rate in stride(from: 1_000_000.0, through: 40_000_000.0, by: 250_000.0) {
            let size = ladder.size(forPerStreamBytesPerSecond: rate)
            #expect(!ChunkLadder.refusedRange.contains(size), "rate \(rate) chose refused size \(size)")
        }
        #expect(ladder.clampToAllowed(16_777_216) == 8_388_608)
    }

    @Test("Sizes outside the refused band are untouched")
    func leavesOtherSizesAlone() {
        let ladder = ChunkLadder(refusedRange: ChunkLadder.refusedRange)
        #expect(ladder.clampToAllowed(8_388_608) == 8_388_608)
        #expect(ladder.clampToAllowed(33_554_432) == 33_554_432)
        #expect(ladder.clampToAllowed(ChunkLadder.minBytes) == ChunkLadder.minBytes)
    }

    /// The host without a known refusal keeps the plain power-of-two ladder.
    @Test("A ladder with no refused range keeps every rung")
    func unrestrictedLadder() {
        let ladder = ChunkLadder()
        #expect(ladder.size(forPerStreamBytesPerSecond: 8_388_608) == 16_777_216)
    }

    @Test("Sizing stays within the client ceiling and floor")
    func bounds() {
        let ladder = ChunkLadder(refusedRange: ChunkLadder.refusedRange)
        #expect(ladder.size(forPerStreamBytesPerSecond: 0) == ChunkLadder.firstProbeBytes)
        #expect(ladder.size(forPerStreamBytesPerSecond: .infinity) == ChunkLadder.firstProbeBytes)
        #expect(ladder.size(forPerStreamBytesPerSecond: 10_000_000_000) <= ChunkLadder.maxBytes)
    }
}
