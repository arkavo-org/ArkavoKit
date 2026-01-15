import ArkavoSocial
import CryptoKit
import Darwin
import Foundation
import IrohSwift

/// TDF Fetch CLI - Fetches TDF content from Iroh and validates/plays it
///
/// Usage:
///   tdf-fetch <ticket> [--output FILE] [--server-url URL] [--validate-key]
///
/// Examples:
///   tdf-fetch blob...ticket
///   tdf-fetch blob...ticket --output video.tdf
///   tdf-fetch blob...ticket --validate-key

@main
struct TDFFetchCLI {
    static let defaultServerURL = URL(string: "https://100.arkavo.net")!

    static func main() async {
        // Unbuffered output
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        let args = CommandLine.arguments

        // Parse arguments
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        var ticket: String?
        var outputPath: String?
        var serverURL = defaultServerURL
        var validateKey = false
        var isPayloadTicket = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--output", "-o":
                i += 1
                guard i < args.count else {
                    printError("Missing output path")
                    exit(1)
                }
                outputPath = args[i]
            case "--server-url":
                i += 1
                guard i < args.count, let url = URL(string: args[i]) else {
                    printError("Invalid server URL")
                    exit(1)
                }
                serverURL = url
            case "--validate-key":
                validateKey = true
            case "--payload":
                isPayloadTicket = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                if args[i].hasPrefix("-") {
                    printError("Unknown option: \(args[i])")
                    exit(1)
                }
                ticket = args[i]
            }
            i += 1
        }

        guard let ticket else {
            printError("Missing ticket")
            printUsage()
            exit(1)
        }

        // Run main workflow
        do {
            try await run(
                ticket: ticket,
                outputPath: outputPath,
                serverURL: serverURL,
                validateKey: validateKey,
                isPayloadTicket: isPayloadTicket
            )
        } catch {
            printError("Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(
        ticket: String,
        outputPath: String?,
        serverURL: URL,
        validateKey: Bool,
        isPayloadTicket: Bool
    ) async throws {
        print("============================================")
        print("TDF Fetch CLI")
        print("============================================")
        print("Ticket: \(ticket.prefix(60))...")
        print("Server URL: \(serverURL)")
        print("Validate key: \(validateKey)")
        print("============================================\n")

        // 1. Create Iroh node
        print("Step 1: Initializing Iroh node...")
        let node = try await IrohNode()
        print("  Node ready!")

        var tdfData: Data
        var descriptor: ContentDescriptor?

        if isPayloadTicket {
            // Direct payload fetch
            print("\nStep 2: Fetching TDF payload directly...")
            tdfData = try await node.get(ticket: ticket)
            print("  Downloaded \(tdfData.count) bytes")
        } else {
            // Fetch descriptor first
            print("\nStep 2: Fetching content descriptor...")
            let descriptorData = try await node.get(ticket: ticket)
            print("  Downloaded descriptor: \(descriptorData.count) bytes")

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            descriptor = try decoder.decode(ContentDescriptor.self, from: descriptorData)

            print("\n  Content Descriptor:")
            print("  ------------------")
            print("  ID: \(descriptor!.id)")
            print("  Title: \(descriptor!.title)")
            print("  MIME Type: \(descriptor!.mimeType)")
            print("  Original Size: \(descriptor!.originalFileSize) bytes")
            print("  TDF Size: \(descriptor!.payloadSize) bytes")
            print("  Created: \(descriptor!.createdAt)")

            // Fetch TDF payload
            print("\nStep 3: Fetching TDF payload...")
            tdfData = try await node.get(ticket: descriptor!.payloadTicket)
            print("  Downloaded \(tdfData.count) bytes")
        }

        // 4. Extract and display manifest
        print("\nStep 4: Extracting TDF manifest...")
        let manifest = try TDFArchiveReader.extractManifest(from: tdfData)
        print("\n  TDF Manifest:")
        print("  -------------")
        print("  Asset ID: \(manifest.assetID)")
        print("  Algorithm: \(manifest.algorithm)")
        print("  KAS URL: \(manifest.kasURL)")
        print("  IV: \(manifest.iv.prefix(20))...")
        print("  Wrapped Key: \(manifest.wrappedKey.prefix(40))...")
        print("  Protected At: \(manifest.protectedAt)")

        // 5. Extract payload
        print("\nStep 5: Extracting encrypted payload...")
        let payload = try TDFArchiveReader.extractPayload(from: tdfData)
        print("  Encrypted payload: \(payload.count) bytes")

        // 6. Save output if requested
        if let outputPath {
            print("\nStep 6: Saving TDF archive to \(outputPath)...")
            try tdfData.write(to: URL(fileURLWithPath: outputPath))
            print("  Saved!")
        }

        // 7. Validate key request (optional)
        if validateKey {
            print("\nStep 7: Validating FairPlay key request...")
            try await validateKeyRequest(
                manifest: manifest,
                serverURL: serverURL
            )
        }

        // Close node
        try await node.close()

        print("\n============================================")
        print("SUCCESS!")
        print("============================================")
        print("\nContent ready for FairPlay playback.")
        if let outputPath {
            print("TDF saved to: \(outputPath)")
        }
        if let desc = descriptor {
            print("Title: \(desc.title)")
        }
        print("Asset ID: \(manifest.assetID)")
        print("============================================")
    }

    static func validateKeyRequest(
        manifest: TDFManifestLite,
        serverURL: URL
    ) async throws {
        print("  Fetching FairPlay certificate...")

        // Fetch certificate
        let certURL = serverURL.appendingPathComponent("media/v1/certificate")
        let (certData, certResponse) = try await URLSession.shared.data(from: certURL)

        guard let httpResponse = certResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw FetchError.certificateFetchFailed
        }
        print("  Certificate: \(certData.count) bytes")

        // In a real implementation, we would:
        // 1. Create an AVContentKeySession
        // 2. Generate SPC using the certificate
        // 3. Send SPC + manifest to /media/v1/key-request
        // 4. Receive CKC

        // For CLI, we just verify the certificate endpoint works
        // and the manifest format is correct
        print("  Certificate endpoint: OK")

        // Verify manifest has required fields
        guard !manifest.wrappedKey.isEmpty,
              !manifest.iv.isEmpty,
              !manifest.kasURL.isEmpty
        else {
            throw FetchError.invalidManifest
        }
        print("  Manifest format: OK")

        // Try to decode the wrapped key to verify it's valid base64
        guard Data(base64Encoded: manifest.wrappedKey) != nil else {
            throw FetchError.invalidWrappedKey
        }
        print("  Wrapped key format: OK")

        // Try to decode IV
        guard Data(base64Encoded: manifest.iv) != nil else {
            throw FetchError.invalidIV
        }
        print("  IV format: OK")

        print("  Key request validation: PASSED")
    }

    static func printUsage() {
        print("""
        TDF Fetch CLI - Fetches TDF content from Iroh and validates it

        Usage:
          tdf-fetch <ticket> [options]

        Options:
          --output, -o FILE  Save TDF archive to file
          --server-url URL   Server URL for key validation (default: https://100.arkavo.net)
          --validate-key     Validate FairPlay certificate and manifest format
          --payload          Treat ticket as direct payload ticket (not descriptor)
          --help, -h         Show this help message

        Examples:
          tdf-fetch blob...ticket
          tdf-fetch blob...ticket --output video.tdf
          tdf-fetch blob...ticket --validate-key
          tdf-fetch blob...ticket --payload --output direct.tdf
        """)
    }

    static func printError(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }
}

enum FetchError: Error, LocalizedError {
    case certificateFetchFailed
    case invalidManifest
    case invalidWrappedKey
    case invalidIV
    case keyRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .certificateFetchFailed:
            "Failed to fetch FairPlay certificate from server"
        case .invalidManifest:
            "TDF manifest is missing required fields"
        case .invalidWrappedKey:
            "Wrapped key is not valid base64"
        case .invalidIV:
            "IV is not valid base64"
        case let .keyRequestFailed(msg):
            "Key request failed: \(msg)"
        }
    }
}
