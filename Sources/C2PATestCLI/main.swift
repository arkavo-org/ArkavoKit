import ArkavoC2PA
import CryptoKit
import Foundation

/// C2PA Test CLI — exercises the C2PA FFI bridge and server endpoints
///
/// Usage:
///   c2pa-test <logo.png> <cert.pem> <key.pem> [--server URL]
///
/// Examples:
///   c2pa-test tests/data/logo.png tests/data/cert.pem tests/data/private.pem
///   c2pa-test tests/data/logo.png tests/data/cert.pem tests/data/private.pem --server https://100.arkavo.net
@main
struct C2PATestCLI {
    static let defaultServerURL = URL(string: "https://100.arkavo.net")!

    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        let args = CommandLine.arguments

        guard args.count >= 4 else {
            printUsage()
            exit(1)
        }

        let logoPath = args[1]
        let certPath = args[2]
        let keyPath = args[3]

        var serverURL = defaultServerURL
        if args.count >= 6, args[4] == "--server",
           let url = URL(string: args[5])
        {
            serverURL = url
        }

        // Validate input files exist
        for (path, label) in [(logoPath, "logo"), (certPath, "cert"), (keyPath, "key")] {
            guard FileManager.default.fileExists(atPath: path) else {
                printError("File not found: \(path) (\(label))")
                exit(1)
            }
        }

        var passed = 0
        var failed = 0

        func check(_ name: String, _ block: () async throws -> Void) async {
            print("\n--- \(name) ---")
            do {
                try await block()
                print("  PASS")
                passed += 1
            } catch {
                print("  FAIL: \(error)")
                failed += 1
            }
        }

        // Read cert and key
        let certPEM: String
        let keyPEM: String
        do {
            certPEM = try String(contentsOfFile: certPath, encoding: .utf8)
            keyPEM = try String(contentsOfFile: keyPath, encoding: .utf8)
        } catch {
            printError("Failed to read cert/key files: \(error)")
            exit(1)
        }

        let inputURL = URL(fileURLWithPath: logoPath)

        print("============================================")
        print("C2PA Test CLI")
        print("============================================")
        print("Input:  \(logoPath)")
        print("Cert:   \(certPath)")
        print("Key:    \(keyPath)")
        print("Server: \(serverURL)")
        print("============================================")

        // ---------------------------------------------------------------
        // Test 1: Sign a file
        // ---------------------------------------------------------------
        let signedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2pa_test_signed.png")
        // Clean up any previous test output
        try? FileManager.default.removeItem(at: signedURL)

        await check("FFI sign") {
            let signer = try C2PASigner(signingMode: .pemFiles(certPEM: certPEM, keyPEM: keyPEM))
            var builder = C2PAManifestBuilder(title: "CLI Integration Test", format: "image/png")
            _ = builder.addCreatedAction()
            _ = builder.addAuthor(name: "C2PA Test CLI")
            let manifest = builder.build()

            try await signer.sign(
                inputFile: inputURL,
                outputFile: signedURL,
                manifest: manifest
            )

            // Verify output is larger than input
            let inputSize = try FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64 ?? 0
            let outputSize = try FileManager.default.attributesOfItem(atPath: signedURL.path)[.size] as? Int64 ?? 0
            print("  Input size:  \(inputSize) bytes")
            print("  Output size: \(outputSize) bytes")
            guard outputSize > inputSize else {
                throw TestError.assertion("signed file (\(outputSize)) should be larger than input (\(inputSize))")
            }
        }

        // ---------------------------------------------------------------
        // Test 2: Verify the signed file
        // ---------------------------------------------------------------
        await check("FFI verify") {
            let signer = try C2PASigner(signingMode: .pemFiles(certPEM: certPEM, keyPEM: keyPEM))
            let result = try await signer.verify(file: signedURL)
            print("  has_manifest: \(result.hasManifest)")
            print("  is_valid:     \(result.isValid)")
            print("  manifest_json length: \(result.manifestJSON.count)")
            guard result.hasManifest else {
                throw TestError.assertion("signed file should have a manifest")
            }
        }

        // ---------------------------------------------------------------
        // Test 3: Info on the signed file
        // ---------------------------------------------------------------
        await check("FFI info") {
            let signer = try C2PASigner(signingMode: .pemFiles(certPEM: certPEM, keyPEM: keyPEM))
            let info = try await signer.info(file: signedURL)
            print("  has_manifest: \(info.hasManifest)")
            print("  raw output length: \(info.rawOutput.count)")
            guard info.hasManifest else {
                throw TestError.assertion("signed file info should indicate a manifest")
            }
            guard info.rawOutput.contains("CLI Integration Test") else {
                throw TestError.assertion("info should contain manifest title")
            }
        }

        // ---------------------------------------------------------------
        // Test 4: Verify an unsigned file (should report no manifest)
        // ---------------------------------------------------------------
        await check("FFI verify unsigned") {
            let signer = try C2PASigner(signingMode: .pemFiles(certPEM: certPEM, keyPEM: keyPEM))
            let result = try await signer.verify(file: inputURL)
            print("  has_manifest: \(result.hasManifest)")
            print("  is_valid:     \(result.isValid)")
            guard !result.hasManifest else {
                throw TestError.assertion("unsigned file should have no manifest")
            }
        }

        // ---------------------------------------------------------------
        // Test 5: Server sign endpoint
        // ---------------------------------------------------------------
        await check("Server /c2pa/v1/sign") {
            let logoData = try Data(contentsOf: inputURL)
            let hash = SHA256.hash(data: logoData)
            let hashHex = hash.map { String(format: "%02x", $0) }.joined()

            let body: [String: Any] = [
                "content_hash": hashHex,
                "hash_algorithm": "SHA-256",
                "exclusion_ranges": [] as [Any],
                "container_format": "mov",
                "metadata": [
                    "title": "C2PA Test CLI",
                    "creator": "Arkavo C2PA Test",
                ] as [String: String],
            ]

            let url = serverURL.appendingPathComponent("c2pa/v1/sign")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            print("  Status: \(statusCode)")

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TestError.assertion("response should be JSON object")
            }
            print("  Response keys: \(json.keys.sorted())")

            let status = json["status"] as? String ?? "unknown"
            print("  status: \(status)")
            guard status == "success" else {
                throw TestError.assertion("server should return success, got: \(status) - \(json)")
            }
            guard json["manifest"] is String else {
                throw TestError.assertion("response should include manifest string")
            }
            if let manifestHash = json["manifest_hash"] as? String {
                print("  manifest_hash: \(manifestHash.prefix(16))...")
            }
        }

        // ---------------------------------------------------------------
        // Test 6: Server sign + validate roundtrip
        // ---------------------------------------------------------------
        await check("Server sign + validate roundtrip") {
            let logoData = try Data(contentsOf: inputURL)
            let hash = SHA256.hash(data: logoData)
            let hashHex = hash.map { String(format: "%02x", $0) }.joined()

            // Sign
            let signBody: [String: Any] = [
                "content_hash": hashHex,
                "hash_algorithm": "SHA-256",
                "exclusion_ranges": [] as [Any],
                "container_format": "mov",
                "metadata": [
                    "title": "Roundtrip Test",
                    "creator": "Arkavo C2PA Test",
                ] as [String: String],
            ]

            let signURL = serverURL.appendingPathComponent("c2pa/v1/sign")
            var signReq = URLRequest(url: signURL)
            signReq.httpMethod = "POST"
            signReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            signReq.httpBody = try JSONSerialization.data(withJSONObject: signBody)

            let (signData, signResponse) = try await URLSession.shared.data(for: signReq)
            let signStatus = (signResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard signStatus == 200,
                  let signJSON = try JSONSerialization.jsonObject(with: signData) as? [String: Any],
                  let manifest = signJSON["manifest"] as? String,
                  let manifestHash = signJSON["manifest_hash"] as? String
            else {
                let body = String(data: signData, encoding: .utf8) ?? "?"
                throw TestError.assertion("sign failed (HTTP \(signStatus)): \(body)")
            }
            print("  Signed manifest length: \(manifest.count)")
            print("  Manifest hash: \(manifestHash.prefix(16))...")

            // Validate
            let validateBody: [String: Any] = [
                "manifest": manifest,
                "content_hash": hashHex,
                "manifest_hash": manifestHash,
            ]

            let validateURL = serverURL.appendingPathComponent("c2pa/v1/validate")
            var validateReq = URLRequest(url: validateURL)
            validateReq.httpMethod = "POST"
            validateReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            validateReq.httpBody = try JSONSerialization.data(withJSONObject: validateBody)

            let (validateData, validateResponse) = try await URLSession.shared.data(for: validateReq)
            let valStatus = (validateResponse as? HTTPURLResponse)?.statusCode ?? 0
            print("  Validate HTTP status: \(valStatus)")

            guard let validateJSON = try JSONSerialization.jsonObject(with: validateData) as? [String: Any] else {
                throw TestError.assertion("validate response should be JSON")
            }

            print("  Response keys: \(validateJSON.keys.sorted())")
            if let errors = validateJSON["errors"] as? [Any] {
                print("  Validation errors: \(errors)")
            }
            if let chain = validateJSON["provenance_chain"] as? [[String: Any]] {
                for entry in chain {
                    print("  Provenance: action=\(entry["action"] ?? "?"), timestamp=\(entry["timestamp"] ?? "?")")
                }
            }
            if let creator = validateJSON["creator"] as? String {
                print("  Creator: \(creator)")
            }

            // Server returns "valid" as 0/1 and provenance data
            guard valStatus == 200 else {
                throw TestError.assertion("validate HTTP \(valStatus)")
            }
            guard validateJSON["provenance_chain"] != nil else {
                throw TestError.assertion("validate should return provenance_chain")
            }
        }

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        // Clean up
        try? FileManager.default.removeItem(at: signedURL)

        print("\n============================================")
        print("Results: \(passed) passed, \(failed) failed")
        print("============================================")

        exit(failed > 0 ? 1 : 0)
    }

    static func printUsage() {
        print("""
        C2PA Test CLI — exercises the C2PA FFI bridge and server endpoints

        Usage:
          c2pa-test <logo.png> <cert.pem> <key.pem> [--server URL]

        Options:
          --server URL    C2PA server URL (default: https://100.arkavo.net)

        Examples:
          c2pa-test logo.png cert.pem private.pem
          c2pa-test logo.png cert.pem private.pem --server https://100.arkavo.net
        """)
    }

    static func printError(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }
}

enum TestError: Error, LocalizedError {
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let msg):
            return msg
        }
    }
}
