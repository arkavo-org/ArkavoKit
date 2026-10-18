import AuthenticationServices
import XCTest
@testable import ArkavoSocial

/// `passkeyCeremony(account:)`: the start, the sheet, the finish, and how each
/// identity answer maps to a reply or an error.
@MainActor
final class PasskeyCeremonyTests: XCTestCase {
    /// The name-free start: no allowCredentials. webauthn-rs adds `mediation`.
    private static let nameFreeOptions =
        #"{"publicKey":{"challenge":"Y2hhbGxlbmdl","timeout":60000,"rpId":"identity.example.test","userVerification":"required"},"mediation":"conditional"}"#
    /// The account-scoped start lists that account's credential.
    private static let scopedOptions =
        #"{"publicKey":{"challenge":"Y2hhbGxlbmdl","rpId":"identity.example.test","allowCredentials":[{"id":"AQI","type":"public-key"}]},"mediation":"conditional"}"#
    private static let reply = #"{"token":"t","handle":"alice"}"#
    private static let account = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    /// Bytes chosen so base64url needs both URL-safe substitutions and padding removal.
    private static let assertion = PasskeyAssertion(
        credentialID: Data([0xFB, 0xFF, 0x01]), // "-_8B"
        rawClientDataJSON: Data([0x01, 0x02]), // "AQI"
        rawAuthenticatorData: Data([0x03, 0x04, 0x05]), // "AwQF"
        signature: Data([0x30, 0x45, 0x02]), // "MEUC"
        userID: Data("uid".utf8) // "dWlk"
    )

    private var client: ArkavoClient!
    private var sheet: ScriptedAssertion!
    private var reporter: RecordingReporter!

    override func setUp() async throws {
        client = makeTestClient()
        reporter = RecordingReporter()
        client.credentialReporter = reporter
        stubSheet(.success(Self.assertion))
    }

    private func stubSheet(_ outcome: Result<PasskeyAssertion, Error>) {
        sheet = ScriptedAssertion(outcome)
        client.assertionProvider = sheet.perform
    }

    @discardableResult
    private func stubHTTP(_ outcomes: [ScriptedHTTP.Outcome]) -> ScriptedHTTP {
        let http = ScriptedHTTP(outcomes)
        client.httpData = http.perform
        return http
    }

    private func assertAuthenticationFailed<T>(
        _ call: () async throws -> T,
        message expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call()
            XCTFail("expected authenticationFailed", file: file, line: line)
        } catch let ArkavoError.authenticationFailed(message) {
            if let expected {
                XCTAssertEqual(message, expected, file: file, line: line)
            }
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    private func assertInvalidResponse<T>(
        _ call: () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call()
            XCTFail("expected invalidResponse. \(message())", file: file, line: line)
        } catch ArkavoError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error). \(message())", file: file, line: line)
        }
    }

    // MARK: - The start

    func testNameFreeCeremonyAsksWithoutAnAccount() async throws {
        let http = stubHTTP([.status(200, Self.nameFreeOptions), .status(200, Self.reply)])

        let reply = try await client.passkeyCeremony(account: nil)

        XCTAssertEqual(reply, AuthenticationReply(token: "t", handle: "alice"))
        let start = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(start.httpMethod, "GET")
        XCTAssertEqual(start.url?.absoluteString, "https://identity.example.test/authenticate")
        XCTAssertNil(start.url?.query)
        let request = try XCTUnwrap(sheet.requests.first)
        XCTAssertTrue(request.allowedCredentials.isEmpty)
        XCTAssertEqual(request.challenge, Data("challenge".utf8))
    }

    func testAccountScopedCeremonyNamesTheAccount() async throws {
        let http = stubHTTP([.status(200, Self.scopedOptions), .status(200, Self.reply)])

        _ = try await client.passkeyCeremony(account: Self.account)

        let start = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(start.httpMethod, "GET")
        XCTAssertEqual(start.url?.path(), "/authenticate")
        XCTAssertEqual(start.url?.query, "account=\(Self.account.uuidString.lowercased())")
        let request = try XCTUnwrap(sheet.requests.first)
        XCTAssertEqual(request.allowedCredentials.map(\.credentialID), [Data([0x01, 0x02])])
    }

    func testUserNotFoundOnTheStartIsSurfaced() async {
        let http = stubHTTP([.status(500, "User Not Found")])

        await assertAuthenticationFailed({ try await self.client.passkeyCeremony(account: Self.account) },
                                         message: "User Not Found")

        XCTAssertTrue(sheet.requests.isEmpty, "no assertion is requested")
        XCTAssertEqual(http.requests.count, 1)
    }

    /// "User Not Found" makes a deletion `.alreadyDeleted`, which clears the
    /// account's passkeys from the device for good. So only identity's own
    /// answer to a scoped start for a missing account means "no such account":
    /// status 500 with exactly that body.
    func testOnlyTheServersUserNotFoundMeansNoSuchAccount() async throws {
        for body in ["User Not Found", "User Not Found\n"] {
            stubHTTP([.status(500, body)])
            await assertAuthenticationFailed({ try await self.client.passkeyCeremony(account: Self.account) },
                                             message: "User Not Found")
        }
        XCTAssertTrue(sheet.requests.isEmpty, "no assertion is requested")

        // In a deletion, through the real ceremony.
        let harness = DeletionHarness()
        let http = harness.stubHTTP([.status(500, "User Not Found")])

        let result = try await harness.client.deleteAccount(accountName: "alice")

        XCTAssertEqual(result, .alreadyDeleted)
        XCTAssertEqual(http.requests.count, 1, "only the start is sent")
        XCTAssertEqual(http.requests.first?.url?.query, "account=\(DeletionHarness.account.uuidString.lowercased())")
        XCTAssertEqual(harness.reporter.noAcceptedCredentials, [
            RecordingReporter.NoAcceptedCredentials(
                relyingPartyID: "identity.example.test",
                userHandle: DeletionHarness.userHandle(of: DeletionHarness.account)
            ),
        ])
    }

    /// A refusal from anything else (a proxy, a gateway, another route) is not
    /// "no such account": a deletion fails and clears no passkey.
    func testAnotherNotFoundIsNotNoSuchAccount() async {
        let answers: [(status: Int, body: String)] = [
            (404, "User Not Found here"),
            (404, "User Not Found"),
            (502, "<html>User Not Found</html>"),
            (500, "User Not Found here"),
            (400, "User Not Found"),
        ]
        for answer in answers {
            let label = "\(answer.status) \(answer.body.debugDescription)"
            stubHTTP([.status(answer.status, answer.body)])
            await assertInvalidResponse({ try await self.client.passkeyCeremony(account: Self.account) }, label)

            let harness = DeletionHarness()
            let http = harness.stubHTTP([.status(answer.status, answer.body)])
            await assertInvalidResponse({ try await harness.client.deleteAccount(accountName: "alice") }, label)
            XCTAssertEqual(http.requests.count, 1, "no DELETE is sent. \(label)")
            XCTAssertTrue(harness.reporter.noAcceptedCredentials.isEmpty, "no passkey is cleared. \(label)")
            XCTAssertTrue(harness.store.removals.isEmpty, label)
        }
        XCTAssertTrue(sheet.requests.isEmpty, "no assertion is requested")
    }

    func testUndecodableChallengeIsInvalidResponse() async {
        let http = stubHTTP([.status(200, #"{"publicKey":{"challenge":"%%%"},"mediation":"conditional"}"#)])

        do {
            _ = try await client.passkeyCeremony(account: nil)
            XCTFail("expected invalidResponse")
        } catch ArkavoError.invalidResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertTrue(sheet.requests.isEmpty, "no assertion is requested")
        XCTAssertEqual(http.requests.count, 1)
    }

    // MARK: - The sheet

    func testCancelledSheetSendsNothingAndRethrows() async {
        stubSheet(.failure(ASAuthorizationError(.canceled)))
        let http = stubHTTP([.status(200, Self.nameFreeOptions)])

        do {
            _ = try await client.passkeyCeremony(account: nil)
            XCTFail("expected the cancellation")
        } catch {
            let authError = error as? ASAuthorizationError
            XCTAssertEqual(authError?.code, .canceled, "got \(error)")
            XCTAssertEqual((error as NSError).domain, ASAuthorizationErrorDomain)
        }

        XCTAssertEqual(http.requests.count, 1, "only the start is sent")
        XCTAssertEqual(http.requests.first?.httpMethod, "GET")
    }

    // MARK: - The finish

    func testPostCarriesTheAssertion() async throws {
        let http = stubHTTP([.status(200, Self.nameFreeOptions), .status(200, Self.reply)])

        _ = try await client.passkeyCeremony(account: nil)

        XCTAssertEqual(http.requests.count, 2)
        let finish = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(finish.httpMethod, "POST")
        XCTAssertEqual(finish.url?.absoluteString, "https://identity.example.test/authenticate")
        XCTAssertEqual(finish.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(finish.httpBody)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "-_8B")
        XCTAssertEqual(body["rawId"] as? String, "-_8B")
        XCTAssertEqual(body["type"] as? String, "public-key")
        let response = try XCTUnwrap(body["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, "AQI")
        XCTAssertEqual(response["authenticatorData"] as? String, "AwQF")
        XCTAssertEqual(response["signature"] as? String, "MEUC")
        XCTAssertEqual(response["userHandle"] as? String, "dWlk")
    }

    func testUnknownPasskeyIsReportedThenThrown() async {
        stubHTTP([.status(200, Self.nameFreeOptions), .status(404, "Unknown Passkey")])

        do {
            _ = try await client.passkeyCeremony(account: nil)
            XCTFail("expected unknownPasskey")
        } catch ArkavoError.unknownPasskey {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(reporter.unknown, [
            RecordingReporter.Unknown(relyingPartyID: "identity.example.test", credentialID: Self.assertion.credentialID),
        ])
        XCTAssertTrue(reporter.noAcceptedCredentials.isEmpty)
    }

    /// Reporting removes a passkey from the device, so only identity's own
    /// refusal triggers it: a 404 with any other body (a proxy, a wrong route) does not.
    func testANotFoundWithoutTheUnknownPasskeyRefusalReportsNothing() async {
        stubHTTP([.status(200, Self.nameFreeOptions), .status(404, "<html>Not Found</html>")])

        await assertAuthenticationFailed { try await self.client.passkeyCeremony(account: nil) }

        XCTAssertTrue(reporter.unknown.isEmpty)
    }

    func testFailedCeremonyIsAnAuthenticationFailure() async {
        stubHTTP([.status(200, Self.nameFreeOptions), .status(400, #"{"token":""}"#)])

        await assertAuthenticationFailed { try await self.client.passkeyCeremony(account: nil) }

        XCTAssertTrue(reporter.unknown.isEmpty, "only an unknown passkey is reported")
    }

    func testANameFreeReplyWithoutAHandleIsAFailure() async {
        stubHTTP([.status(200, Self.nameFreeOptions), .status(200, #"{"token":"t"}"#)])

        await assertAuthenticationFailed({ try await self.client.passkeyCeremony(account: nil) },
                                         message: "No account handle received")
    }
}
