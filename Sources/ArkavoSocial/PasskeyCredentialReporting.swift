import AuthenticationServices
import Foundation

/// Tells the system's passkey list which passkeys identity no longer accepts,
/// so a passkey whose account is gone stops being offered on the sheet.
///
/// Reporting is advisory: the methods never throw, so a report can never fail
/// a sign-in or a deletion.
protocol PasskeyCredentialReporting: Sendable {
    /// identity refused `credentialID` as an unknown passkey.
    func reportUnknown(relyingPartyID: String, credentialID: Data) async

    /// The account behind `userHandle` is gone: none of its passkeys is accepted.
    func reportNoAcceptedCredentials(relyingPartyID: String, userHandle: Data) async
}

/// Reports through `ASCredentialDataManager` (iOS and macOS 26.2+). On an
/// older system, or when the system refuses a report, it logs and returns.
struct SystemPasskeyCredentialReporter: PasskeyCredentialReporting {
    func reportUnknown(relyingPartyID: String, credentialID: Data) async {
        if #available(iOS 26.2, macOS 26.2, *) {
            do {
                try await ASCredentialDataManager().reportUnknownPublicKeyCredential(
                    relyingPartyIdentifier: relyingPartyID,
                    credentialID: credentialID
                )
                print("PasskeyCredentialReporting: reported an unknown passkey")
            } catch {
                Self.logFailure("reportUnknown", error)
            }
        } else {
            print("PasskeyCredentialReporting: reportUnknown unavailable on this system")
        }
    }

    func reportNoAcceptedCredentials(relyingPartyID: String, userHandle: Data) async {
        if #available(iOS 26.2, macOS 26.2, *) {
            do {
                try await ASCredentialDataManager().reportAllAcceptedPublicKeyCredentials(
                    relyingPartyIdentifier: relyingPartyID,
                    userHandle: userHandle,
                    acceptedCredentialIDs: []
                )
                print("PasskeyCredentialReporting: reported no accepted passkeys for an account")
            } catch {
                Self.logFailure("reportNoAcceptedCredentials", error)
            }
        } else {
            print("PasskeyCredentialReporting: reportNoAcceptedCredentials unavailable on this system")
        }
    }

    private static func logFailure(_ report: String, _ error: Error) {
        let nsError = error as NSError
        print("PasskeyCredentialReporting: \(report) failed domain=\(nsError.domain) code=\(nsError.code)")
    }
}
