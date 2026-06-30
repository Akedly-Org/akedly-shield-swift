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
        XCTAssertTrue(s.contains("returnUrl=myapp://akedly-passkey"))
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
}
