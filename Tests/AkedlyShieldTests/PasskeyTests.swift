import XCTest
@testable import AkedlyShield

final class PasskeyTests: XCTestCase {

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
        XCTAssertEqual(url?.absoluteString.contains("//localhost:5174/pk?"), true)
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
}
