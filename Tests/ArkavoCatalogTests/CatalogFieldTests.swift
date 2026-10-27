import Foundation
import Testing
@testable import ArkavoCatalog

struct CatalogFieldTests {
    // MARK: Identifiers

    @Test(arguments: ["a", ".a", "a.b", "arkavo:5c1f0e7a-2b8d", "x@y_z", String(repeating: "s", count: 248)])
    func validSubject(_ value: String) {
        #expect(CatalogField.isValidSubject(value))
    }

    @Test(arguments: ["", ".", "..", "a..b", "a/b", "a b", "é", String(repeating: "s", count: 249)])
    func invalidSubject(_ value: String) {
        #expect(!CatalogField.isValidSubject(value))
    }

    @Test func contentIDsAllow256Bytes() {
        #expect(CatalogField.isValidContentID(String(repeating: "c", count: 256)))
        #expect(!CatalogField.isValidContentID(String(repeating: "c", count: 257)))
    }

    @Test func digestsAreExactly64LowercaseHex() {
        #expect(CatalogField.isLowercaseHexDigest(String(repeating: "0123456789abcdef", count: 4)))
        #expect(!CatalogField.isLowercaseHexDigest(String(repeating: "A", count: 64)))
        #expect(!CatalogField.isLowercaseHexDigest(String(repeating: "a", count: 63)))
        #expect(!CatalogField.isLowercaseHexDigest(String(repeating: "g", count: 64)))
    }

    // MARK: Integers

    @Test func integersAreDigitsWithoutALeadingZero() {
        #expect(CatalogField.integer("0") == 0)
        #expect(CatalogField.integer("7") == 7)
        #expect(CatalogField.integer("18446744073709551615") == UInt64.max)
        for text in ["", "01", "-1", "+1", "1.0", "1e0", " 1", "18446744073709551616"] {
            #expect(CatalogField.integer(text) == nil, "\(text)")
        }
    }

    // MARK: Titles

    @Test func titlesAreCutAtACharacterBoundary() {
        #expect(CatalogField.truncatedTitle("") == nil)
        #expect(CatalogField.truncatedTitle("Studio") == "Studio")
        let long = String(repeating: "t", count: 510) + "😀"
        #expect(CatalogField.truncatedTitle(long) == String(repeating: "t", count: 510))
        let exact = String(repeating: "😀", count: 128)
        #expect(CatalogField.truncatedTitle(exact + "x") == exact)
        #expect(CatalogField.isValidTitle(exact))
        #expect(!CatalogField.isValidTitle(""))
    }

    // MARK: Timestamps

    @Test(arguments: ["1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "2000-02-29T12:34:56Z", "2026-10-19T01:02:03Z",
                      "0000-01-01T00:00:00Z", "9999-12-31T23:59:59Z"])
    func timestampsRoundTrip(_ text: String) throws {
        let date = try #require(CatalogField.timestamp(text))
        #expect(CatalogField.timestamp(date) == text)
    }

    @Test func timestampsCountFromTheEpoch() {
        #expect(CatalogField.timestamp("1970-01-01T00:00:01Z") == Date(timeIntervalSince1970: 1))
        #expect(CatalogField.timestamp("2026-10-19T01:02:03Z") == Date(timeIntervalSince1970: 1_792_371_723))
    }

    @Test func formattingRoundsDownToTheSecond() {
        #expect(CatalogField.timestamp(Date(timeIntervalSince1970: 1.9)) == "1970-01-01T00:00:01Z")
        #expect(CatalogField.timestamp(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59Z")
    }

    @Test func formattingRefusesYearsOutsideFourDigits() {
        #expect(CatalogField.timestamp(Date(timeIntervalSince1970: 253_402_300_800)) == nil)  // 10000-01-01
        #expect(CatalogField.timestamp(Date(timeIntervalSince1970: -62_167_219_201)) == nil)  // before 0000-01-01
        for interval in [1e19, -1e19, .infinity, -.infinity, .nan, Double(Int.max)] {
            #expect(CatalogField.timestamp(Date(timeIntervalSince1970: interval)) == nil, "\(interval)")
        }
    }

    // MARK: Attribute FQNs

    @Test(arguments: [
        "https://patreon.arkavo.com/attr/campaign/value/12345678",
        "https://example.com",
        "https://EXAMPLE.com/a",
        "https://a_b.example/a",
        "https://-a.example/a",
        "https://example.com:8443/a",
        "https://example.com:/a",
        "https://example.com:65535",
        "https://192.0.2.10/a",
        "https://0.0.0.0",
        "https://example.com/a?x=1#y",
        "https://example.com?x",
        "https://example.com#y",
    ])
    func acceptedAttribute(_ value: String) {
        #expect(CatalogField.isAttributeFQN(value))
    }

    @Test(arguments: [
        "https://",
        "https:///a",
        "https://?x",
        "https://:443/a",
        "http://example.com/a",
        "HTTPS://example.com/a",
        "https://user@example.com/a",
        "https://[2001:db8::1]/a",
        "https://exa%41mple.com/a",
        "https://example.com:65536/a",
        "https://example.com:123456/a",
        "https://example.com:8x/a",
        "https://example..com/a",
        "https://example.com./a",
        "https://.example.com/a",
        "https://a.1/x",
        "https://a.0x1f/x",
        "https://a.0X/x",
        "https://256.0.0.1/x",
        "https://01.2.3.4/x",
        "https://1.2.3/x",
        "https://xn--abc.example/x",
        "https://XN--abc.example/x",
        "https://a!b.example/x",
        "https://a b/c",
        "https://\\example.com",
    ])
    func refusedAttribute(_ value: String) {
        #expect(!CatalogField.isAttributeFQN(value))
    }

    @Test func attributesAreAtMost512Bytes() {
        let base = "https://example.com/"
        #expect(CatalogField.isAttributeFQN(base + String(repeating: "x", count: 512 - base.utf8.count)))
        #expect(!CatalogField.isAttributeFQN(base + String(repeating: "x", count: 513 - base.utf8.count)))
    }
}
