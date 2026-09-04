import Foundation

/// Client and edge metadata: the ISP name, the client's city, and which Cloudflare
/// colo served the test.
///
/// Every field is decoded defensively because the live shapes disagree with the
/// documentation: `asn` is a number, latitude and longitude are strings, and `colo`
/// is an object even though older clients treat it as a bare IATA code.
public struct CloudflareMeta: Sendable, Codable, Equatable {
    public var asn: Int?
    public var asOrganization: String?
    public var city: String?
    public var region: String?
    public var country: String?
    public var coloCode: String?
    public var coloCity: String?

    public init(
        asn: Int? = nil,
        asOrganization: String? = nil,
        city: String? = nil,
        region: String? = nil,
        country: String? = nil,
        coloCode: String? = nil,
        coloCity: String? = nil
    ) {
        self.asn = asn
        self.asOrganization = asOrganization
        self.city = city
        self.region = region
        self.country = country
        self.coloCode = coloCode
        self.coloCity = coloCity
    }

    private enum CodingKeys: String, CodingKey {
        case asn, asOrganization, city, region, country, colo
    }

    private enum ColoKeys: String, CodingKey {
        case iata, city
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let value = try? container.decode(Int.self, forKey: .asn) {
            asn = value
        } else if let text = try? container.decode(String.self, forKey: .asn) {
            asn = Int(text)
        }

        asOrganization = try? container.decode(String.self, forKey: .asOrganization)
        city = try? container.decode(String.self, forKey: .city)
        region = try? container.decode(String.self, forKey: .region)
        country = try? container.decode(String.self, forKey: .country)

        // colo is an object today and a plain string in older documentation.
        if let colo = try? container.nestedContainer(keyedBy: ColoKeys.self, forKey: .colo) {
            coloCode = try? colo.decode(String.self, forKey: .iata)
            coloCity = try? colo.decode(String.self, forKey: .city)
        } else if let code = try? container.decode(String.self, forKey: .colo) {
            coloCode = code
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(asn, forKey: .asn)
        try container.encodeIfPresent(asOrganization, forKey: .asOrganization)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(country, forKey: .country)
        var colo = container.nestedContainer(keyedBy: ColoKeys.self, forKey: .colo)
        try colo.encodeIfPresent(coloCode, forKey: .iata)
        try colo.encodeIfPresent(coloCity, forKey: .city)
    }

    public var ispDisplayName: String {
        if let organization = asOrganization, !organization.isEmpty { return organization }
        if let asn { return "AS\(asn)" }
        return "Unknown ISP"
    }

    public var clientLocation: String? {
        [city, region].compactMap { $0 }.filter { !$0.isEmpty }.first
    }

    public var serverDisplayName: String? {
        switch (coloCity, coloCode) {
        case let (city?, code?): return "\(city) (\(code))"
        case let (city?, nil): return city
        case let (nil, code?): return code
        default: return nil
        }
    }
}
