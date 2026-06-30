# AkedlyShield (Swift)

Client-side PoW solver and Turnstile helper for Akedly Shield V1.2 (iOS/macOS).

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Akedly-Org/akedly-shield-swift", from: "1.0.0")
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

## Passkeys (V1.2)

Run a hosted V1.2 passkey ceremony on `auth.akedly.io/pk` from a native app. The ceremony
runs in an **`ASWebAuthenticationSession`** (it shares the system credential store, so Face
ID / Touch ID / device-PIN passkeys work) and deep-links the result back to your app — **no
embedded WebView, no passkey entitlement, no associated-domains setup.**

```swift
import AkedlyShield

// 1. Your backend clears the gate + starts the ceremony:
//    POST /api/v1.2/transactions/passkey/auth-options
//      { APIKey, pipelineID, verificationAddress: { phoneNumber }, powSolution?, turnstileToken? }
//    -> { data: { ceremonyToken } }   (or a "no passkey" code -> use OTP)
let ceremonyToken = try await myBackend.startPasskeyAuth(phone)

// 2. Run the ceremony. `callbackScheme` is your app's URL scheme.
let passkey = AkedlyPasskey() // or AkedlyPasskey(ceremonyOrigin: "http://localhost:5174") for QA
let result = await passkey.openPasskeyCeremony(token: ceremonyToken, callbackScheme: "myapp")

if result.verified {
    // 3. Confirm offline on YOUR backend (no polling, no callback) — see below.
    try await myBackend.completeSignIn(resultToken: result.resultToken!)
} else {
    // result.reason: "closed" (cancel) | "ineligible" | "start_failed" | <server code>
    await runOtpFallback()
}
```

To **enroll** a passkey, pass the `enrollmentToken` from a successful OTP `/verify` as the
`token` instead — the API is identical; enrollment is proven on the next successful sign-in.

### Verify the result (seamless — no polling)

A verified ceremony carries a **`resultToken`**: a compact, signed proof of the outcome. You
confirm a sign-in by verifying it **offline on your own backend** — no `/result` poll, no
server-to-server callback to Akedly. The token is HMAC-signed with **your account API key** (the
same secret you already use to create transactions), so only your backend — which holds that key
— can verify it.

> ⚠️ **Verify on your server, never in the app.** Your API key is a server secret. Do **not**
> embed it in the iOS app or verify the token on-device. The app forwards `result.resultToken`
> to your backend; your backend verifies it and creates the session.

**Token format**

```
pkrt1.<base64url(payloadJSON)>.<base64url(signature)>
```

`payloadJSON` (a JSON object, before base64url):

```json
{ "v": 1, "purpose": "auth", "transactionId": "…", "pipelineId": "…",
  "verified": true, "iat": 1730000000000, "exp": 1730000600000 }
```

`iat`/`exp` are **milliseconds** since the Unix epoch (`exp` ≈ 10 minutes after `iat`).

**The signature — exactly what is HMAC'd, in this order**

```
signature = HMAC_SHA256( key = YOUR_API_KEY, message = "pkrt1." + base64url(payloadJSON) )
```

- **algorithm:** HMAC-SHA256.
- **key:** your account API key, as raw UTF-8 bytes.
- **message:** the ASCII string `"pkrt1."` immediately followed by the base64url payload segment
  — i.e. **the whole token with the trailing `.<signature>` removed**. The `pkrt1.` prefix **is
  part of the signed bytes**. (Equivalently: `token` up to, but not including, the final `.`.)
- **base64url is unpadded** (RFC 4648 §5: `+`→`-`, `/`→`_`, `=` stripped). When decoding on a
  platform that requires padding, re-pad to a multiple of 4 with `=`.

**Verification steps (do them all, in order)**

1. Reject if `token` doesn't start with `pkrt1.`.
2. Strip the `pkrt1.` prefix, then split the remainder on `.` — there must be **exactly
   two** segments, `dataSegment` and `sigSegment` (reject otherwise).
3. Compute `expected = HMAC_SHA256(apiKey, "pkrt1." + dataSegment)`.
4. **Constant-time-compare** `expected` against `base64url-decode(sigSegment)`. Reject on
   mismatch (forged / tampered).
5. `payload = JSON(base64url-decode(dataSegment))`.
6. Reject if `now_ms > payload.exp` (expired).
7. Require `payload.verified === true`.
8. Require `payload.transactionId ===` the transaction **you** started — this binds the proof to
   *this* sign-in. Only then create the session.

**Reference verifier — Node.js** (zero deps; portable to any backend language):

```javascript
import crypto from 'node:crypto';

export function verifyAkedlyResult(token, apiKey) {
  if (!apiKey) return null;                                       // fail closed on an empty key
  if (typeof token !== 'string' || !token.startsWith('pkrt1.')) return null;
  const parts = token.slice('pkrt1.'.length).split('.');
  if (parts.length !== 2) return null;                              // exactly two segments
  const [data, sig] = parts;
  const b64u = /^[A-Za-z0-9_-]+$/;                                  // strict unpadded base64url
  if (!b64u.test(data) || !b64u.test(sig)) return null;            // no alternate serializations
  const expected = crypto.createHmac('sha256', apiKey).update('pkrt1.' + data).digest();
  const given = Buffer.from(sig, 'base64url');
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  const payload = JSON.parse(Buffer.from(data, 'base64url').toString());
  if (!payload.exp || Date.now() > payload.exp) return null;        // expired
  return payload; // { verified, purpose, transactionId, pipelineId, ... } — trust it
}
```

**Reference verifier — server-side Swift** (CryptoKit on Apple platforms, or `swift-crypto` /
`import Crypto` on Linux/Vapor):

```swift
import Foundation
import Crypto   // or `import CryptoKit` on Apple platforms

struct AkedlyClaim: Decodable {
    let verified: Bool
    let purpose: String?
    let transactionId: String?
    let pipelineId: String?
    let exp: Double            // milliseconds since epoch
}

func base64urlDecode(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }                              // re-pad
    return Data(base64Encoded: b)
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

func verifyAkedlyResult(_ token: String, apiKey: String) -> AkedlyClaim? {
    let prefix = "pkrt1."
    guard token.hasPrefix(prefix) else { return nil }
    let parts = token.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }                      // exactly two segments
    let dataSegment = String(parts[0])
    let sigSegment  = String(parts[1])
    // Strict, unpadded base64url on both segments — base64urlDecode would otherwise accept
    // padded ("…=") / standard-alphabet spellings of the same bytes, i.e. alternate
    // serializations of one signed proof that could slip past a string-keyed replay check.
    let b64u = "^[A-Za-z0-9_-]+$"
    guard dataSegment.range(of: b64u, options: .regularExpression) != nil,
          sigSegment.range(of: b64u, options: .regularExpression) != nil else { return nil }

    let message = Data((prefix + dataSegment).utf8)                  // "pkrt1." + dataSegment
    let key = SymmetricKey(data: Data(apiKey.utf8))
    let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))

    guard let provided = base64urlDecode(sigSegment),
          constantTimeEqual(expected, provided),
          let payloadData = base64urlDecode(dataSegment),
          let claim = try? JSONDecoder().decode(AkedlyClaim.self, from: payloadData),
          claim.exp > Date().timeIntervalSince1970 * 1000            // not expired (ms)
    else { return nil }
    return claim
}

// On your sign-in route, after the app POSTs { resultToken }:
//   guard let claim = verifyAkedlyResult(resultToken, apiKey: AKEDLY_API_KEY),
//         claim.verified, claim.transactionId == expectedTxId else { /* reject */ }
//   createSession(user)
```

Treat the token like a one-time auth code: short-lived (~10 min) and accepted once.

### Without the SDK (open the page yourself)

`AkedlyPasskey` is a thin convenience wrapper. You can run the exact same ceremony with
nothing but `ASWebAuthenticationSession` (or `SFSafariViewController` / a Custom Tab):

```swift
let url = URL(string: "https://auth.akedly.io/pk?token=\(ceremonyToken)&returnUrl=myapp://akedly-passkey")!
let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "myapp") { callbackURL, _ in
    guard let callbackURL else { return } // nil on user-cancel — fall back to OTP
    // callbackURL = myapp://akedly-passkey?verified=true&transactionId=…&resultToken=pkrt1.…
    let result = AkedlyPasskeyCeremony.parseResult(from: callbackURL) // or parse the query yourself
}
```

The page reads `returnUrl` from the query (or from the `returnTarget` you sign into the
ceremony token server-side via `/auth-options` — preferred for production), runs WebAuthn on
the akedly.io origin, then redirects to `returnUrl` with the result in the query string. The
`AkedlyPasskeyCeremony.buildURL` / `.parseResult` helpers are public if you want the parsing
without the session wrapper.

## Algorithm

```
hash = SHA256(challenge + ":" + String(nonce))   // hex digest
valid = hash.hasPrefix("0" * difficulty)          // leading hex zeros
```

## Related Packages

- **JavaScript**: [`@akedly/shield`](https://www.npmjs.com/package/@akedly/shield)
- **Dart/Flutter**: [`akedly_shield`](https://github.com/Akedly-Org/akedly-shield-dart)
- **Kotlin (Android)**: [`com.akedly.shield`](https://github.com/Akedly-Org/akedly-shield-kotlin)
