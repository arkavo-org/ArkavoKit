import Foundation
import Testing
@testable import ArkavoCatalog

/// The bundle's shape and size caps, its initializer and its encoding. Verification is not covered here.
struct CatalogBundleTests {
    private typealias Fixture = CatalogV2Fixture

    private static func b64(_ count: Int) -> String { Base64URL.encode(Data(repeating: 0x41, count: count)) }

    /// A valid bundle's fields as text, so a test replaces exactly one.
    private struct Fields {
        var pointer = b64(10), credentialID = b64(10), authenticatorData = b64(10), clientDataJSON = b64(10)
        var signature = b64(10), credential = b64(10)

        var json: Data {
            Fixture.bundleJSON(pointer: pointer, credentialID: credentialID, authenticatorData: authenticatorData,
                               clientDataJSON: clientDataJSON, signature: signature, credential: credential)
        }
    }

    // MARK: Decoding

    @Test
    func decodesTheContractShape() throws {
        let signature = Fixture.assertionSignature()
        let json = Fixture.bundleJSON(
            pointer: Base64URL.encode(Fixture.pointer), credentialID: Base64URL.encode(Fixture.credentialID),
            authenticatorData: Base64URL.encode(Fixture.authenticatorData),
            clientDataJSON: Base64URL.encode(Fixture.clientData), signature: Base64URL.encode(signature),
            credential: Base64URL.encode(Fixture.goldenAttestation))
        let bundle = try CatalogBundle.decode(json)
        #expect(bundle.pointer == Fixture.pointer)
        #expect(bundle.credentialID == Data(0..<16))
        #expect(bundle.authenticatorData == Fixture.authenticatorData)
        #expect(bundle.clientDataJSON == Fixture.clientData)
        #expect(bundle.signature == signature)
        #expect(bundle.attestation == Fixture.goldenAttestation)
        #expect(Fixture.goldenAttestation.count == 400)
        #expect(try CatalogBundle.decode(Fixture.bundle()).pointer == Fixture.pointer)
        #expect(try CatalogPointer.decode(bundle.pointer).seq == 7)
    }

    @Test
    func acceptsWhitespaceAndKeyOrder() throws {
        let reordered = Data(
            " {\"credential\":\"AA\",\"assertion\":{\"signature\":\"AA\",\"clientDataJSON\":\"AA\",\"authenticatorData\":\"AA\",\"credentialId\":\"AA\"},\"pointer\":\"AA\"}\n".utf8)
        #expect(try CatalogBundle.decode(reordered).signature == Data([0]))
    }

    @Test
    func acceptsTheSizeCaps() throws {
        var fields = Fields()
        fields.pointer = Self.b64(1_024)
        fields.credentialID = Self.b64(1_023)
        fields.authenticatorData = Self.b64(4_096)
        fields.clientDataJSON = Self.b64(4_096)
        fields.signature = Self.b64(80)
        fields.credential = Self.b64(4_096)
        let bundle = try CatalogBundle.decode(fields.json)
        #expect(bundle.pointer.count == 1_024 && bundle.credentialID.count == 1_023 && bundle.signature.count == 80)
        #expect(bundle.authenticatorData.count == 4_096 && bundle.clientDataJSON.count == 4_096)
        #expect(bundle.attestation.count == 4_096)
        #expect(fields.json.count <= CatalogBundle.maxBytes)
    }

    struct Refusal: Sendable, CustomTestStringConvertible {
        let label: String
        let bytes: Data
        init(_ label: String, _ text: String) { self.init(label, Data(text.utf8)) }
        init(_ label: String, _ bytes: Data) { self.label = label; self.bytes = bytes }
        var testDescription: String { label }
    }

    private static func field(_ edit: (inout Fields) -> Void) -> Data {
        var fields = Fields()
        edit(&fields)
        return fields.json
    }

    private static let valid = #"{"pointer":"AA","assertion":{"credentialId":"AA","authenticatorData":"AA","clientDataJSON":"AA","signature":"AA"},"credential":"AA"}"#

    private static let refusals: [Refusal] = [
        .init("a missing top-level key", #"{"pointer":"AA","assertion":{"credentialId":"AA","authenticatorData":"AA","clientDataJSON":"AA","signature":"AA"}}"#),
        .init("an extra top-level key", valid.replacingOccurrences(of: "\"credential\":\"AA\"", with: "\"credential\":\"AA\",\"x\":\"AA\"")),
        .init("a missing assertion key", valid.replacingOccurrences(of: "\"signature\":\"AA\"", with: "\"sig\":\"AA\"")),
        .init("an extra assertion key", valid.replacingOccurrences(of: "\"signature\":\"AA\"", with: "\"signature\":\"AA\",\"x\":\"AA\"")),
        .init("a repeated top-level key", valid.replacingOccurrences(of: "\"pointer\":\"AA\"", with: "\"pointer\":\"AA\",\"pointer\":\"AA\"")),
        .init("a repeated assertion key", valid.replacingOccurrences(of: "\"signature\":\"AA\"", with: "\"signature\":\"AA\",\"signature\":\"AA\"")),
        .init("a non-string pointer", valid.replacingOccurrences(of: "\"pointer\":\"AA\"", with: "\"pointer\":1")),
        .init("a non-string credential", valid.replacingOccurrences(of: "\"credential\":\"AA\"", with: "\"credential\":null")),
        .init("a non-object assertion", valid.replacingOccurrences(of: #""assertion":{"credentialId":"AA","authenticatorData":"AA","clientDataJSON":"AA","signature":"AA"}"#, with: "\"assertion\":\"AA\"")),
        .init("a non-string signature", valid.replacingOccurrences(of: "\"signature\":\"AA\"", with: "\"signature\":[]")),
        .init("a padded value", field { $0.signature = "YQ==" }),
        .init("a standard-alphabet value", field { $0.pointer = "a+b/" }),
        .init("non-zero trailing bits", field { $0.credential = "YR" }),
        .init("a pointer of 1025 bytes", field { $0.pointer = b64(1_025) }),
        .init("a credentialId of 1024 bytes", field { $0.credentialID = b64(1_024) }),
        .init("authenticatorData of 4097 bytes", field { $0.authenticatorData = b64(4_097) }),
        .init("clientDataJSON of 4097 bytes", field { $0.clientDataJSON = b64(4_097) }),
        .init("a signature of 81 bytes", field { $0.signature = b64(81) }),
        .init("a credential of 4097 bytes", field { $0.credential = b64(4_097) }),
        .init("an empty pointer", field { $0.pointer = "" }),
        .init("an empty credentialId", field { $0.credentialID = "" }),
        .init("an empty authenticatorData", field { $0.authenticatorData = "" }),
        .init("an empty clientDataJSON", field { $0.clientDataJSON = "" }),
        .init("an empty signature", field { $0.signature = "" }),
        .init("an empty credential", field { $0.credential = "" }),
        .init("input over 32768 bytes", Fields().json + Data(repeating: 0x20, count: 32_768)),
        .init("a trailing x", Fields().json + Data("x".utf8)),
        .init("a leading BOM", Data([0xEF, 0xBB, 0xBF]) + Fields().json),
        .init("not an object", "[]"),
        .init("empty input", Data()),
    ]

    @Test(arguments: refusals)
    func refusesWhatIsNotABundle(_ refusal: Refusal) {
        #expect(throws: CatalogBundleError.malformed) { try CatalogBundle.decode(refusal.bytes) }
    }

    @Test
    func theByteLimitIsInclusive() throws {
        let json = Fields().json
        #expect(try CatalogBundle.decode(json + Data(repeating: 0x20, count: CatalogBundle.maxBytes - json.count)).pointer.count == 10)
    }

    @Test
    func descriptionIsFixed() throws {
        let bundle = try CatalogBundle.decode(Fixture.bundle())
        #expect(String(describing: bundle) == "Catalog bundle")
        #expect(String(reflecting: bundle) == "Catalog bundle")
        #expect(Mirror(reflecting: bundle).children.isEmpty)
        #expect("\(bundle)" == "Catalog bundle")
    }

    // MARK: The initializer

    /// `count` bytes that are not all alike, so their base64url uses `-` and `_`.
    private static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 251) })
    }

    /// The bundle's six binary values, each with the largest size `decode` accepts.
    enum Field: String, CaseIterable, Sendable {
        case pointer, credentialID, authenticatorData, clientDataJSON, signature, attestation

        var maxCount: Int {
            switch self {
            case .pointer: 1_024
            case .credentialID: 1_023
            case .authenticatorData, .clientDataJSON, .attestation: 4_096
            case .signature: 80
            }
        }

        /// A bundle whose value for this field is `count` bytes and whose other values are 10 bytes each.
        func bundle(count: Int) throws(CatalogBundleError) -> CatalogBundle {
            func value(_ field: Field) -> Data { CatalogBundleTests.bytes(field == self ? count : 10) }
            return try CatalogBundle(pointer: value(.pointer), credentialID: value(.credentialID),
                                     authenticatorData: value(.authenticatorData), clientDataJSON: value(.clientDataJSON),
                                     signature: value(.signature), attestation: value(.attestation))
        }

        /// The bundle's JSON with this field's value `count` bytes and the others 10 bytes each.
        func json(count: Int) -> Data {
            func value(_ field: Field) -> String { Base64URL.encode(CatalogBundleTests.bytes(field == self ? count : 10)) }
            return CatalogV2Fixture.bundleJSON(
                pointer: value(.pointer), credentialID: value(.credentialID), authenticatorData: value(.authenticatorData),
                clientDataJSON: value(.clientDataJSON), signature: value(.signature), credential: value(.attestation))
        }

        func value(in bundle: CatalogBundle) -> Data {
            switch self {
            case .pointer: bundle.pointer
            case .credentialID: bundle.credentialID
            case .authenticatorData: bundle.authenticatorData
            case .clientDataJSON: bundle.clientDataJSON
            case .signature: bundle.signature
            case .attestation: bundle.attestation
            }
        }
    }

    @Test(arguments: Field.allCases)
    func theInitializerAcceptsOneByteAndTheCap(_ field: Field) throws {
        for count in [1, field.maxCount] {
            let bundle = try field.bundle(count: count)
            #expect(field.value(in: bundle) == Self.bytes(count))
        }
    }

    @Test(arguments: Field.allCases)
    func theInitializerRefusesNothingAndOneOverTheCap(_ field: Field) {
        #expect(throws: CatalogBundleError.malformed) { try field.bundle(count: 0) }
        #expect(throws: CatalogBundleError.malformed) { try field.bundle(count: field.maxCount + 1) }
    }

    /// The initializer and `decode` accept exactly the same sizes.
    @Test(arguments: Field.allCases)
    func theInitializerAndDecodeAgreeOnEachSize(_ field: Field) throws {
        for count in [0, 1, field.maxCount, field.maxCount + 1] {
            let made = try? field.bundle(count: count)
            let decoded = try? CatalogBundle.decode(field.json(count: count))
            #expect(made == decoded, "\(field) of \(count) bytes")
            #expect((made != nil) == (1...field.maxCount).contains(count), "\(field) of \(count) bytes")
        }
    }

    // MARK: Encoding

    @Test
    func encodedIsTheContractKeysSortedWithNoWhitespace() throws {
        let bundle = try CatalogBundle.decode(Fixture.bundle())
        func b64(_ data: Data) -> String { Base64URL.encode(data) }
        let expected = #"{"assertion":{"authenticatorData":"\#(b64(bundle.authenticatorData))","clientDataJSON":"\#(b64(bundle.clientDataJSON))","credentialId":"\#(b64(bundle.credentialID))","signature":"\#(b64(bundle.signature))"},"credential":"\#(b64(bundle.attestation))","pointer":"\#(b64(bundle.pointer))"}"#
        #expect(bundle.encoded() == Data(expected.utf8))

        let root = try #require(StrictJSON.parse(bundle.encoded())?.object)
        #expect(Set(root.keys) == ["pointer", "assertion", "credential"])
        let assertion = try #require(root["assertion"]?.object)
        #expect(Set(assertion.keys) == ["credentialId", "authenticatorData", "clientDataJSON", "signature"])
    }

    @Test
    func encodedRoundTripsThroughDecode() throws {
        let golden = try CatalogBundle.decode(Fixture.bundle())
        #expect(try CatalogBundle.decode(golden.encoded()) == golden)

        let smallest = try CatalogBundle(pointer: Self.bytes(1), credentialID: Self.bytes(1),
                                         authenticatorData: Self.bytes(1), clientDataJSON: Self.bytes(1),
                                         signature: Self.bytes(1), attestation: Self.bytes(1))
        #expect(try CatalogBundle.decode(smallest.encoded()) == smallest)

        let largest = try CatalogBundle(pointer: Self.bytes(1_024), credentialID: Self.bytes(1_023),
                                        authenticatorData: Self.bytes(4_096), clientDataJSON: Self.bytes(4_096),
                                        signature: Self.bytes(80), attestation: Self.bytes(4_096))
        let encoded = largest.encoded()
        #expect(encoded.count <= CatalogBundle.maxBytes)
        #expect(String(decoding: encoded, as: UTF8.self).contains("-"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("_"))
        #expect(try CatalogBundle.decode(encoded) == largest)
    }
}
