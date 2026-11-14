import Foundation
import Testing
@testable import ArkavoCatalog

/// The shared vectors in `Vectors/catalog-vectors.json`: each document, index, metadata payload and pointer must decode
/// exactly when it is marked valid. The node runs the index and pointer vectors against its own parser, so the two agree.
struct CatalogVectorTests {
    struct Vector: Decodable, CustomTestStringConvertible {
        let kind: String
        let name: String
        let valid: Bool
        let text: String?
        let base64: String?
        /// On an `index` vector: the lowercase hex SHA-256 of its canonical form, which a `/2` pointer signs.
        let indexHash: String?

        var bytes: Data { text.map { Data($0.utf8) } ?? Data(base64Encoded: base64 ?? "") ?? Data() }
        var testDescription: String { "\(kind): \(name)" }
    }

    struct File: Decodable {
        let vectors: [Vector]
    }

    static let vectors: [Vector] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Vectors/catalog-vectors.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.vectors
    }()

    @Test func theVectorsLoad() {
        #expect(Self.vectors.count > 100)
        for kind in ["document", "index", "metadata", "pointer"] {
            #expect(Self.vectors.contains { $0.kind == kind && $0.valid })
            #expect(Self.vectors.contains { $0.kind == kind && !$0.valid })
        }
        // Both pointer schemas: `/2`, and `/1` as the node still serves it.
        let pointers = Self.vectors.filter { $0.kind == "pointer" && $0.valid }.compactMap {
            try? CatalogPointer.decode($0.bytes)
        }
        #expect(pointers.contains { $0.indexHash != nil })
        #expect(pointers.contains { $0.indexHash == nil })
        // The node's three `index_hash_vectors`.
        #expect(Self.vectors.filter { $0.indexHash != nil }.map(\.name)
            == ["indexHash: empty", "indexHash: two, given out of order", "indexHash: byte order"])
    }

    /// A pointer or an index entry is a JSON object. The same values as an array, in the schema's key order, are refused,
    /// which a reader that deserializes a struct from a sequence would accept.
    @Test func arrayFormsAreRefused() throws {
        let names = ["pointer": ["/1 pointer as an array", "/2 pointer as an array"], "index": ["index entry as an array"]]
        for (kind, names) in names {
            for name in names {
                let vector = try #require(Self.vectors.first { $0.kind == kind && $0.name == name }, "\(kind): \(name)")
                #expect(!vector.valid)
                #expect(vector.text?.hasPrefix("[") == true)
            }
        }
        let pointers = Self.vectors.filter { $0.kind == "pointer" && $0.name.hasSuffix("as an array") }
        #expect(pointers.count == 2)
        for vector in pointers {
            #expect(throws: CatalogBundleError.pointer) { try CatalogPointer.decode(vector.bytes) }
        }
        let index = try #require(Self.vectors.first { $0.kind == "index" && $0.name == "index entry as an array" })
        #expect(throws: CreatorCatalogError.entryKeys(0)) { try CreatorCatalog.decodeIndex(index.bytes) }
    }

    /// An index vector's `indexHash` is the SHA-256 of its canonical form, as the node computes it from the parsed
    /// entries, and as `canonicalIndexHash()` computes it for the catalog listing them.
    @Test(arguments: vectors.filter { $0.indexHash != nil })
    func indexHashIsTheCanonicalIndexsSHA256(_ vector: Vector) throws {
        #expect(vector.kind == "index")
        #expect(vector.valid)
        let entries = try CreatorCatalog.decodeIndex(vector.bytes)
        #expect(CreatorCatalog.indexHash(entries) == vector.indexHash)
        let catalog = CreatorCatalog(owner: CreatorCatalogTests.owner, entries: entries.map {
            CreatorCatalog.Entry(contentID: $0.contentID, version: $0.version, payloadHash: $0.payloadHash,
                                 payloadSize: $0.payloadSize, metadata: CreatorCatalogTests.metadata)
        })
        #expect(try catalog.canonicalIndexHash() == vector.indexHash)
    }

    @Test(arguments: vectors)
    func vectorDecodesExactlyWhenValid(_ vector: Vector) {
        let accepted = switch vector.kind {
        case "document": (try? CreatorCatalog.decode(vector.bytes)) != nil
        case "index": (try? CreatorCatalog.decodeIndex(vector.bytes)) != nil
        case "metadata": (try? CatalogEntryMetadata.decode(vector.bytes)) != nil
        case "pointer": (try? CatalogPointer.decode(vector.bytes)) != nil
        default: !vector.valid
        }
        #expect(accepted == vector.valid)
    }

    /// What the encoders write decodes to the same value, so a valid vector survives a decode and re-encode.
    @Test(arguments: vectors.filter { $0.valid && ($0.kind == "document" || $0.kind == "metadata") })
    func validVectorRoundTrips(_ vector: Vector) throws {
        if vector.kind == "document" {
            let catalog = try CreatorCatalog.decode(vector.bytes)
            #expect(try CreatorCatalog.decode(catalog.encoded()) == catalog)
        } else {
            let metadata = try CatalogEntryMetadata.decode(vector.bytes)
            #expect(try CatalogEntryMetadata.decode(metadata.encoded()) == metadata)
        }
    }
}
