import Foundation
import Testing
@testable import SpeedCore

@Suite("Cloudflare metadata decoding")
struct CloudflareMetaTests {
    private func decode(_ json: String) throws -> CloudflareMeta {
        try JSONDecoder().decode(CloudflareMeta.self, from: Data(json.utf8))
    }

    @Test("Decodes the shape the live endpoint actually returns")
    func liveShape() throws {
        // Synthetic metadata with the observed endpoint schema: asn is a number,
        // coordinates are strings, and colo is an object. No real client data.
        let meta = try decode("""
        {"hostname":"speed.cloudflare.com","clientIp":"2001:db8::1","httpProtocol":"HTTP/1.1",
         "asn":64512,"asOrganization":"Example ISP","country":"XX","city":"Example City",
         "region":"Example Region","postalCode":"000000","latitude":"0.0","longitude":"0.0",
         "colo":{"iata":"XXX","lat":0.0,"lon":0.0,"cca2":"XX","region":"Example Region","city":"Example Server"}}
        """)

        #expect(meta.asn == 64512)
        #expect(meta.ispDisplayName == "Example ISP")
        #expect(meta.clientLocation == "Example City")
        #expect(meta.serverDisplayName == "Example Server (XXX)")
    }

    @Test("Tolerates the older shape where colo is a bare code and asn is a string")
    func legacyShape() throws {
        let meta = try decode(#"{"asn":"13335","asOrganization":"Cloudflare","colo":"MAA"}"#)
        #expect(meta.asn == 13335)
        #expect(meta.serverDisplayName == "MAA")
    }

    @Test("The 403 empty body still yields a usable, non-blank ISP label")
    func emptyBody() throws {
        // Without a Referer header the endpoint answers 403 with {}. The display must
        // degrade to a label rather than showing nothing.
        let meta = try decode("{}")
        #expect(meta.ispDisplayName == "Unknown ISP")
        #expect(meta.serverDisplayName == nil)
    }
}

@Suite("Response validation")
struct ResponseValidatorTests {
    @Test("HTTP 403 refusals are not reported as HTTP 429 rate limits")
    func distinguishesRefusalFromRateLimit() throws {
        let refused = [
            ResponseValidator.validateDownload(status: 403, contentType: nil, expectedContentLength: 0, requestedBytes: 0),
            ResponseValidator.validateDownload(status: 403, contentType: nil, expectedContentLength: 1, requestedBytes: 104_857_600),
            ResponseValidator.validateUpload(status: 403, confirmedBytesHeader: nil, sentBytes: 1024),
        ]
        for outcome in refused {
            do { try outcome.requireValid(); Issue.record("HTTP 403 must fail") }
            catch {
                guard case .engineFailure(let message) = error as? SpeedTestError else {
                    Issue.record("HTTP 403 must be an explicit server failure"); continue
                }
                #expect(message.contains("HTTP 403"))
            }
        }
        #expect(ResponseValidator.validateDownload(status: 429, contentType: nil, expectedContentLength: 1, requestedBytes: 0) == .rateLimited)
        #expect(ResponseValidator.validateUpload(status: 429, confirmedBytesHeader: nil, sentBytes: 1024) == .rateLimited)
    }

    @Test("A captive portal's HTML is rejected instead of being measured as speed")
    func rejectsPortalHTML() {
        let outcome = ResponseValidator.validateDownload(
            status: 200, contentType: "text/html; charset=utf-8",
            expectedContentLength: 4_096, requestedBytes: 26_214_400
        )
        guard case .intercepted = outcome else { Issue.record("portal HTML must be rejected"); return }
    }

    @Test("A body shorter than requested is rejected, not counted")
    func rejectsLengthMismatch() {
        let outcome = ResponseValidator.validateDownload(
            status: 200, contentType: "application/octet-stream",
            expectedContentLength: 1_000, requestedBytes: 26_214_400
        )
        guard case .intercepted = outcome else { Issue.record("a short body must be rejected"); return }
    }

    @Test("The byte-cap rejection is recognised rather than read as a network failure")
    func recognisesByteCap() {
        // Cloudflare answers 403 with a one-byte body when asked for too much.
        let outcome = ResponseValidator.validateDownload(
            status: 403, contentType: nil, expectedContentLength: 1, requestedBytes: 104_857_600
        )
        #expect(outcome == .byteCapExceeded)
    }

    @Test("A valid chunk passes")
    func acceptsValidChunk() {
        let outcome = ResponseValidator.validateDownload(
            status: 200, contentType: "application/octet-stream",
            expectedContentLength: 26_214_400, requestedBytes: 26_214_400
        )
        #expect(outcome == .valid)
    }

    @Test("An upload is only trusted when the server confirms the byte count it received")
    func uploadNeedsServerConfirmation() {
        #expect(ResponseValidator.validateUpload(status: 200, confirmedBytesHeader: "1048576", sentBytes: 1_048_576) == .valid)

        guard case .intercepted = ResponseValidator.validateUpload(
            status: 200, confirmedBytesHeader: nil, sentBytes: 1_048_576
        ) else { Issue.record("a missing confirmation header must not count"); return }

        guard case .intercepted = ResponseValidator.validateUpload(
            status: 200, confirmedBytesHeader: "512", sentBytes: 1_048_576
        ) else { Issue.record("a partial upload must not count"); return }
    }
}

@Suite("Upload fixtures")
struct UploadFixtureTests {
    @Test("Fixtures are created at the requested size and reused")
    func createsAndReuses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isr-fixtures-\(UUID().uuidString)")
        let fixtures = UploadFixture(directory: directory)
        defer { fixtures.clear() }

        let url = try fixtures.url(forBytes: 1_048_576)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 1_048_576)

        let again = try fixtures.url(forBytes: 1_048_576)
        #expect(again == url)
    }

    @Test("Rung selection targets about two seconds of upload per request")
    func rungSelection() {
        let fixtures = UploadFixture(directory: FileManager.default.temporaryDirectory)
        #expect(fixtures.rung(forPerStreamBytesPerSecond: 0) == 16_384)
        #expect(fixtures.rung(forPerStreamBytesPerSecond: 2_000_000) == 4_194_304)
        #expect(fixtures.rung(forPerStreamBytesPerSecond: 20_000_000) == 33_554_432)
    }
}
