import Foundation
import Testing
@testable import ArkavoSocial

// Tests for the embedded content catalog (issue #1): cold-start discovery
// requires that a fetched CreatorProfile alone can hydrate ContentTicketCache.

// Whole-second date: ISO8601 serialization drops sub-second precision, and
// ContentTicket equality is synthesized over all fields including createdAt.
private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTicket(
    contentID: Data,
    version: Int = 1,
    creator: Data = Data(repeating: 0xAB, count: 32),
    ticket: String = "blobacme"
) -> ContentTicket {
    ContentTicket(
        ticket: ticket,
        contentID: contentID,
        version: version,
        creatorPublicID: creator,
        createdAt: fixedDate
    )
}

@Test func profileWithoutCatalogStillDecodes() throws {
    // Profiles published before contentCatalog existed must keep decoding:
    // round-trip a profile, strip the key at the JSON level, decode again.
    var profile = CreatorProfile(displayName: "Maker")
    profile.contentCatalog = [makeTicket(contentID: Data(repeating: 1, count: 32))]
    let data = try profile.toData()

    var json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    json.removeValue(forKey: "contentCatalog")
    let legacyData = try JSONSerialization.data(withJSONObject: json)

    let decoded = try CreatorProfile.fromData(legacyData)
    #expect(decoded.contentCatalog == nil)
    #expect(decoded.displayName == "Maker")
}

@Test func catalogRoundTripsThroughSerialization() throws {
    var profile = CreatorProfile(displayName: "Maker")
    let tickets = [
        makeTicket(contentID: Data(repeating: 1, count: 32), version: 2),
        makeTicket(contentID: Data(repeating: 2, count: 32), version: 1),
    ]
    profile.contentCatalog = tickets

    let decoded = try CreatorProfile.fromData(profile.toData())
    #expect(decoded.contentCatalog == tickets)
}

// ContentTicketCache is a process-wide singleton, so these tests run
// serialized and use content/creator IDs unique to each test — global
// cache counts are never asserted.
@Suite(.serialized)
struct ContentTicketCacheSeedTests {
    @Test func seedHydratesCacheForColdStart() async {
        let cache = ContentTicketCache.shared
        let creator = Data(repeating: 0xC1, count: 32)
        var profile = CreatorProfile(displayName: "Maker")
        profile.contentCatalog = [
            makeTicket(contentID: Data(repeating: 0x11, count: 32), creator: creator),
            makeTicket(contentID: Data(repeating: 0x12, count: 32), creator: creator),
        ]

        let updated = await cache.seed(from: profile)
        #expect(updated == 2)

        // The consumer catalog filter now sees the creator's content.
        let listed = await cache.tickets(for: creator)
        #expect(listed.count == 2)
    }

    @Test func seedDoesNotRollBackNewerCachedVersions() async {
        let cache = ContentTicketCache.shared
        let creator = Data(repeating: 0xC2, count: 32)
        let contentID = Data(repeating: 0x21, count: 32)
        await cache.cache(
            makeTicket(contentID: contentID, version: 5, creator: creator, ticket: "blobnewer"),
            for: contentID
        )

        var profile = CreatorProfile(displayName: "Maker")
        profile.contentCatalog = [
            makeTicket(contentID: contentID, version: 4, creator: creator, ticket: "blobstale"),
        ]

        let updated = await cache.seed(from: profile)
        #expect(updated == 0)
        let kept = await cache.ticket(for: contentID)
        #expect(kept?.ticket == "blobnewer")

        // A genuinely newer catalog entry does replace the cached one.
        profile.contentCatalog = [
            makeTicket(contentID: contentID, version: 6, creator: creator, ticket: "blobnewest"),
        ]
        let updatedNewer = await cache.seed(from: profile)
        #expect(updatedNewer == 1)
        let replaced = await cache.ticket(for: contentID)
        #expect(replaced?.ticket == "blobnewest")
    }

    @Test func seedWithNilCatalogIsNoOp() async {
        let cache = ContentTicketCache.shared
        let creator = Data(repeating: 0xC3, count: 32)
        let profile = CreatorProfile(displayName: "Maker")

        let updated = await cache.seed(from: profile)
        #expect(updated == 0)
        let listed = await cache.tickets(for: creator)
        #expect(listed.isEmpty)
    }
}
