import Foundation

/// Signs content with C2PA manifests
///
/// NOTE: Currently uses c2patool CLI as a temporary implementation.
/// This will be replaced with native c2pa-opentdf-rs integration:
/// https://github.com/arkavo-org/c2pa-opentdf-rs/issues
public actor C2PASigner {
    private let c2patoolPath: String

    public enum SigningError: Error, LocalizedError {
        case c2patoolNotFound
        case manifestCreationFailed
        case signingFailed(String)
        case invalidInput
        case missingSigningCertificate

        public var errorDescription: String? {
            switch self {
            case .c2patoolNotFound:
                return "c2patool not found in PATH. Please install c2pa-tool."
            case .manifestCreationFailed:
                return "Failed to create manifest JSON"
            case .signingFailed(let message):
                return "C2PA signing failed: \(message)"
            case .invalidInput:
                return "Invalid input file"
            case .missingSigningCertificate:
                return "Signing certificate not configured"
            }
        }
    }

    public init(c2patoolPath: String = "/opt/homebrew/bin/c2patool") throws {
        // Verify c2patool exists
        guard FileManager.default.fileExists(atPath: c2patoolPath) else {
            // Try to find it in PATH
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["c2patool"]

            let pipe = Pipe()
            process.standardOutput = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    self.c2patoolPath = path
                    return
                }
            }

            throw SigningError.c2patoolNotFound
        }

        self.c2patoolPath = c2patoolPath
    }

    /// Signs a video file with a C2PA manifest
    public func sign(
        inputFile: URL,
        outputFile: URL,
        manifest: C2PAManifest,
        signingCert: URL? = nil,
        privateKey: URL? = nil
    ) async throws {
        // Validate input
        guard FileManager.default.fileExists(atPath: inputFile.path) else {
            throw SigningError.invalidInput
        }

        // Create manifest JSON
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest_\(UUID().uuidString).json")

        try manifestData.write(to: manifestFile)
        defer {
            try? FileManager.default.removeItem(at: manifestFile)
        }

        // Build c2patool command
        var arguments = [
            inputFile.path,
            "--manifest", manifestFile.path,
            "--output", outputFile.path,
            "--force"
        ]

        // Add signing certificate if provided
        if let _ = signingCert, let _ = privateKey {
            // Note: c2patool uses cert+key in manifest, not CLI args
            // For now, we'll use unsigned manifests (sidecar mode)
            arguments.append("--sidecar")
        }

        // Execute c2patool
        let process = Process()
        process.executableURL = URL(fileURLWithPath: c2patoolPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Check result
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SigningError.signingFailed(errorMessage)
        }
    }

    /// Verifies a C2PA manifest in a file
    public func verify(file: URL) async throws -> C2PAValidationResult {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw SigningError.invalidInput
        }

        // Execute c2patool with detailed flag
        let process = Process()
        process.executableURL = URL(fileURLWithPath: c2patoolPath)
        process.arguments = [file.path, "--detailed"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        // Parse output (simplified - full implementation would parse JSON)
        let hasManifest = !output.isEmpty && !output.contains("No claim found")
        let isValid = process.terminationStatus == 0 && hasManifest

        return C2PAValidationResult(
            isValid: isValid,
            hasManifest: hasManifest,
            manifestJSON: output,
            error: error.isEmpty ? nil : error
        )
    }

    /// Extracts manifest information without full validation
    public func info(file: URL) async throws -> C2PAInfo {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw SigningError.invalidInput
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: c2patoolPath)
        process.arguments = [file.path, "--info"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        return C2PAInfo(rawOutput: output)
    }
}

// MARK: - Validation Result

public struct C2PAValidationResult: Sendable {
    public let isValid: Bool
    public let hasManifest: Bool
    public let manifestJSON: String
    public let error: String?

    public init(isValid: Bool, hasManifest: Bool, manifestJSON: String, error: String?) {
        self.isValid = isValid
        self.hasManifest = hasManifest
        self.manifestJSON = manifestJSON
        self.error = error
    }
}

// MARK: - Info Result

public struct C2PAInfo: Sendable {
    public let rawOutput: String

    public init(rawOutput: String) {
        self.rawOutput = rawOutput
    }

    public var hasManifest: Bool {
        !rawOutput.contains("No claim found") && !rawOutput.isEmpty
    }

    public var manifestSize: Int? {
        // Parse manifest size from output (simplified)
        let components = rawOutput.components(separatedBy: "\n")
        for line in components {
            if line.contains("Manifest size:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1,
                   let sizeStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first,
                   let size = Int(sizeStr) {
                    return size
                }
            }
        }
        return nil
    }
}
