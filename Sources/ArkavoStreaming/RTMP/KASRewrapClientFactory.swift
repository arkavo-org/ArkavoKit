import Foundation
import OpenTDFKit

/// Maps the pre-4.0.1 `KASRewrapClient(kasURL:oauthToken:)` call onto
/// `init(configuration:oauthToken:)`.
///
/// The old initializer treated `kasURL` as a KAS base that already included
/// `/kas` and then appended `v2/rewrap` (legacy REST). `forKasLegacyRest`
/// appends `/kas/v2/rewrap` itself, so a trailing `/kas` on the input must
/// be stripped first.
public enum KASRewrapClientFactory {
    public static func make(kasURL: URL, oauthToken: String) throws -> KASRewrapClient {
        try KASRewrapClient(
            configuration: configuration(for: kasURL),
            oauthToken: oauthToken
        )
    }

    static func configuration(for kasURL: URL) -> OpenTDFConfiguration {
        .forKasLegacyRest(legacyRestBase(for: kasURL))
    }

    static func legacyRestBase(for kasURL: URL) -> String {
        let path = kasURL.path
        if path == "/kas" || path.hasSuffix("/kas") || path.hasSuffix("/kas/") {
            return trimmingTrailingSlashes(kasURL.deletingLastPathComponent().absoluteString)
        }
        return trimmingTrailingSlashes(kasURL.absoluteString)
    }
}

private func trimmingTrailingSlashes(_ s: String) -> String {
    var result = s
    while result.hasSuffix("/") {
        result.removeLast()
    }
    return result
}
