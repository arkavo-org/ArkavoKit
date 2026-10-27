import Foundation
import Testing
@testable import ArkavoCatalog

/// The shared vectors in `Vectors/catalog-vectors.json`: each document, metadata payload and pointer must decode exactly
/// when it is marked valid. The node runs the document and pointer vectors against its own parser, so the readers agree.
struct CatalogVectorTests {
    struct Vector: Decodable, CustomTestStringConvertible {
        let kind: String
        let name: String
        let valid: Bool
        let text: String?
        let base64: String?

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
        for kind in ["document", "metadata", "pointer"] {
            #expect(Self.vectors.contains { $0.kind == kind && $0.valid })
            #expect(Self.vectors.contains { $0.kind == kind && !$0.valid })
        }
    }

    @Test(arguments: vectors)
    func vectorDecodesExactlyWhenValid(_ vector: Vector) {
        let accepted = switch vector.kind {
        case "document": (try? CreatorCatalog.decode(vector.bytes)) != nil
        case "metadata": (try? CatalogEntryMetadata.decode(vector.bytes)) != nil
        case "pointer": (try? CatalogPointer.decode(vector.bytes)) != nil
        default: !vector.valid
        }
        #expect(accepted == vector.valid)
    }

    /// What the encoders write decodes to the same value, so a valid vector survives a decode and re-encode.
    @Test(arguments: vectors.filter { $0.valid && $0.kind != "pointer" })
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
