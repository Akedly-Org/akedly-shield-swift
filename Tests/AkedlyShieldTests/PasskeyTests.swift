import XCTest
@testable import AkedlyShield
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

final class PasskeyTests: XCTestCase {

    func testNativeAssertionOptionsRejectHostileValuesAndIgnoreTransports() throws {
        let payload = Data([0xfb, 0xff, 0xff, 0xfb])
        let encoded = payload.base64URLEncodedString()

        XCTAssertEqual(encoded, "-___-w")
        XCTAssertEqual(Data(base64URLEncoded: encoded), payload)

        let challenge = Data([1, 2, 3]).base64URLEncodedString()
        let credentialIDs = [Data([4, 5, 6]), Data([7, 8, 9]), Data([10, 11, 12])]
        let options: [String: Any] = [
            "challenge": challenge,
            "rpId": "akedly.io",
            "allowCredentials": [
                [
                    "id": credentialIDs[0].base64URLEncodedString(),
                    "type": "public-key",
                    "transports": ["internal"]
                ],
                [
                    "id": credentialIDs[1].base64URLEncodedString(),
                    "type": "public-key"
                ],
                [
                    "id": credentialIDs[2].base64URLEncodedString(),
                    "type": "public-key",
                    "transports": NSNull()
                ]
            ]
        ]

        let mapped = try AkedlyPasskeyNativeMapper.assertionOptions(from: options)
        XCTAssertEqual(mapped.challenge, Data(base64URLEncoded: challenge))
        XCTAssertEqual(mapped.rpId, "akedly.io")
        XCTAssertEqual(mapped.allowedCredentialIDs, credentialIDs)

        func assertInvalid(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
            var invalidOptions = options
            invalidOptions["allowCredentials"] = value
            XCTAssertThrowsError(try AkedlyPasskeyNativeMapper.assertionOptions(from: invalidOptions), file: file, line: line) { error in
                guard case AkedlyPasskeyError.invalidOptions = error else {
                    XCTFail("expected invalidOptions, got \(error)", file: file, line: line)
                    return
                }
            }
        }

        assertInvalid([])
        var missingOptions = options
        missingOptions.removeValue(forKey: "allowCredentials")
        XCTAssertThrowsError(try AkedlyPasskeyNativeMapper.assertionOptions(from: missingOptions))
        assertInvalid(NSNull())
        assertInvalid([["id": "abc=", "type": "public-key"]])
        assertInvalid([["id": "a", "type": "public-key"]])
        assertInvalid([["id": 123, "type": "public-key"]])
    }

#if canImport(AuthenticationServices)
    @MainActor
    func testNativePublicAPIIsUnsupportedOnMacOSAndRejectsNonJSONDictionaries() async throws {
        #if os(macOS)
        XCTAssertFalse(AkedlyPasskey.isNativeSupported)

        do {
            _ = try await AkedlyPasskey.register(options: Data("{}".utf8))
            XCTFail("macOS must report unsupported")
        } catch AkedlyPasskeyError.unsupported {
        }
        do {
            _ = try await AkedlyPasskey.authenticate(options: Data("{}".utf8))
            XCTFail("macOS must report unsupported")
        } catch AkedlyPasskeyError.unsupported {
        }
        do {
            _ = try await AkedlyPasskey.register(options: ["valid": true])
            XCTFail("macOS must report unsupported")
        } catch AkedlyPasskeyError.unsupported {
        }
        do {
            _ = try await AkedlyPasskey.authenticate(options: ["valid": true])
            XCTFail("macOS must report unsupported")
        } catch AkedlyPasskeyError.unsupported {
        }
        do {
            _ = try await AkedlyPasskey.authenticate(options: ["invalid": Date()])
            XCTFail("non-JSON values must be rejected")
        } catch AkedlyPasskeyError.invalidOptions {
        }
        #endif
    }
#endif

    func testResultIsSendable() {
        // Compile-time contract: the result crosses concurrency boundaries (returned from an
        // async @MainActor method into arbitrary consumer tasks).
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(AkedlyPasskeyResult.self)
    }

    func testBuildURL() {
        let url = AkedlyPasskeyCeremony.buildURL(
            origin: "https://auth.akedly.io",
            token: "pk1.abc",
            callbackScheme: "myapp"
        )
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://auth.akedly.io/pk?"))
        XCTAssertTrue(s.contains("token=pk1.abc"))
        // returnUrl is percent-encoded to match the Kotlin/Dart SDKs byte-for-byte
        // (`:`→%3A, `/`→%2F). The bare `myapp://…` form would corrupt the query.
        XCTAssertTrue(s.contains("returnUrl=myapp%3A%2F%2Fakedly-passkey"))
        XCTAssertFalse(s.contains("returnUrl=myapp://"))
    }

    func testBuildURLEncodesReservedCharsInToken() {
        // A token carrying reserved query chars must be escaped, not passed through literally,
        // or it would split the query (`&`/`=`) or read back wrong.
        let url = AkedlyPasskeyCeremony.buildURL(
            origin: "https://auth.akedly.io",
            token: "a&b=c/d",
            callbackScheme: "myapp"
        )
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        XCTAssertTrue(s.contains("token=a%26b%3Dc%2Fd"))
        XCTAssertFalse(s.contains("token=a&b=c/d"))
    }

    func testBuildURLTrimsTrailingSlash() {
        let url = AkedlyPasskeyCeremony.buildURL(
            origin: "http://localhost:5174/",
            token: "t",
            callbackScheme: "demo"
        )
        XCTAssertEqual(url?.absoluteString, "http://localhost:5174/pk?token=t&returnUrl=demo%3A%2F%2Fakedly-passkey")
    }

    func testParseVerifiedResult() {
        let url = URL(string: "myapp://akedly-passkey?type=AKEDLY_PASSKEY_RESULT&purpose=auth&verified=true&transactionId=tx_9&resultToken=pkrt1.aaa.bbb")!
        let r = AkedlyPasskeyCeremony.parseResult(from: url)
        XCTAssertTrue(r.verified)
        XCTAssertEqual(r.purpose, "auth")
        XCTAssertEqual(r.transactionId, "tx_9")
        XCTAssertEqual(r.resultToken, "pkrt1.aaa.bbb")
        XCTAssertNil(r.reason)
    }

    func testParseFailedResultCarriesCodeAsReason() {
        let url = URL(string: "myapp://akedly-passkey?verified=false&code=ineligible")!
        let r = AkedlyPasskeyCeremony.parseResult(from: url)
        XCTAssertFalse(r.verified)
        XCTAssertNil(r.resultToken)
        XCTAssertEqual(r.reason, "ineligible")
    }

    func testParseMissingVerifiedDefaultsFalse() {
        let url = URL(string: "myapp://akedly-passkey")!
        let r = AkedlyPasskeyCeremony.parseResult(from: url)
        XCTAssertFalse(r.verified)
        XCTAssertEqual(r.reason, "failed")
    }

    func testVerifiedWithoutResultTokenIsNotTrusted() {
        // A bare verified=true with no proof token must NOT be reported as a trusted success.
        let url = URL(string: "myapp://akedly-passkey?verified=true")!
        let r = AkedlyPasskeyCeremony.parseResult(from: url)
        XCTAssertFalse(r.verified)
        XCTAssertNil(r.resultToken)
        XCTAssertEqual(r.reason, "no_proof")
    }

    func testWhitespaceOnlyResultTokenIsNotTrusted() {
        // A whitespace-only token is not real proof — treat it as no_proof, not a success.
        let url = URL(string: "myapp://akedly-passkey?verified=true&resultToken=%20%20")!
        let r = AkedlyPasskeyCeremony.parseResult(from: url)
        XCTAssertFalse(r.verified)
        XCTAssertNil(r.resultToken)
        XCTAssertEqual(r.reason, "no_proof")
    }

    func testDuplicateReservedResultParamsFailClosed() {
        let base = "type=AKEDLY_PASSKEY_RESULT&purpose=auth&verified=true&transactionId=tx_9&code=ineligible&resultToken=pkrt1.aaa.bbb"
        let fields = ["type", "purpose", "verified", "transactionId", "code", "resultToken"]
        for name in fields {
            let url = URL(string: "myapp://akedly-passkey?\(base)&\(name)=duplicate")!
            let r = AkedlyPasskeyCeremony.parseResult(from: url)
            XCTAssertFalse(r.verified, "duplicate \(name) must fail closed")
            XCTAssertNil(r.resultToken)
            XCTAssertEqual(r.reason, "failed")
        }
    }

    #if canImport(AuthenticationServices)
    func testSessionCompletionCallbackURLWinsOverError() {
        let url = URL(string: "myapp://akedly-passkey?verified=true&resultToken=pkrt1.aaa.bbb")!
        let r = AkedlyPasskeyCeremony.mapSessionCompletion(callbackURL: url, error: nil)
        XCTAssertTrue(r.verified)
        XCTAssertEqual(r.resultToken, "pkrt1.aaa.bbb")
    }

    func testSessionCompletionUserCancelMapsToClosed() {
        let r = AkedlyPasskeyCeremony.mapSessionCompletion(
            callbackURL: nil,
            error: ASWebAuthenticationSessionError(.canceledLogin)
        )
        XCTAssertFalse(r.verified)
        XCTAssertEqual(r.reason, "closed")
    }

    func testSessionCompletionNonCancelFailuresMapToStartFailed() {
        // Only a user cancel is "closed" — setup failures must not masquerade as one.
        let failures: [Error?] = [
            ASWebAuthenticationSessionError(.presentationContextInvalid),
            ASWebAuthenticationSessionError(.presentationContextNotProvided),
            NSError(domain: "SomeOtherDomain", code: 1),
            nil
        ]
        for error in failures {
            let r = AkedlyPasskeyCeremony.mapSessionCompletion(callbackURL: nil, error: error)
            XCTAssertFalse(r.verified)
            XCTAssertEqual(r.reason, "start_failed")
        }
    }
    #endif
}
