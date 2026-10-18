# Name-free passkey sign-in (ArkavoKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ArkavoClient` signs in with a name-free passkey ceremony, learning the account's handle from identity. Deletion re-authenticates the stored account by UUID. Passkeys whose account is gone are cleared from the system list.

**Architecture:**
- One internal `passkeyCeremony(account:)` replaces `authenticateUser(accountName:)`.
  - Its HTTP goes through the existing `httpData` seam.
  - The system sheet goes through a new `assertionProvider` seam.
  - Passkey cleanup goes through a new `credentialReporter` seam, so the ceremony is unit-tested end to end with no network and no sheet.
- `connect(account:)` and `deleteAccount(accountName:)` sit on top of the ceremony.

**Tech Stack:** Swift 6.4 package, AuthenticationServices, XCTest (`@testable import ArkavoSocial`).

**Spec:** authnz-rs `docs/superpowers/specs/2026-10-17-passkey-sign-in-design.md`, at `/Users/arkavo/Projects/authnz-rs-passkey-sign-in/docs/superpowers/specs/`. The server contract it builds on is authnz-rs `docs/superpowers/plans/2026-10-17-passkey-sign-in-server.md`.

## Global Constraints

- **Server contract:**
  - `GET {authURL}/authenticate`, with no name, starts a name-free sign-in. `GET {authURL}/authenticate?account=<lowercased UUID>` re-authenticates one account.
  - `POST {authURL}/authenticate`:
    - 200 `{"token","handle"}`;
    - 400 `{"token":""}` for a failed ceremony;
    - 404 body `Unknown Passkey`;
    - 403 body `Passkey belongs to another account`.
  - The start answers 500 `User Not Found` for a scoped account that no longer exists.
- **Public API after this plan:**
  - `@discardableResult public func connect(account: UUID? = nil) async throws -> String`, which returns the signed-in account's handle. `connect(accountName:)` is removed (pre-release API break).
  - New `ArkavoError.unknownPasskey`.
  - `deleteAccount(accountName:)` keeps its signature.
- **Error text is unchanged:**
  - `ArkavoError.authenticationFailed("User Not Found")` still means "no such account" for deletion.
  - A cancelled sheet still rethrows the raw `ASAuthorizationError` with code `.canceled`.
- `ASCredentialDataManager` calls run only under `if #available(iOS 26.2, macOS 26.2, *)`, because the package supports iOS 26. A reporting failure is logged and never thrown.
- Never log a token, a challenge, an assertion or a response body. Use the existing logging style in `ArkavoClient.swift`.
- The release is ArkavoKit `0.4.0`, a lightweight tag on the merge commit. Pushing the tag is the owner's call.

## Review Focus

1. **A cancelled passkey sheet** sends no POST and rethrows `ASAuthorizationError.canceled` unchanged. Test `testCancelledSheetSendsNothingAndRethrows` (Task 1).
2. **A cached token with no stored handle** must not "sign in" with an empty handle. It drops the token and runs the ceremony. Test `testCachedTokenWithoutAHandleRunsTheCeremony` (Task 2).
3. **Deleting an account whose handle is not the stored token's account** never re-authenticates some other account. It throws `.notConnected` with no HTTP. Test `testStoredTokenOfAnotherHandleRefusesWithoutASignIn` (Task 3).
4. **A non-base64url challenge** answers `.invalidResponse` and does not crash; today the code force-unwraps it. Test `testUndecodableChallengeIsInvalidResponse` (Task 1).
5. **A passkey-reporting failure** (the API is unavailable or throws) never fails a sign-in or a deletion. Test `testReporterFailureDoesNotFailTheCeremony` (Task 1).

---

### Task 1: The passkey ceremony

**Files:**
- Modify: `Sources/ArkavoSocial/ArkavoClient.swift`:
  - `ArkavoError` (13-22): add `case unknownPasskey`.
  - The seams near 79-88: add `assertionProvider` and `credentialReporter`.
  - Add `passkeyCeremony(account:)` next to `authenticateUser` (843). `authenticateUser` stays until Task 3.
  - `AuthenticationOptionsResponse` (2239): unchanged.
- Create: `Sources/ArkavoSocial/PasskeyCredentialReporting.swift`.
- Test: create `Tests/ArkavoKitTests/PasskeyCeremonyTests.swift`. Extend `ArkavoClientTestDoubles.swift` with `ScriptedAssertion` and `RecordingReporter`.

**Interfaces:**
- Produces, all internal unless marked:
  - `struct PasskeyAssertion: Sendable, Equatable { let credentialID: Data; let rawClientDataJSON: Data; let rawAuthenticatorData: Data; let signature: Data; let userID: Data? }`.
  - `var assertionProvider: @MainActor (ASAuthorizationPlatformPublicKeyCredentialAssertionRequest) async throws -> PasskeyAssertion`. Its default maps `performAuthentication(request:)`'s assertion field for field.
  - `protocol PasskeyCredentialReporting: Sendable`, with:
    - `func reportUnknown(relyingPartyID: String, credentialID: Data) async`;
    - `func reportNoAcceptedCredentials(relyingPartyID: String, userHandle: Data) async`.
  - `struct SystemPasskeyCredentialReporter: PasskeyCredentialReporting`. It calls `ASCredentialDataManager().reportUnknownPublicKeyCredential(relyingPartyIdentifier:credentialID:)` and `reportAllAcceptedPublicKeyCredentials(relyingPartyIdentifier:userHandle:acceptedCredentialIDs: [])`, catching and logging errors.
  - `var credentialReporter: any PasskeyCredentialReporting = SystemPasskeyCredentialReporter()`.
  - `struct AuthenticationReply: Equatable { let token: String; let handle: String }`.
  - `func passkeyCeremony(account: UUID?) async throws -> AuthenticationReply`.
  - `public enum ArkavoError`: new `case unknownPasskey`.

- [ ] **Step 1: Write the failing tests** in `PasskeyCeremonyTests.swift`. Script `client.httpData` with `ScriptedHTTP`, `client.assertionProvider` and `client.credentialReporter`.
  - `testNameFreeCeremonyAsksWithoutAnAccount`:
    - The GET URL is `https://identity.example.test/authenticate` with no query.
    - The assertion request's `allowedCredentials` is empty.
    - POST 200 `{"token":"t","handle":"alice"}` gives `AuthenticationReply(token: "t", handle: "alice")`.
  - `testAccountScopedCeremonyNamesTheAccount`:
    - The GET query is `account=<uuid.uuidString.lowercased()>`.
    - The options' listed id becomes the request's only `allowedCredentials` entry.
  - `testPostCarriesTheAssertion`: the POST JSON carries `id`, `rawId`, `response.clientDataJSON`, `authenticatorData`, `signature` and `userHandle`, each base64url of the scripted assertion, plus `type == "public-key"`.
  - `testUnknownPasskeyIsReportedThenThrown`: POST 404 `Unknown Passkey` throws `ArkavoError.unknownPasskey`. The reporter got `reportUnknown(relyingPartyID: <client's RP>, credentialID: <assertion id>)` once.
  - `testFailedCeremonyIsAnAuthenticationFailure`: POST 400 `{"token":""}` throws `.authenticationFailed`.
  - `testANameFreeReplyWithoutAHandleIsAFailure`: POST 200 `{"token":"t"}` throws `.authenticationFailed("No account handle received")`.
  - `testUserNotFoundOnTheStartIsSurfaced`: GET 500 `User Not Found` throws `.authenticationFailed("User Not Found")`, with no assertion requested.
  - `testUndecodableChallengeIsInvalidResponse`: a challenge of `"%%%"` throws `.invalidResponse`.
  - `testCancelledSheetSendsNothingAndRethrows`: `assertionProvider` throws `ASAuthorizationError(.canceled)`. The same error is rethrown, and only the GET was sent.
  - `testReporterFailureDoesNotFailTheCeremony`: a reporter that records and returns, as the live one does after catching, still gives `.unknownPasskey`. The live `SystemPasskeyCredentialReporter` has no unit test because it calls the system.
- [ ] **Step 2: Run to verify they fail.** `swift test --filter ArkavoKitTests.PasskeyCeremonyTests`. Expect a FAIL (compile error).
- [ ] **Step 3: Implement** `passkeyCeremony(account:)`:
  - GET via `httpData`. The challenge decodes with `Data(base64Encoded: challenge.base64URLToBase64())`, and a failure gives `.invalidResponse`.
  - Build the request with `Self.passkeyAssertionRequest(provider:challenge:allowCredentialIDs:)`, then `assertionProvider`.
  - POST via `httpData`, with the same body shape as `authenticateUser` today.
  - Map the statuses as in Global Constraints. 404 calls `credentialReporter.reportUnknown` before throwing.
- [ ] **Step 4: Run to verify they pass.** Run `swift test --filter ArkavoKitTests.PasskeyCeremonyTests`, which should pass, then `swift test`, where all existing tests should still pass.
- [ ] **Step 5: Commit.** `git commit -m "feat(social): name-free passkey ceremony with stale-passkey reporting"`

### Task 2: `connect(account:)`

**Files:**
- Modify: `Sources/ArkavoSocial/ArkavoClient.swift`, `connect(accountName:)` (210-285).
- Test: `Tests/ArkavoKitTests/ArkavoClientDeletionTests.swift:298`, which moves to `connect()`. Create `Tests/ArkavoKitTests/ConnectTests.swift`.

**Interfaces:**
- Consumes: Task 1's `passkeyCeremony(account:)` and `AuthenticationReply`.
- Produces: `@discardableResult public func connect(account: UUID? = nil) async throws -> String`.
  - **Fast path:** a cached token AND a stored handle (`KeychainManager.getArkavoHandle()`) open the socket and return the stored handle. A token without a handle is deleted, and the ceremony runs.
  - **Ceremony path:** `passkeyCeremony(account:)`, then `saveAuthenticationToken(reply.token)`, then `saveArkavoHandle(reply.handle)`. Then the socket. Return `reply.handle`.

- [ ] **Step 1: Write the failing tests** in `ConnectTests.swift`.
  - `testCachedTokenWithoutAHandleRunsTheCeremony`. The socket path has no seam, so the fast-path decision is a pure function, `nonisolated static func usesCachedSession(token: String?, handle: String?) -> Bool`.
    - Assert `true` only when both are non-nil and non-empty.
    - `connect` calls it with `KeychainManager.getAuthenticationToken()` and `KeychainManager.getArkavoHandle()`.
  - Update `testWhileDeletingEverythingElseIsRefused` to call `connect()`, and still expect `.invalidState`.
- [ ] **Step 2: Run to verify they fail.** `swift test --filter ArkavoKitTests.ConnectTests`. Expect a FAIL.
- [ ] **Step 3: Implement** the signature and paths above. Delete `connect(accountName:)`. Then confirm that the apps' registration writes the same Keychain item `getArkavoHandle()` reads: `KeychainManager.saveArkavoCredentials(handle:did:)` (Creator) and `saveIdentityPair`/`saveArkavoCredentials` (iOS `ArkavoSharedCredentialStore`). Do this with `grep -n "com.arkavo.handle" Sources/ArkavoSocial/KeychainManager.swift`.
  - If the registration writes a different item, the fast path after registration would miss the handle.
  - In that case `saveArkavoCredentials` must also write it. Add a test for that.
- [ ] **Step 4: Run.** `swift test`. Expect a PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(social)!: connect signs in by passkey without an account name"`

### Task 3: Deletion re-authenticates the stored account

**Files:**
- Modify: `Sources/ArkavoSocial/ArkavoClient.swift`:
  - the `authenticator` seam (79);
  - `freshDeletionToken(accountName:)` (527);
  - `requestAccountDeletion` (497-522) and the `deleteAccount(accountName:)` success paths;
  - delete `authenticateUser(accountName:)` (843-924).
- Modify: `Tests/ArkavoKitTests/ArkavoClientTestDoubles.swift`. `DeletionHarness.stubCeremonies` uses the new seam type, and `FakeCredentialStore` holds a `TestCWT` token whose `sub` is a fixed UUID.
- Test: `Tests/ArkavoKitTests/ArkavoClientDeletionTests.swift`.

**Interfaces:**
- Consumes: `passkeyCeremony(account:)`, `credentialReporter`, `CWTSubject.sub(fromToken:)` and `credentialStore.authenticationToken()` / `sharedHandle()`.
- Produces:
  - `lazy var authenticator: @MainActor (UUID) async throws -> String`, whose default is `passkeyCeremony(account:).token`.
  - `freshDeletionToken(accountName:)` re-authenticates `UUID(uuidString: CWTSubject.sub(fromToken: storedToken))`, but only when `credentialStore.sharedHandle() == accountName`. Otherwise it throws `ArkavoError.notConnected` with no request.
  - On `.deleted` and `.alreadyDeleted`: `credentialReporter.reportNoAcceptedCredentials(relyingPartyID:userHandle:)` with the UUID's 16 bytes, written as `withUnsafeBytes(of: uuid.uuid) { Data($0) }`.
  - Unverified: whether the system accepts an **empty** `acceptedCredentialIDs` list. Note it on the PR for TestFlight QA.
    - If QA finds it refused (the passkey stays listed after a deletion), the follow-up is that the reporter also calls `reportUnknown` for the credential id used in the deletion's re-authentication.
    - Supporting that, `passkeyCeremony` would return that id.

- [ ] **Step 1: Write the failing tests.**
  - `testDeletionReauthenticatesTheStoredAccount`: `authenticator` is called once, with the stored token's `sub` UUID.
  - `testNoStoredTokenRefusesWithoutASignIn`: throws `.notConnected`. The authenticator is not called, and no HTTP is sent.
  - `testStoredTokenOfAnotherHandleRefusesWithoutASignIn`: the stored handle is `"bob"` and `deleteAccount(accountName: "alice")` throws `.notConnected` without a sign-in.
  - `testDeletionClearsTheAccountsPasskeys`: after `.deleted`, the reporter got `reportNoAcceptedCredentials` with the UUID bytes, once.
  - `testAlreadyDeletedAlsoClearsTheAccountsPasskeys`.
  - The existing 21 deletion tests keep their assertions, re-plumbed to the `(UUID)` seam. `testUserNotFoundOnTheFirstSignInSendsNothing` and `testUnauthorizedThenUserNotFoundIsAlreadyDeleted` still pass on the `"User Not Found"` text.
- [ ] **Step 2: Run to verify they fail.** `swift test --filter ArkavoKitTests.ArkavoClientDeletionTests`. Expect a FAIL.
- [ ] **Step 3: Implement** the above. Delete `authenticateUser(accountName:)`.
- [ ] **Step 4: Run.** `swift test`. Expect a PASS. `grep -n "authenticate/" Sources` finds nothing.
- [ ] **Step 5: Commit.** `git commit -m "feat(social): deletion re-authenticates the stored account and clears its passkeys"`

### Task 4: Public API guard

**Files:**
- Modify: `Tests/ArkavoKitTests/ArkavoSocialPublicAPITests.swift`.

- [ ] **Step 1: Add the API-shape tests.**
  - `testUnknownPasskeyIsMatchable`: a `switch` on `ArkavoError.unknownPasskey` compiles and matches.
  - `testConnectReturnsTheHandle`: assigning `{ (c: ArkavoClient) async throws -> String in try await c.connect() }` compiles. Keep the closure unexecuted.
  - Keep the `AccountDeleting` conformance.
- [ ] **Step 2: Run.** `swift test`. Expect a PASS.
- [ ] **Step 3: Commit.** `git commit -m "test(social): pin the passkey sign-in public API"`
- [ ] **Step 4: Release (owner).** After the PR merges, the owner pushes tag `0.4.0` on the merge commit. Creator and arkavo-ios pin it exactly.
