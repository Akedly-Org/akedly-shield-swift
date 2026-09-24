# AkedlyShield (Swift)

Client-side PoW solver, Turnstile helper, and hosted passkey ceremony launcher for Akedly Shield V1.2 (iOS/macOS).

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

**Requires:** iOS 13+ / macOS 10.15 (CryptoKit); Turnstile is iOS-only (WKWebView)

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
//      { APIKey, pipelineID, verificationAddress: { phoneNumber }, powSolution?, turnstileToken?,
//        returnTarget: { "url": "myapp://akedly-passkey" } }  // <-- REQUIRED for the resultToken
//    -> { data: { ceremonyToken } }   (or 404 NO_PASSKEY -> use OTP)
let ceremonyToken = try await myBackend.startPasskeyAuth(phone)

// 2. Run the ceremony. `callbackScheme` is your app's URL scheme.
let passkey = AkedlyPasskey() // or AkedlyPasskey(ceremonyOrigin: "http://localhost:5174") for QA
let result = await passkey.openPasskeyCeremony(token: ceremonyToken, callbackScheme: "myapp")

if result.verified {
    // 3. Confirm offline on YOUR backend — no polling needed. (Akedly also fires the pipeline's
    //    backend callback, if configured; it is unsigned, so the resultToken is the proof.)
    try await myBackend.completeSignIn(resultToken: result.resultToken!)
} else {
    // result.reason: "closed" (cancel) | "busy" (a ceremony is already in flight) | "invalid_url"
    //              | "start_failed" | "no_proof" | "failed" | <server code>
    await runOtpFallback()
}
```

To **enroll** a passkey, pass the `enrollmentToken` from a successful OTP `/verify` as the
`token` instead — the API is identical; enrollment is proven on the next successful sign-in.

> ⚠️ **The result is unproven unless you ask for the proof — on BOTH flows.** The hosted page relays
> a `resultToken` only to a **server-signed** return target. The `returnUrl` this SDK puts in the
> query selects the redirect but is always untrusted, so the token is stripped unless your backend
> passed `returnTarget` (e.g. `{ "url": "myapp://akedly-passkey" }`) — to `/auth-options` when
> authenticating, or to `/verify` when enrolling. Omit it and the ceremony still succeeds, but this
> SDK reports `verified: false` / `no_proof`, because it refuses to call an unproven result verified.
>
> - **Authenticating:** pass `returnTarget` at `/auth-options`, or you will never see
>   `verified: true` in the app and must reconcile against the pipeline's backend callback instead.
> - **Enrolling:** pass it at `/verify`, or treat the enroll result as advisory and let the next
>   successful sign-in be the proof. Do not gate your "passkey enabled" UI on the enroll result alone.

### Native iOS passkeys

On iOS 16 and newer, `AkedlyPasskey.register` and `AkedlyPasskey.authenticate` use the system
platform authenticator directly. They return the exact `attResp` or `authResp` JSON expected by
the V1.2 backend and never make a network request. Your backend must fetch the options, pass the
app identity when it requests them, and post the returned response for verification:

```json
{"nativeApp":{"platform":"ios","appId":"com.example.myapp"}}
```

Pass the returned `data.options` as `Data` (the primary overload) or as a `[String: Any]`
dictionary:

```swift
let authResponse = try await AkedlyPasskey.authenticate(options: optionsData)
try await myBackend.verifyPasskey(authResponse: authResponse)
```

Add the Associated Domains capability with `webcredentials:akedly.io`. For a debug build, also
add `webcredentials:akedly.io?mode=developer`. Register the Team ID and bundle identifier with
Akedly and wait for the app registration to be approved and published. No URL scheme or app-side
API key is required for the native flow.

`AkedlyPasskey.isNativeSupported` is `true` only on iOS 16 or newer. On iOS 13–15, native calls
throw `AkedlyPasskeyError.unsupported`; use `openPasskeyCeremony` as the hosted fallback. The
native SDK also never owns the OTP or `PASSKEY_REPROOF_REQUIRED` fallback: your backend continues
the same transaction through its ordinary OTP flow when native verification asks for re-proof.

| Error | Meaning |
| --- | --- |
| `unsupported` | Native platform passkeys are unavailable on this OS. |
| `cancelled` | The user explicitly cancelled/dismissed the system sheet, iOS found no matching credential, or the task was cancelled. iOS does not expose a separate `noCredential` result. |
| `invalidOptions` | The options JSON is malformed or has no allowed credential. |
| `failed` | Authentication Services returned another error. |

Every non-successful native registration or authentication outcome falls back through the merchant's OTP flow; connectivity failures come from merchant backend calls because this SDK makes no network request.

If backend verification returns `PASSKEY_REPROOF_REQUIRED`, keep the same transaction lineage and
run the merchant's ordinary `/send` then `/verify` OTP flow. Native ceremonies do not use the
hosted continuation token.

> **Presenting reliably on first launch.** By default the session's presentation anchor is
> resolved at ceremony time from the app's **foreground-active key window**. Early in the app
> lifecycle — first launch, a cold-start deep link, mid scene-transition — that window may not
> exist yet and the session can fail to present. If you call `openPasskeyCeremony` early, pass
> your window explicitly: `AkedlyPasskey(presentationAnchor: { myWindow })`.
>
> **App extensions: this library does not build into one.** `defaultPresentationAnchor()` reads
> `UIApplication.shared`, which UIKit marks unavailable in app extensions — and that is a *compile*
> error for any target built with `APPLICATION_EXTENSION_API_ONLY = YES`, whether or not you pass an
> explicit anchor, because the symbol is referenced either way. Run the ceremony from the containing
> app. (Marking the anchor path `@available(iOSApplicationExtension, unavailable)` would turn this
> from a confusing UIKit error into a clear one; it is not done yet because it needs a Mac to
> compile-verify against the `ASWebAuthenticationPresentationContextProviding` conformance.)

### Verify the result (seamless — no polling)

A verified ceremony carries a **`resultToken`**: a compact, signed proof of the outcome. You
confirm a sign-in by verifying it **offline on your own backend** — no `/result` poll, no
server-to-server callback to Akedly. The token is HMAC-signed with **your account API key** (the
same secret you already use to create transactions), so only your backend — which holds that key
— can verify it.

> ⚠️ **Verify on your server, never in the app.** The app forwards `result.resultToken` to your
> backend; your backend verifies it and creates the session. Verifying on-device proves nothing —
> the device is what you are trying to authenticate.
>
> 🛑 **This only works if your API key is not in your app — and the OTP example above puts it
> there.** The proof is an HMAC under your account API key, so *anyone who holds that key can mint
> a `verified: true` token for any transaction*. "Full Integration Example" above sends `apiKey`
> straight from the device, which ships it in your binary where it is trivially extracted. If you
> do both, a user who pulls the key out of your app can enter a victim's phone number, let your
> backend start the transaction, forge a proof for it, and be signed in as that victim.
>
> Pick one:
> - **Route the V1.2 OTP calls through your own backend** so the key never ships in the app
>   (recommended — the passkey `auth-options` call above is already server-side for this reason), or
> - **Don't use offline verification.** Confirm the outcome server-to-server with `GET /result`
>   instead, and treat `resultToken` as a UX-only signal.

**Token format**

```
pkrt1.<base64url(payloadJSON)>.<base64url(signature)>
```

`payloadJSON` (a JSON object, before base64url):

```json
{ "v": 1, "purpose": "auth", "transactionId": "…", "pipelineId": "…",
  "verified": true, "iat": 1730000000000, "exp": 1730000120000 }
```

`iat`/`exp` are **milliseconds** since the Unix epoch (`exp` ≈ 2 minutes after `iat`).

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
3. Reject **non-canonical base64url**: each segment must contain only `[A-Za-z0-9_-]` AND
   round-trip — `base64url-encode(base64url-decode(segment))` must equal the segment exactly.
   Base64's slack bits in the final character mean up to 4 different strings decode to the
   same bytes; without this check, one signed proof has several spellings, defeating a
   string-keyed single-use / replay check.
4. Compute `expected = HMAC_SHA256(apiKey, "pkrt1." + dataSegment)`.
5. **Constant-time-compare** `expected` against `base64url-decode(sigSegment)`. Reject on
   mismatch (forged / tampered).
6. `payload = JSON(base64url-decode(dataSegment))`.
7. Reject if `now_ms > payload.exp` (expired).
8. Require `payload.verified === true`.
9. Require `payload.transactionId ===` the transaction **you** started, and `payload.pipelineId ===`
   your pipeline — this binds the proof to *this* sign-in.
10. Require `payload.purpose === "auth"`. An `"enroll"` proof says a passkey was **registered**,
    not that the holder authenticated — accepting one as a sign-in lets anyone who can enroll a
    passkey log in as the account it was enrolled against.
11. **Consume the token once.** Record the `transactionId` (or the whole token) as spent and reject
    a repeat. The signature stays valid for its full 2-minute life, so without this a token
    observed in a redirect URL, a referrer, or a log can be replayed.

Only after all eleven do you create the session.

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
  if (Buffer.from(data, 'base64url').toString('base64url') !== data ||
      Buffer.from(sig, 'base64url').toString('base64url') !== sig) return null; // canonical only — slack bits in the last char alias one sig to several strings
  const expected = crypto.createHmac('sha256', apiKey).update('pkrt1.' + data).digest();
  const given = Buffer.from(sig, 'base64url');
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  const payload = JSON.parse(Buffer.from(data, 'base64url').toString());
  if (!payload.exp || Date.now() > payload.exp) return null;        // expired
  if (payload.verified !== true) return null;                       // only a verified outcome is trustworthy
  return payload; // verified + unexpired — the caller MUST still bind payload.transactionId to the ceremony it started
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

func base64urlEncode(_ d: Data) -> String {
    return d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

func verifyAkedlyResult(_ token: String, apiKey: String) -> AkedlyClaim? {
    guard !apiKey.isEmpty else { return nil }                       // fail closed: never HMAC under an empty key
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
          base64urlEncode(provided) == sigSegment,                   // canonical only — slack bits in the
          constantTimeEqual(expected, provided),                     // last char alias one sig to several strings
          let payloadData = base64urlDecode(dataSegment),
          base64urlEncode(payloadData) == dataSegment,               // canonical (same rule for the payload)
          let claim = try? JSONDecoder().decode(AkedlyClaim.self, from: payloadData),
          claim.exp > Date().timeIntervalSince1970 * 1000,           // not expired (ms)
          claim.verified                                             // only a verified outcome is trustworthy
    else { return nil }
    return claim
}

// On your sign-in route, after the app POSTs { resultToken }:
//   guard let claim = verifyAkedlyResult(resultToken, apiKey: AKEDLY_API_KEY),
//         claim.transactionId == expectedTxId else { /* reject */ }
//   createSession(user)
```

Treat the token like a one-time auth code: short-lived (~2 min) and accepted once.

### Local vs on-device testing

The `ceremonyOrigin` decides which auth-gateway runs the WebAuthn ceremony — and therefore the
relying-party (RP) ID the passkey binds to.

- **iOS Simulator (local).** Run the simulator on **iOS 16+** and sign it into iCloud
  (Simulator → Settings → sign in) so the platform authenticator can create and use passkeys.
  Pass `AkedlyPasskey(ceremonyOrigin: "http://localhost:5174")` to run the ceremony on the
  local auth-gateway with RP=`localhost` — simulators accept a `localhost` RP and reach the
  host's `localhost` directly.
- **Real device (prod).** Use the default `ceremonyOrigin` (`https://auth.akedly.io`,
  RP=`akedly.io`) — a `localhost` RP cannot bind on a physical device. Your token-minting
  backend must also be reachable from the device.

> There is a full end-to-end V1.2 sandbox — web plus all four mobile SDK reference apps, with a
> headless Playwright + Chrome virtual-authenticator gate — for exercising this loop without a
> physical device.

### Without the launcher (open the page yourself)

`AkedlyPasskey` is a thin convenience wrapper. You can run the exact same ceremony with
`ASWebAuthenticationSession` while still using this package's result parser. The URL construction
below is deliberately spelled out so the session lifecycle and signed-versus-unsigned return-target
boundary remain visible. This iOS example belongs in a target that depends on `AkedlyShield`.

```swift
import AkedlyShield
import AuthenticationServices
import UIKit

final class PasskeyLauncher: NSObject, ASWebAuthenticationPresentationContextProviding {
    // Retain the session for the ceremony's lifetime — a local `let` would deallocate it
    // (and dismiss the sheet) as soon as the enclosing scope returns.
    private var session: ASWebAuthenticationSession?
    private let onFallback: () -> Void
    private let onFailure: (Error?) -> Void

    init(onFallback: @escaping () -> Void, onFailure: @escaping (Error?) -> Void) {
        self.onFallback = onFallback
        self.onFailure = onFailure
    }

    func start(ceremonyToken: String) {
        // Percent-encode the query VALUES (the SDK's buildURL does this for both the token
        // and the returnUrl): myapp://akedly-passkey → myapp%3A%2F%2Fakedly-passkey. A bare
        // `://` in a query value corrupts the query. Ceremony tokens are base64url + `.`
        // (already query-safe), but encode defensively so the example is correct for any value.
        var comps = URLComponents(string: "https://auth.akedly.io/pk")!
        comps.queryItems = [
            URLQueryItem(name: "token", value: ceremonyToken),
            URLQueryItem(name: "returnUrl", value: "myapp://akedly-passkey"),
        ]
        // URLComponents leaves "+" literal in query values; encode it too (matches buildURL).
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let url = comps.url!
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "myapp") { [weak self] callbackURL, error in
            self?.session = nil
            guard let callbackURL else {
                if let asError = error as? ASWebAuthenticationSessionError,
                   asError.code == .canceledLogin {
                    self?.onFallback()
                } else {
                    self?.onFailure(error)
                }
                return
            }
            // callbackURL = myapp://akedly-passkey?verified=true&transactionId=…
            // resultToken rides ONLY if your backend signed returnTarget into the ceremony token
            // at /auth-options. Built by hand from the query alone, the target is untrusted, the
            // token is stripped, and parseResult yields verified:false / no_proof.
            let result = AkedlyPasskeyCeremony.parseResult(from: callbackURL) // or parse the query yourself
            // hand result.resultToken to your backend …
        }
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
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
