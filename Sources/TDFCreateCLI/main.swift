import ArkavoMediaKit
import ArkavoSocial
import CryptoKit
import Darwin
import Foundation
import IrohSwift
import OpenTDFKit

/// TDF Create CLI - Creates TDF-protected content and publishes to Iroh
///
/// Usage:
///   tdf-create <input-file> [--kas-url URL] [--output FILE]
///
/// Examples:
///   tdf-create video.mov
///   tdf-create video.mov --kas-url https://100.arkavo.net
///   tdf-create video.mov --output protected.tdf

@main
struct TDFCreateCLI {
    static let defaultKASURL = URL(string: "https://100.arkavo.net")!

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

        var inputPath: String?
        var kasURL = defaultKASURL
        var outputPath: String?
        var publishToIroh = true
        var useRelay = true  // Default to relay for cross-device access
        var relayUrl: String? = nil  // Uses n0's public relay when nil
        var serveAfterPublish = false  // Keep node running to serve content
        var useHLSPackaging = false  // Package video as HLS for FairPlay DRM

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--kas-url":
                i += 1
                guard i < args.count, let url = URL(string: args[i]) else {
                    printError("Invalid KAS URL")
                    exit(1)
                }
                kasURL = url
            case "--output", "-o":
                i += 1
                guard i < args.count else {
                    printError("Missing output path")
                    exit(1)
                }
                outputPath = args[i]
            case "--no-publish":
                publishToIroh = false
            case "--relay":
                useRelay = true
            case "--no-relay":
                useRelay = false
            case "--relay-url":
                i += 1
                guard i < args.count else {
                    printError("Missing relay URL")
                    exit(1)
                }
                relayUrl = args[i]
                useRelay = true
            case "--serve":
                serveAfterPublish = true
            case "--hls":
                useHLSPackaging = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                if args[i].hasPrefix("-") {
                    printError("Unknown option: \(args[i])")
                    exit(1)
                }
                inputPath = args[i]
            }
            i += 1
        }

        guard let inputPath else {
            printError("Missing input file")
            printUsage()
            exit(1)
        }

        // Run main workflow
        do {
            try await run(
                inputPath: inputPath,
                kasURL: kasURL,
                outputPath: outputPath,
                publishToIroh: publishToIroh,
                useRelay: useRelay,
                relayUrl: relayUrl,
                serveAfterPublish: serveAfterPublish,
                useHLSPackaging: useHLSPackaging
            )
        } catch {
            printError("Failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(
        inputPath: String,
        kasURL: URL,
        outputPath: String?,
        publishToIroh: Bool,
        useRelay: Bool,
        relayUrl: String?,
        serveAfterPublish: Bool,
        useHLSPackaging: Bool
    ) async throws {
        print("============================================")
        print("TDF Create CLI")
        print("============================================")
        print("Input: \(inputPath)")
        print("KAS URL: \(kasURL)")
        print("Publish to Iroh: \(publishToIroh)")
        print("Relay: \(useRelay ? (relayUrl ?? "n0 public relay") : "disabled")")
        if useHLSPackaging {
            print("HLS Packaging: enabled (FairPlay compatible)")
        }
        print("============================================\n")

        // 1. Read input file
        print("Step 1: Reading input file...")
        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw CLIError.fileNotFound(inputPath)
        }

        // Determine MIME type from extension
        let mimeType = mimeTypeForExtension(inputURL.pathExtension)
        print("  MIME type: \(mimeType)")

        // Check if this is a video file for HLS packaging
        let isVideo = mimeType.hasPrefix("video/")
        if useHLSPackaging && !isVideo {
            print("  Warning: --hls flag is only applicable to video files, ignoring")
        }

        // Get original file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: inputPath)
        let originalFileSize = fileAttributes[.size] as? Int64 ?? 0
        print("  File size: \(originalFileSize) bytes")

        // 2. Generate asset ID
        let assetID = UUID().uuidString
        print("\nStep 2: Generated asset ID: \(assetID)")

        // 3. Create TDF protection
        print("\nStep 3: Creating TDF protection...")
        let tdfData: Data

        if useHLSPackaging && isVideo {
            // Use HLS packaging for video with FairPlay compatibility
            tdfData = try await createHLSTDF(
                inputURL: inputURL,
                kasURL: kasURL,
                assetID: assetID
            )
        } else {
            // Standard TDF protection for non-video or non-HLS mode
            let inputData = try Data(contentsOf: inputURL)
            print("  Read \(inputData.count) bytes")
            let protectionService = TDFProtectionService(kasURL: kasURL)
            tdfData = try await protectionService.protect(
                data: inputData,
                assetID: assetID,
                mimeType: mimeType
            )
        }
        print("  Created TDF archive: \(tdfData.count) bytes")

        // 4. Save TDF file if output path specified
        let tdfOutputPath: String
        if let outputPath {
            tdfOutputPath = outputPath
        } else {
            // Default output path
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            tdfOutputPath = "\(baseName).tdf"
        }

        print("\nStep 4: Saving TDF archive to \(tdfOutputPath)...")
        try tdfData.write(to: URL(fileURLWithPath: tdfOutputPath))
        print("  Saved!")

        // 5. Extract manifest for display
        print("\nStep 5: Verifying TDF archive...")
        let manifest = try TDFArchiveReader.extractManifest(from: tdfData)
        print("  Asset ID: \(manifest.assetID)")
        print("  Algorithm: \(manifest.algorithm)")
        print("  KAS URL: \(manifest.kasURL)")
        print("  Protected at: \(manifest.protectedAt)")

        // 6. Publish to Iroh
        if publishToIroh {
            print("\nStep 6: Publishing to Iroh network...")
            let config = IrohConfig(relayEnabled: useRelay, customRelayUrl: relayUrl)
            let node = try await IrohNode(config: config)

            // Publish TDF archive
            print("  Uploading TDF archive...")
            let payloadTicket = try await node.put(tdfData)
            print("  Payload ticket: \(payloadTicket.prefix(60))...")

            // Create and publish descriptor
            print("  Creating content descriptor...")
            let contentID = generateContentID(from: assetID)
            let descriptor = ContentDescriptor(
                id: UUID(),
                contentID: contentID,
                creatorPublicID: Data(repeating: 0, count: 32), // Placeholder
                manifest: manifest,
                payloadTicket: payloadTicket,
                payloadSize: Int64(tdfData.count),
                title: inputURL.lastPathComponent,
                mimeType: mimeType,
                durationSeconds: nil,
                originalFileSize: originalFileSize,
                createdAt: Date(),
                updatedAt: Date(),
                version: 1
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let descriptorData = try encoder.encode(descriptor)
            let descriptorTicket = try await node.put(descriptorData)

            print("\n============================================")
            print("SUCCESS!")
            print("============================================")
            print("\nTDF File: \(tdfOutputPath)")
            print("\nDescriptor Ticket (share this):")
            print(descriptorTicket)
            print("\nPayload Ticket (direct TDF access):")
            print(payloadTicket)
            print("============================================")

            if serveAfterPublish {
                print("\nServing content... Press Ctrl+C to stop.")
                print("Node is available via relay for remote downloads.")

                // Keep running until interrupted using async sleep
                signal(SIGINT) { _ in
                    print("\nShutting down...")
                    exit(0)
                }
                while true {
                    try await Task.sleep(for: .seconds(60))
                }
            } else {
                try await node.close()
            }
        } else {
            print("\n============================================")
            print("SUCCESS!")
            print("============================================")
            print("\nTDF File: \(tdfOutputPath)")
            print("Asset ID: \(assetID)")
            print("============================================")
        }
    }

    /// Create HLS-packaged TDF for video files (FairPlay compatible)
    ///
    /// Converts video to HLS segments, encrypts with AES-128-CBC,
    /// and packages everything into a single TDF archive.
    static func createHLSTDF(
        inputURL: URL,
        kasURL: URL,
        assetID: String
    ) async throws -> Data {
        // Create temp directory for HLS output
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 1. Convert video to HLS segments
        print("  Converting video to HLS segments...")
        let converter = HLSConverter()
        let hlsResult = try await converter.convert(
            videoURL: inputURL,
            outputDirectory: tempDir,
            segmentDuration: 6.0
        )
        print("    Created \(hlsResult.segmentURLs.count) segments")
        print("    Total duration: \(String(format: "%.1f", hlsResult.totalDuration))s")

        // 2. Fetch KAS RSA public key
        print("  Fetching KAS public key...")
        let kasPublicKeyPEM = try await fetchKASRSAPublicKey(kasURL: kasURL)

        // 3. Package HLS into TDF with encrypted segments
        print("  Packaging HLS into TDF archive...")
        let packager = HLSTDFPackager(
            kasURL: kasURL,
            kasPublicKeyPEM: kasPublicKeyPEM,
            keySize: .bits128,  // FairPlay requires 128-bit keys
            mode: .cbc         // FairPlay requires CBC mode
        )

        let tdfData = try await packager.package(
            hlsResult: hlsResult,
            assetID: assetID
        )

        return tdfData
    }

    /// Fetch KAS RSA public key for key wrapping
    static func fetchKASRSAPublicKey(kasURL: URL) async throws -> String {
        var components = URLComponents(url: kasURL, resolvingAgainstBaseURL: true)!
        components.path = "/kas/v2/kas_public_key"
        components.queryItems = [URLQueryItem(name: "algorithm", value: "rsa")]

        guard let url = components.url else {
            throw CLIError.invalidArgument("Invalid KAS URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw CLIError.invalidArgument("Failed to fetch KAS public key")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publicKey = json["public_key"] as? String
        else {
            throw CLIError.invalidArgument("Invalid KAS response format")
        }

        return publicKey
    }

    static func printUsage() {
        print("""
        TDF Create CLI - Creates TDF-protected content and publishes to Iroh

        Usage:
          tdf-create <input-file> [options]

        Options:
          --kas-url URL     KAS server URL (default: https://100.arkavo.net)
          --output, -o FILE Output TDF file path (default: <input>.tdf)
          --hls             Package video as HLS for FairPlay DRM playback
          --no-publish      Don't publish to Iroh, only create local TDF file
          --relay           Enable relay for NAT traversal (default: enabled, uses n0's public relay)
          --no-relay        Disable relay (direct connections only)
          --relay-url URL   Use custom relay URL instead of n0's public relay
          --serve           Keep node running to serve content after publishing
          --help, -h        Show this help message

        Examples:
          tdf-create video.mov
          tdf-create video.mov --hls
          tdf-create video.mov --hls --serve
          tdf-create video.mov --kas-url https://kas.example.com
          tdf-create video.mov --output protected.tdf --no-publish
        """)
    }

    static func printError(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }

    static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mov", "qt":
            "video/quicktime"
        case "mp4", "m4v":
            "video/mp4"
        case "avi":
            "video/x-msvideo"
        case "mkv":
            "video/x-matroska"
        case "webm":
            "video/webm"
        case "mp3":
            "audio/mpeg"
        case "m4a", "aac":
            "audio/mp4"
        case "wav":
            "audio/wav"
        case "flac":
            "audio/flac"
        case "jpg", "jpeg":
            "image/jpeg"
        case "png":
            "image/png"
        case "gif":
            "image/gif"
        case "pdf":
            "application/pdf"
        default:
            "application/octet-stream"
        }
    }

    static func generateContentID(from assetID: String) -> Data {
        let data = assetID.data(using: .utf8) ?? Data()
        return Data(SHA256.hash(data: data))
    }
}

enum CLIError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            "File not found: \(path)"
        case let .invalidArgument(msg):
            "Invalid argument: \(msg)"
        }
    }
}
