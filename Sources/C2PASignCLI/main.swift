import ArkavoC2PA
import AVFoundation
import Foundation

/// C2PA Sign CLI — signs a MOV/MP4/M4A through the arkavo-rs signing server and
/// checks the result with `c2patool`
///
/// Usage:
///   c2pa-sign <input> <output> [--server URL] [--title T] [--creator C]
///             [--token CWT] [--trust-anchors ca.pem] [--force]
///
/// Checks:
///   1. c2patool reports validation_state Valid (Trusted with --trust-anchors),
///      with assertion.dataHash.match and claimSignature.validated
///   2. a copy with one flipped media byte reports assertion.dataHash.mismatch
///   3. AVFoundation reads the same duration from the signed file as the input
@main
struct C2PASignCLI {
    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        guard let options = Options(arguments: Array(CommandLine.arguments.dropFirst())) else {
            printUsage()
            exit(1)
        }
        guard let c2patool = findExecutable("c2patool") else {
            printError("c2patool not found in PATH (brew install c2patool)")
            exit(1)
        }
        if options.force {
            try? FileManager.default.removeItem(at: options.output)
        }

        print("============================================")
        print("C2PA Sign CLI")
        print("============================================")
        print("Input:    \(options.input.path)")
        print("Output:   \(options.output.path)")
        print("Server:   \(options.serverURL)")
        print("Token:    \(options.token == nil ? "none" : "identity.arkavo.net bearer")")
        print("c2patool: \(c2patool.path)")
        print("============================================")

        let token = options.token
        let signer = C2PAServerSigner(service: C2PASigningService(
            serverURL: options.serverURL,
            accessToken: { token }
        ))
        let metadata = C2PASigningMetadata(
            title: options.title,
            creator: options.creator,
            aiGenerated: false,
            software: "ArkavoKit c2pa-sign"
        )

        print("\n--- Sign ---")
        let embedded: C2PAEmbeddedManifest
        do {
            embedded = try await signer.sign(inputFile: options.input, outputFile: options.output, metadata: metadata)
        } catch {
            print("  FAIL: \(error.localizedDescription)")
            exit(1)
        }
        print("  content_hash:   \(embedded.contentHash)")
        print("  manifest box:   bytes \(embedded.manifestRange.lowerBound)..<\(embedded.manifestRange.upperBound)"
            + " (\(embedded.manifestRange.count) bytes)")
        print("  sign requests:  \(embedded.requestCount)")

        var passed = 0
        var failed = 0
        func check(_ name: String, _ block: () async throws -> Void) async {
            print("\n--- \(name) ---")
            do {
                try await block()
                print("  PASS")
                passed += 1
            } catch {
                print("  FAIL: \(error.localizedDescription)")
                failed += 1
            }
        }

        await check("c2patool validation") {
            let report = try C2PAToolReport(c2patool: c2patool, file: options.output, trustAnchors: options.trustAnchors)
            let expectedState = options.trustAnchors == nil ? "Valid" : "Trusted"
            print("  validation_state:  \(report.state)")
            print("  validation_status: \(report.failures.isEmpty ? "[]" : report.failures.joined(separator: ", "))")
            print("  title:             \(report.title ?? "-")")
            print("  signer:            \(report.issuer ?? "-")")
            for code in ["assertion.dataHash.match", "claimSignature.validated"] {
                guard report.successes.contains(code) else {
                    throw CheckError("missing \(code)")
                }
            }
            guard report.state == expectedState else {
                throw CheckError("expected \(expectedState), got \(report.state)")
            }
        }

        await check("c2patool detects tampering") {
            let tampered = FileManager.default.temporaryDirectory
                .appendingPathComponent("c2pa-sign-tampered-\(UUID().uuidString).\(options.output.pathExtension)")
            defer { try? FileManager.default.removeItem(at: tampered) }
            try FileManager.default.copyItem(at: options.output, to: tampered)
            // Halfway between the manifest box and the end of the file: media, not ftyp.
            let fileSize = try FileManager.default.attributesOfItem(atPath: tampered.path)[.size] as? UInt64 ?? 0
            let offset = (embedded.manifestRange.upperBound + fileSize) / 2
            let handle = try FileHandle(forUpdating: tampered)
            try handle.seek(toOffset: offset)
            let byte = try handle.read(upToCount: 1) ?? Data([0])
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([byte[byte.startIndex] ^ 0xFF]))
            try handle.close()

            let report = try C2PAToolReport(c2patool: c2patool, file: tampered, trustAnchors: options.trustAnchors)
            print("  flipped byte at:   \(offset)")
            print("  validation_state:  \(report.state)")
            guard report.failures.contains("assertion.dataHash.mismatch") else {
                throw CheckError("expected assertion.dataHash.mismatch, got \(report.failures)")
            }
        }

        await check("signed file still plays") {
            let original = try await AVURLAsset(url: options.input).load(.duration)
            let signed = try await AVURLAsset(url: options.output).load(.duration)
            print("  duration in/out:   \(original.seconds)s / \(signed.seconds)s")
            guard signed.seconds > 0, signed == original else {
                throw CheckError("durations differ")
            }
        }

        print("\n============================================")
        print("Results: \(passed) passed, \(failed) failed")
        print("============================================")
        exit(failed > 0 ? 1 : 0)
    }

    static func printUsage() {
        print("""
        C2PA Sign CLI — signs a MOV/MP4/M4A through the arkavo-rs signing server
        and checks the result with c2patool

        Usage:
          c2pa-sign <input> <output> [options]

        Options:
          --server URL          Signing server (default: \(C2PASigningService.defaultServerURL))
          --title TITLE         Manifest title (default: input file name)
          --creator NAME        Creator sent in the metadata (default: Arkavo c2pa-sign);
                                platform.arkavo.net records the token's subject instead
          --token CWT           identity.arkavo.net passkey token sent as the bearer
                                (default: $ARKAVO_TOKEN)
          --trust-anchors PEM   Trust these CAs; expects Trusted instead of Valid
          --force               Replace the output file if it exists
        """)
    }

    static func printError(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }

    static func findExecutable(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct Options {
    let input: URL
    let output: URL
    var serverURL = C2PASigningService.defaultServerURL
    var title: String
    var creator = "Arkavo c2pa-sign"
    var token: String?
    var trustAnchors: URL?
    var force = false

    init?(arguments: [String]) {
        var positional: [String] = []
        var serverURL: URL?
        var title: String?
        var creator: String?
        var token = ProcessInfo.processInfo.environment["ARKAVO_TOKEN"]
        var trustAnchors: URL?
        var force = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--server":
                guard let value = iterator.next(), let url = URL(string: value) else { return nil }
                serverURL = url
            case "--title":
                guard let value = iterator.next() else { return nil }
                title = value
            case "--creator":
                guard let value = iterator.next() else { return nil }
                creator = value
            case "--token":
                guard let value = iterator.next() else { return nil }
                token = value
            case "--trust-anchors":
                guard let value = iterator.next() else { return nil }
                trustAnchors = URL(fileURLWithPath: value)
            case "--force":
                force = true
            default:
                guard !argument.hasPrefix("--") else { return nil }
                positional.append(argument)
            }
        }
        guard positional.count == 2 else { return nil }

        input = URL(fileURLWithPath: positional[0])
        output = URL(fileURLWithPath: positional[1])
        self.title = title ?? input.lastPathComponent
        if let serverURL { self.serverURL = serverURL }
        if let creator { self.creator = creator }
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.trustAnchors = trustAnchors
        self.force = force
    }
}

/// The parts of `c2patool <file>` JSON output the checks need
struct C2PAToolReport {
    let state: String
    let failures: [String]
    let successes: [String]
    let title: String?
    let issuer: String?

    init(c2patool: URL, file: URL, trustAnchors: URL?) throws {
        let process = Process()
        process.executableURL = c2patool
        process.arguments = [file.path] + (trustAnchors.map { ["trust", "--trust_anchors", $0.path] } ?? [])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError("c2patool exited \(process.terminationStatus): "
                + String(decoding: errorOutput.isEmpty ? data : errorOutput, as: UTF8.self))
        }
        state = json["validation_state"] as? String ?? "unknown"
        failures = (json["validation_status"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        let results = (json["validation_results"] as? [String: Any])?["activeManifest"] as? [String: Any]
        successes = (results?["success"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        let manifests = json["manifests"] as? [String: Any]
        let active = (json["active_manifest"] as? String).flatMap { manifests?[$0] as? [String: Any] }
        title = active?["title"] as? String
        let signature = active?["signature_info"] as? [String: Any]
        issuer = [signature?["common_name"] as? String, signature?["issuer"] as? String]
            .compactMap { $0 }.joined(separator: " / ")
    }
}

struct CheckError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
