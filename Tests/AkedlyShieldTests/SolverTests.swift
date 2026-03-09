import XCTest
import CryptoKit
@testable import AkedlyShield

final class SolverTests: XCTestCase {

    func verifyNonce(challenge: String, nonce: Int, difficulty: Int) -> Bool {
        let input = "\(challenge):\(nonce)"
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(repeating: "0", count: difficulty)
        return hex.hasPrefix(prefix)
    }

    func testSolvePowSyncDifficulty3() {
        let challenge = String(repeating: "a", count: 64)
        let nonce = solvePowSync(challenge: challenge, difficulty: 3)
        XCTAssertTrue(verifyNonce(challenge: challenge, nonce: nonce, difficulty: 3))
    }

    func testSolvePowSyncDifficulty4() {
        let challenge = String(repeating: "a", count: 64)
        let nonce = solvePowSync(challenge: challenge, difficulty: 4)
        XCTAssertTrue(verifyNonce(challenge: challenge, nonce: nonce, difficulty: 4))
    }

    func testSolvePowAsyncDifficulty3() async {
        let challenge = String(repeating: "a", count: 64)
        let nonce = await solvePow(challenge: challenge, difficulty: 3)
        XCTAssertTrue(verifyNonce(challenge: challenge, nonce: nonce, difficulty: 3))
    }

    func testSolvePowAsyncDifficulty4() async {
        let challenge = String(repeating: "a", count: 64)
        let nonce = await solvePow(challenge: challenge, difficulty: 4)
        XCTAssertTrue(verifyNonce(challenge: challenge, nonce: nonce, difficulty: 4))
    }

    func testSyncAndAsyncProduceSameNonce() async {
        let challenge = String(repeating: "a", count: 64)
        let syncNonce = solvePowSync(challenge: challenge, difficulty: 3)
        let asyncNonce = await solvePow(challenge: challenge, difficulty: 3)
        XCTAssertEqual(syncNonce, asyncNonce)
    }
}
