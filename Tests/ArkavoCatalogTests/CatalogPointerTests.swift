import Foundation
import Testing
@testable import ArkavoCatalog

/// `arkavo.catalog-pointer/1`: every refusal is one edit of the contract's pointer P7, and the builder writes P7 byte for
/// byte from its values.
struct CatalogPointerTests {
    private typealias Fixture = CatalogV2Fixture

    private static func edited(_ old: String, _ new: String) -> Data {
        precondition(Fixture.pointerText.contains(old))
        return Data(Fixture.pointerText.replacingOccurrences(of: old, with: new).utf8)
    }

    // MARK: Decoding

    @Test
    func decodesThePointerFixture() throws {
        let pointer = try CatalogPointer.decode(Fixture.pointer)
        #expect(Fixture.pointer.count == 224)
        #expect(pointer.owner == "0a1b2c3d-0000-4000-8000-000000000001")
        #expect(pointer.seq == 7)
        #expect(pointer.catalogHash == "729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7")
        #expect(pointer.catalogHash == Fixture.documentHash)
        #expect(pointer.catalogSize == 97)
        #expect(pointer.catalogSize == Fixture.document.count)
        #expect(pointer.issuedAt == Date(timeIntervalSince1970: 1_792_371_723))
        #expect(pointer.bytes == Fixture.pointer)
    }

    @Test
    func acceptsTheBoundaries() throws {
        #expect(CreatorCatalog.maxDocumentBytes == 524_288)
        #expect(try CatalogPointer.decode(Self.edited("\"seq\":7", "\"seq\":9007199254740991")).seq == 9_007_199_254_740_991)
        #expect(try CatalogPointer.decode(Self.edited("\"seq\":7", "\"seq\":1")).seq == 1)
        #expect(try CatalogPointer.decode(Self.edited("\"catalogSize\":97", "\"catalogSize\":524288")).catalogSize == 524_288)
        #expect(try CatalogPointer.decode(Self.edited("\"catalogSize\":97", "\"catalogSize\":1")).catalogSize == 1)
    }

    @Test
    func acceptsSurroundingWhitespaceAndKeepsTheBytes() throws {
        let padded = Data(" \n\t".utf8) + Fixture.pointer + Data("\r\n ".utf8)
        let pointer = try CatalogPointer.decode(padded)
        #expect(pointer.seq == 7)
        #expect(pointer.bytes == padded)
    }

    @Test
    func acceptsTheOwnerAndFieldOrderInAnyOrder() throws {
        let reordered = Data(
            #"{"issuedAt":"2026-10-19T01:02:03Z","catalogSize":97,"catalogHash":"729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7","seq":7,"owner":"a:b@c.d_e-f","schema":"arkavo.catalog-pointer/1"}"#.utf8)
        #expect(try CatalogPointer.decode(reordered).owner == "a:b@c.d_e-f")
    }

    struct Refusal: Sendable, CustomTestStringConvertible {
        let label: String
        let bytes: Data
        var testDescription: String { label }
    }

    private static let refusals: [Refusal] = [
        .init(label: "seq 0", bytes: edited("\"seq\":7", "\"seq\":0")),
        .init(label: "seq 2^53", bytes: edited("\"seq\":7", "\"seq\":9007199254740992")),
        .init(label: "seq 1.0", bytes: edited("\"seq\":7", "\"seq\":1.0")),
        .init(label: "seq 7e0", bytes: edited("\"seq\":7", "\"seq\":7e0")),
        .init(label: "seq -7", bytes: edited("\"seq\":7", "\"seq\":-7")),
        .init(label: "seq 07", bytes: edited("\"seq\":7", "\"seq\":07")),
        .init(label: "seq as a string", bytes: edited("\"seq\":7", "\"seq\":\"7\"")),
        .init(label: "catalogSize 0", bytes: edited("\"catalogSize\":97", "\"catalogSize\":0")),
        .init(label: "catalogSize 524289", bytes: edited("\"catalogSize\":97", "\"catalogSize\":524289")),
        .init(label: "catalogSize 97.0", bytes: edited("\"catalogSize\":97", "\"catalogSize\":97.0")),
        .init(label: "catalogSize as a string", bytes: edited("\"catalogSize\":97", "\"catalogSize\":\"97\"")),
        .init(label: "uppercase catalogHash", bytes: edited("729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7",
                                                             "729D79721D28362279F6E2A5A9E0F7B64A7E9097ADFA67207F41B615618D01E7")),
        .init(label: "short catalogHash", bytes: edited("729d79721d28362279f6e2a5a9e0f7b64a7e9097adfa67207f41b615618d01e7", "729d")),
        .init(label: "schema 2", bytes: edited("arkavo.catalog-pointer/1", "arkavo.catalog-pointer/2")),
        .init(label: "owner a/b", bytes: edited("0a1b2c3d-0000-4000-8000-000000000001", "a/b")),
        .init(label: "owner a..b", bytes: edited("0a1b2c3d-0000-4000-8000-000000000001", "a..b")),
        .init(label: "issuedAt with a fraction", bytes: edited("2026-10-19T01:02:03Z", "2026-10-19T01:02:03.000Z")),
        .init(label: "issuedAt on 30 February", bytes: edited("2026-10-19T01:02:03Z", "2026-02-30T00:00:00Z")),
        .init(label: "issuedAt with an offset", bytes: edited("2026-10-19T01:02:03Z", "2026-10-19T01:02:03+00:00")),
        .init(label: "an extra key", bytes: edited("\"seq\":7", "\"seq\":7,\"extra\":1")),
        .init(label: "a repeated seq", bytes: edited("\"seq\":7", "\"seq\":7,\"seq\":8")),
        .init(label: "a missing issuedAt", bytes: edited(",\"issuedAt\":\"2026-10-19T01:02:03Z\"", "")),
        .init(label: "a trailing x", bytes: Fixture.pointer + Data("x".utf8)),
        .init(label: "1025 bytes", bytes: edited("\"}", "\"}").dropLast() + Data(repeating: 0x20, count: 1_025 - 224) + Data("}".utf8)),
        .init(label: "a leading BOM", bytes: Data([0xEF, 0xBB, 0xBF]) + Fixture.pointer),
        .init(label: "not an object", bytes: Data("[]".utf8)),
        .init(label: "empty", bytes: Data()),
    ]

    @Test(arguments: refusals)
    func refusesWhatIsNotAPointer(_ refusal: Refusal) {
        #expect(throws: CatalogBundleError.pointer) { try CatalogPointer.decode(refusal.bytes) }
    }

    @Test
    func the1024ByteBoundaryIsAccepted() throws {
        let padding = Data(repeating: 0x20, count: 1_024 - Fixture.pointer.count)
        #expect(try CatalogPointer.decode(Fixture.pointer.dropLast() + padding + Data("}".utf8)).seq == 7)
    }

    // MARK: The builder

    /// The builder's inputs; the defaults are P7's values.
    struct Inputs: Sendable, CustomTestStringConvertible {
        let label: String
        var owner = CatalogV2Fixture.subject
        var seq: UInt64 = 7
        var catalogHash = CatalogV2Fixture.documentHash
        var catalogSize = 97
        var issuedAt = CatalogV2Fixture.pointerIssuedAt
        /// The `issuedAt` text an accepted case writes.
        var stamp = "2026-10-19T01:02:03Z"

        var testDescription: String { label }

        func build() throws(CatalogBundleError) -> CatalogPointer {
            try CatalogPointer(owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize, issuedAt: issuedAt)
        }

        /// What an accepted case writes: P7's key order, no whitespace, with these values.
        var expectedBytes: Data {
            CatalogV2Fixture.makePointer(owner: owner, seq: seq, catalogHash: catalogHash, catalogSize: catalogSize,
                                         issuedAt: stamp)
        }
    }

    private static let otherHash = String(repeating: "0123456789abcdef", count: 4)

    private static let builds: [Inputs] = [
        .init(label: "P7"),
        .init(label: "seq 1", seq: 1),
        .init(label: "seq 2^53 - 1", seq: CatalogPointer.maxSeq),
        .init(label: "catalogSize 1", catalogSize: 1),
        .init(label: "catalogSize 524288", catalogSize: 524_288),
        .init(label: "another catalogHash", catalogHash: otherHash),
        .init(label: "an owner of every allowed kind of byte", owner: "a:b@c.d_e-f"),
        .init(label: "an owner of 248 bytes", owner: String(repeating: "a", count: 248)),
        .init(label: "issuedAt with a fraction", issuedAt: Date(timeIntervalSince1970: 1_792_371_723.999)),
        .init(label: "issuedAt 1970", issuedAt: Date(timeIntervalSince1970: 0), stamp: "1970-01-01T00:00:00Z"),
        .init(label: "issuedAt half a second before 1970", issuedAt: Date(timeIntervalSince1970: -0.5),
              stamp: "1969-12-31T23:59:59Z"),
        .init(label: "issuedAt the first second of 0000", issuedAt: Date(timeIntervalSince1970: -62_167_219_200),
              stamp: "0000-01-01T00:00:00Z"),
        .init(label: "issuedAt the last second of 9999", issuedAt: Date(timeIntervalSince1970: 253_402_300_799.5),
              stamp: "9999-12-31T23:59:59Z"),
    ]

    @Test(arguments: builds)
    func theBuilderWritesTheContractBytes(_ inputs: Inputs) throws {
        let pointer = try inputs.build()
        #expect(pointer.bytes == inputs.expectedBytes)
        #expect(!pointer.bytes.contains(UInt8(ascii: " ")))
        #expect(Array(pointer.owner.utf8) == Array(inputs.owner.utf8))
        #expect(pointer.seq == inputs.seq)
        #expect(pointer.catalogHash == inputs.catalogHash)
        #expect(pointer.catalogSize == inputs.catalogSize)
        #expect(pointer.issuedAt == CatalogField.timestamp(inputs.stamp))
        #expect(try CatalogPointer.decode(pointer.bytes) == pointer)
    }

    @Test
    func theBuilderWritesP7() throws {
        let pointer = try CatalogPointer(owner: Fixture.subject, seq: 7, catalogHash: Fixture.documentHash, catalogSize: 97,
                                         issuedAt: Fixture.pointerIssuedAt)
        #expect(pointer.bytes == Fixture.pointer)
        #expect(String(decoding: pointer.bytes, as: UTF8.self) == Fixture.pointerText)
        #expect(try CatalogPointer.decode(Fixture.pointer) == pointer)
    }

    @Test
    func theBuilderRoundsIssuedAtDownToTheSecond() throws {
        let fraction = try CatalogPointer(owner: Fixture.subject, seq: 7, catalogHash: Fixture.documentHash,
                                          catalogSize: 97, issuedAt: Date(timeIntervalSince1970: 1_792_371_723.999))
        #expect(fraction.issuedAt == Date(timeIntervalSince1970: 1_792_371_723))
        #expect(fraction.bytes == Fixture.pointer)
        let beforeEpoch = try CatalogPointer(owner: Fixture.subject, seq: 7, catalogHash: Fixture.documentHash,
                                             catalogSize: 97, issuedAt: Date(timeIntervalSince1970: -0.5))
        #expect(beforeEpoch.issuedAt == Date(timeIntervalSince1970: -1))
        #expect(beforeEpoch.bytes == Fixture.makePointer(issuedAt: "1969-12-31T23:59:59Z"))
    }

    private static let builderRefusals: [Inputs] = [
        .init(label: "an empty owner", owner: ""),
        .init(label: "owner .", owner: "."),
        .init(label: "owner a..b", owner: "a..b"),
        .init(label: "owner a/b", owner: "a/b"),
        .init(label: "an owner with a quote", owner: "a\"b"),
        .init(label: "an owner with a backslash", owner: "a\\b"),
        .init(label: "an owner with a space", owner: "a b"),
        .init(label: "an owner that is not ASCII", owner: "cr\u{E9}ator"),
        .init(label: "an owner of 249 bytes", owner: String(repeating: "a", count: 249)),
        .init(label: "seq 0", seq: 0),
        .init(label: "seq 2^53", seq: CatalogPointer.maxSeq + 1),
        .init(label: "seq UInt64.max", seq: .max),
        .init(label: "an uppercase catalogHash", catalogHash: Fixture.documentHash.uppercased()),
        .init(label: "a catalogHash of 63 characters", catalogHash: String(Fixture.documentHash.dropLast())),
        .init(label: "a catalogHash of 65 characters", catalogHash: Fixture.documentHash + "0"),
        .init(label: "a catalogHash that is not hex", catalogHash: String(repeating: "g", count: 64)),
        .init(label: "an empty catalogHash", catalogHash: ""),
        .init(label: "catalogSize 0", catalogSize: 0),
        .init(label: "catalogSize 524289", catalogSize: 524_289),
        .init(label: "catalogSize -1", catalogSize: -1),
        .init(label: "catalogSize Int.max", catalogSize: .max),
        .init(label: "issuedAt the last second before 0000", issuedAt: Date(timeIntervalSince1970: -62_167_219_201)),
        .init(label: "issuedAt the first second of 10000", issuedAt: Date(timeIntervalSince1970: 253_402_300_800)),
        .init(label: "issuedAt far in the past", issuedAt: Date(timeIntervalSince1970: -1e15)),
        .init(label: "issuedAt far in the future", issuedAt: Date(timeIntervalSince1970: 1e15)),
    ]

    @Test(arguments: builderRefusals)
    func theBuilderRefusesAnInvalidField(_ inputs: Inputs) {
        #expect(throws: CatalogBundleError.pointer) { try inputs.build() }
    }

    // MARK: The next seq

    @Test
    func nextSeqIsOneMoreThanTheHigherOfTheTwo() {
        #expect(CatalogPointer.nextSeq(stored: nil, localHighest: nil) == 1)
        #expect(CatalogPointer.nextSeq(stored: 7, localHighest: nil) == 8)
        #expect(CatalogPointer.nextSeq(stored: nil, localHighest: 7) == 8)
        #expect(CatalogPointer.nextSeq(stored: 7, localHighest: 3) == 8)
        #expect(CatalogPointer.nextSeq(stored: 3, localHighest: 7) == 8)
        #expect(CatalogPointer.nextSeq(stored: 7, localHighest: 7) == 8)
        #expect(CatalogPointer.nextSeq(stored: CatalogPointer.maxSeq - 1, localHighest: 3) == CatalogPointer.maxSeq)
        #expect(CatalogPointer.nextSeq(stored: 3, localHighest: CatalogPointer.maxSeq - 1) == CatalogPointer.maxSeq)
    }

    @Test
    func nextSeqIsNilAtMaxSeq() {
        #expect(CatalogPointer.maxSeq == 9_007_199_254_740_991)
        #expect(CatalogPointer.nextSeq(stored: CatalogPointer.maxSeq, localHighest: nil) == nil)
        #expect(CatalogPointer.nextSeq(stored: nil, localHighest: CatalogPointer.maxSeq) == nil)
        #expect(CatalogPointer.nextSeq(stored: 1, localHighest: CatalogPointer.maxSeq) == nil)
        #expect(CatalogPointer.nextSeq(stored: CatalogPointer.maxSeq, localHighest: CatalogPointer.maxSeq) == nil)
        #expect(CatalogPointer.nextSeq(stored: .max, localHighest: nil) == nil)
    }
}
