import CryptoKit
import Foundation
import Testing
@testable import ArkavoCatalog

/// identity.arkavo.net's COSE_KeySet: the parser keeps every usable EC2 P-256 entry by kid.
struct IdentityKeySetParserTests {
    private typealias Fixture = CatalogV2Fixture

    @Test
    func theEntryBuilderReproducesTheGoldenSet() {
        #expect(TestCBOR.array([Fixture.keySetEntry()]).data == Fixture.goldenKeySet)
    }

    @Test
    func parsesTheGoldenKidSet() throws {
        let keys = try #require(IdentityKeySetParser.parse(Fixture.goldenKeySet))
        #expect(keys.count == 1)
        #expect(try #require(keys[Fixture.goldenKID]).x963Representation == Fixture.idpPublicKeyX963)
    }

    @Test
    func parsesTheLiveSet() throws {
        let keys = try #require(IdentityKeySetParser.parse(Fixture.liveKeySet))
        #expect(keys.count == 1)
        #expect(try #require(keys[Fixture.liveKID]).x963Representation == Fixture.livePublicKeyX963)
    }

    /// A retired key the set still lists is kept beside the current one.
    @Test
    func parsesASetOfTwoKids() throws {
        let keys = try #require(IdentityKeySetParser.parse(Fixture.goldenAndLiveKeySet))
        #expect(keys.count == 2)
        #expect(try #require(keys[Fixture.goldenKID]).x963Representation == Fixture.idpPublicKeyX963)
        #expect(try #require(keys[Fixture.liveKID]).x963Representation == Fixture.livePublicKeyX963)
    }

    /// Entries the parser skips. Each one comes before a good golden entry under its own kid, so a parser that kept it would
    /// return two keys.
    enum UnusableEntry: String, CaseIterable, Sendable {
        case noKid, emptyKid, kty3, crv2, x31Bytes, offCurve, repeatedIgnoredLabel, notAMap

        var entry: TestCBOR {
            let kid = Data("unusable-kid".utf8)
            let y = CatalogV2Fixture.idpPublicKeyX963[33..<65]
            switch self {
            case .noKid: return CatalogV2Fixture.keySetEntry(kid: nil)
            case .emptyKid: return CatalogV2Fixture.keySetEntry(kid: Data())
            case .kty3: return CatalogV2Fixture.keySetEntry(kid: kid, kty: .uint(3))
            case .crv2: return CatalogV2Fixture.keySetEntry(kid: kid, crv: .uint(2))
            case .x31Bytes: return CatalogV2Fixture.keySetEntry(kid: kid, x: CatalogV2Fixture.idpPublicKeyX963[1..<32])
            case .offCurve:
                var offCurve = Data(y)
                offCurve[offCurve.startIndex] ^= 0x01
                return CatalogV2Fixture.keySetEntry(kid: kid, y: offCurve)
            // alg (3) is ignored, but no label may appear twice.
            case .repeatedIgnoredLabel: return CatalogV2Fixture.keySetEntry(kid: kid, extra: [(.uint(3), .nint(6))])
            case .notAMap: return .array([.bytes(Array(kid))])
            }
        }
    }

    @Test(arguments: UnusableEntry.allCases)
    func skipsAnUnusableEntryBesideAGoodOne(_ unusable: UnusableEntry) throws {
        let set = TestCBOR.array([unusable.entry, Fixture.keySetEntry()]).data
        let keys = try #require(IdentityKeySetParser.parse(set))
        #expect(keys.count == 1)
        #expect(try #require(keys[Fixture.goldenKID]).x963Representation == Fixture.idpPublicKeyX963)
    }

    /// A set that cannot be used at all.
    enum UnusableSet: String, CaseIterable, Sendable {
        case onlyUnusableEntries, emptyArray, mapAtTheTop, trailingByte, goldenKidTwice, taggedArray, empty

        var data: Data {
            switch self {
            case .onlyUnusableEntries:
                return TestCBOR.array([IdentityKeySetParserTests.UnusableEntry.noKid.entry,
                                       IdentityKeySetParserTests.UnusableEntry.offCurve.entry]).data
            case .emptyArray: return TestCBOR.array([]).data
            case .mapAtTheTop: return Data(CatalogV2Fixture.goldenKeySet.dropFirst())
            case .trailingByte: return CatalogV2Fixture.goldenKeySet + Data([0x00])
            case .goldenKidTwice:
                let other = CatalogV2Fixture.livePublicKeyX963
                return TestCBOR.array([CatalogV2Fixture.keySetEntry(),
                                       CatalogV2Fixture.keySetEntry(x: other[1..<33], y: other[33..<65])]).data
            case .taggedArray: return TestCBOR.tag(18, .array([CatalogV2Fixture.keySetEntry()])).data
            case .empty: return Data()
            }
        }
    }

    @Test(arguments: UnusableSet.allCases)
    func anUnusableSetIsNil(_ unusable: UnusableSet) {
        #expect(IdentityKeySetParser.parse(unusable.data) == nil)
    }
}
