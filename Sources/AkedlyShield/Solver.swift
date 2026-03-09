import Foundation
import CryptoKit

public func solvePowSync(challenge: String, difficulty: Int) -> Int {
    let prefix = String(repeating: "0", count: difficulty)
    var nonce = 0
    while true {
        let input = "\(challenge):\(nonce)"
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex.hasPrefix(prefix) {
            return nonce
        }
        nonce += 1
    }
}

public func solvePow(challenge: String, difficulty: Int) async -> Int {
    return await Task.detached(priority: .userInitiated) {
        let prefix = String(repeating: "0", count: difficulty)
        var nonce = 0
        while true {
            let input = "\(challenge):\(nonce)"
            let data = Data(input.utf8)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if hex.hasPrefix(prefix) {
                return nonce
            }
            nonce += 1
            if nonce % 10000 == 0 {
                await Task.yield()
            }
        }
    }.value
}
