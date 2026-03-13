#if canImport(C2paOpenTDF)
import C2paOpenTDF
#endif
import Foundation

/// How to provide signing credentials
public enum SigningMode: Sendable {
    /// Auto-generate a self-signed certificate chain (dev/testing)
    case selfSigned
    /// Explicit PEM-encoded certificate chain and private key
    case pemFiles(certPEM: String, keyPEM: String)
}

/// Signs content with C2PA manifests using the c2pa-opentdf-rs native library
public actor C2PASigner {
    private let certPEM: String
    private let keyPEM: String

    public enum SigningError: Error, LocalizedError {
        case manifestCreationFailed
        case signingFailed(String)
        case invalidInput
        case missingSigningCertificate
        case sdkError(String)
        case frameworkNotAvailable

        public var errorDescription: String? {
            switch self {
            case .manifestCreationFailed:
                return "Failed to create manifest JSON"
            case .signingFailed(let message):
                return "C2PA signing failed: \(message)"
            case .invalidInput:
                return "Invalid input file"
            case .missingSigningCertificate:
                return "Signing certificate not configured"
            case .sdkError(let message):
                return "C2PA SDK error: \(message)"
            case .frameworkNotAvailable:
                return "C2paOpenTDF framework not available — build with the xcframework to enable C2PA signing"
            }
        }
    }

    public init(signingMode: SigningMode = .selfSigned) throws {
        switch signingMode {
        case .pemFiles(let certPEM, let keyPEM):
            self.certPEM = certPEM
            self.keyPEM = keyPEM
        case .selfSigned:
            throw SigningError.missingSigningCertificate
        }
    }

    /// Signs a media file with a C2PA manifest
    public func sign(
        inputFile: URL,
        outputFile: URL,
        manifest: C2PAManifest
    ) async throws {
        #if canImport(C2paOpenTDF)
        let manifestData = try JSONEncoder().encode(manifest)
        guard let manifestJSON = String(data: manifestData, encoding: .utf8) else {
            throw SigningError.manifestCreationFailed
        }

        let inputPath = inputFile.path
        let outputPath = outputFile.path
        let cert = certPEM
        let key = keyPEM

        let (resultCode, errorPtr) = Self.callSign(
            inputPath: inputPath, outputPath: outputPath,
            manifestJSON: manifestJSON, cert: cert, key: key
        )

        let errorMessage = consumeFFIString(errorPtr)
        guard resultCode == SUCCESS else {
            throw SigningError.signingFailed(errorMessage ?? "unknown error")
        }
        #else
        throw SigningError.frameworkNotAvailable
        #endif
    }

    #if canImport(C2paOpenTDF)
    private nonisolated static func callSign(
        inputPath: String, outputPath: String,
        manifestJSON: String, cert: String, key: String
    ) -> (C2paResultCode, UnsafeMutablePointer<CChar>?) {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = c2pa_sign_file(
            inputPath, outputPath, manifestJSON, cert, key, &errorPtr
        )
        return (result, errorPtr)
    }
    #endif

    /// Verifies a C2PA manifest in a file
    public func verify(file: URL) async throws -> C2PAValidationResult {
        #if canImport(C2paOpenTDF)
        let filePath = file.path

        let (resultCode, resultPtr, errorPtr) = Self.callVerify(filePath: filePath)

        let errorMessage = consumeFFIString(errorPtr)
        guard resultCode == SUCCESS else {
            throw SigningError.sdkError(errorMessage ?? "unknown error")
        }

        guard let resultJSON = consumeFFIString(resultPtr) else {
            throw SigningError.sdkError("verify returned no result")
        }

        guard let data = resultJSON.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SigningError.sdkError("failed to parse verify result JSON")
        }

        let isValid = dict["is_valid"] as? Bool ?? false
        let hasManifest = dict["has_manifest"] as? Bool ?? false
        let manifestJSON = dict["manifest_json"] as? String ?? ""

        return C2PAValidationResult(
            isValid: isValid,
            hasManifest: hasManifest,
            manifestJSON: manifestJSON,
            error: nil
        )
        #else
        throw SigningError.frameworkNotAvailable
        #endif
    }

    #if canImport(C2paOpenTDF)
    private nonisolated static func callVerify(
        filePath: String
    ) -> (C2paResultCode, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) {
        var resultPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = c2pa_verify_file(filePath, &resultPtr, &errorPtr)
        return (result, resultPtr, errorPtr)
    }
    #endif

    /// Extracts manifest information without full validation
    public func info(file: URL) async throws -> C2PAInfo {
        #if canImport(C2paOpenTDF)
        let filePath = file.path

        let (resultCode, infoPtr, errorPtr) = Self.callInfo(filePath: filePath)

        let errorMessage = consumeFFIString(errorPtr)
        guard resultCode == SUCCESS else {
            throw SigningError.sdkError(errorMessage ?? "unknown error")
        }

        let infoJSON = consumeFFIString(infoPtr) ?? ""
        return C2PAInfo(rawOutput: infoJSON)
        #else
        throw SigningError.frameworkNotAvailable
        #endif
    }

    #if canImport(C2paOpenTDF)
    private nonisolated static func callInfo(
        filePath: String
    ) -> (C2paResultCode, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) {
        var infoPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = c2pa_info_file(filePath, &infoPtr, &errorPtr)
        return (result, infoPtr, errorPtr)
    }

    // MARK: - Private

    private func consumeFFIString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        let str = String(cString: ptr)
        c2pa_string_free(ptr)
        return str
    }
    #endif
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
        !rawOutput.isEmpty
    }
}
