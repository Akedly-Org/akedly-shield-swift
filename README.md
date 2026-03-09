# AkedlyShield (Swift)

Client-side PoW solver and Turnstile helper for Akedly Shield V1.2 (iOS/macOS).

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AkedlyIO/akedly-shield", from: "1.0.0")
]
```

Or in Xcode: File > Add Package Dependencies > enter the repository URL.

## Quick Start

```swift
import AkedlyShield

// Async solver (recommended)
let nonce = await solvePow(challenge: challenge, difficulty: difficulty)

// Sync solver (blocks current thread)
let nonce = solvePowSync(challenge: challenge, difficulty: difficulty)
```

## API

### `solvePow(challenge:difficulty:) async -> Int`

Async function using Swift concurrency. Runs on a background thread via `Task.detached` and yields every 10,000 iterations for cooperative cancellation.

### `solvePowSync(challenge:difficulty:) -> Int`

Synchronous solver. Blocks until a valid nonce is found. Use on background queues only.

### `AkedlyTurnstile` (iOS)

Creates a hidden `WKWebView` to load the Turnstile bridge page and retrieve a token.

```swift
let turnstile = AkedlyTurnstile()
let token = try await turnstile.getToken(siteKey: "your-site-key")
// Use token in your API request as turnstileToken
```

**Parameters:**
- `bridgeDomain` — bridge page domain (default: `turnstile.akedly.io`)

**Requires:** iOS 13+ (CryptoKit + WKWebView)

## Full Integration Example

```swift
import AkedlyShield

func sendOTP(phone: String, apiKey: String, pipelineID: String) async throws {
    // 1. Get challenge
    let url = URL(string: "https://api.akedly.io/api/v1.2/transactions/challenge?APIKey=\(apiKey)&pipelineID=\(pipelineID)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let challengeData = json["data"] as! [String: Any]

    // 2. Solve PoW
    var powSolution: [String: Any]?
    if challengeData["challengeRequired"] as? Bool == true {
        let challenge = challengeData["challenge"] as! String
        let difficulty = challengeData["difficulty"] as! Int
        let nonce = await solvePow(challenge: challenge, difficulty: difficulty)
        powSolution = [
            "challengeToken": challengeData["challengeToken"]!,
            "nonce": nonce
        ]
    }

    // 3. Get Turnstile token (if required)
    var turnstileToken: String?
    if let turnstile = challengeData["turnstile"] as? [String: Any],
       turnstile["required"] as? Bool == true,
       let siteKey = turnstile["siteKey"] as? String {
        let ts = AkedlyTurnstile()
        turnstileToken = try await ts.getToken(siteKey: siteKey)
    }

    // 4. Send OTP
    var body: [String: Any] = [
        "APIKey": apiKey,
        "pipelineID": pipelineID,
        "verificationAddress": ["phoneNumber": phone]
    ]
    if let pow = powSolution { body["powSolution"] = pow }
    if let tt = turnstileToken { body["turnstileToken"] = tt }

    var request = URLRequest(url: URL(string: "https://api.akedly.io/api/v1.2/transactions/send")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (_, _) = try await URLSession.shared.data(for: request)
}
```

## Algorithm

```
hash = SHA256(challenge + ":" + String(nonce))   // hex digest
valid = hash.hasPrefix("0" * difficulty)          // leading hex zeros
```

## Related Packages

- **JavaScript**: [`@akedly/shield`](https://www.npmjs.com/package/@akedly/shield)
- **Dart/Flutter**: [`akedly_shield`](https://github.com/Akedly-Org/akedly-shield-dart)
- **Kotlin (Android)**: [`com.akedly.shield`](https://github.com/Akedly-Org/akedly-shield-kotlin)
