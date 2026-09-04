import Foundation

/// Pre-generated files used as upload bodies.
///
/// File-backed rather than in-memory: `uploadTask(with:from:)` holds the whole body in
/// RAM, so a large upload on a fast link would balloon a menu bar agent's footprint.
/// A file also gives an explicit Content-Length instead of chunked encoding.
public struct UploadFixture: Sendable {
    public static let rungs = [1_048_576, 4_194_304, 16_777_216, 33_554_432]

    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func makeDefault() throws -> UploadFixture {
        UploadFixture(directory: try AppPaths.uploadFixturesDirectory())
    }

    public func url(forBytes bytes: Int) throws -> URL {
        let rung = Self.rungs.min(by: { abs($0 - bytes) < abs($1 - bytes) }) ?? Self.rungs[0]
        let url = directory.appendingPathComponent("upload-\(rung).bin")

        let existing = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        if existing == rung { return url }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Random rather than zeros so no layer along the path can compress it away and
        // report a speed the link cannot actually deliver.
        var data = Data(count: rung)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, rung)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    public func rung(forPerStreamBytesPerSecond rate: Double) -> Int {
        guard rate > 0 else { return Self.rungs[0] }
        let target = Int(rate * 2.0)
        return Self.rungs.min(by: { abs($0 - target) < abs($1 - target) }) ?? Self.rungs[0]
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
