# AGENTS.md — akedly-shield-swift

iOS/macOS Swift client SDK for Akedly's **V1.2 secure REST API**. Three independent pieces under
`Sources/AkedlyShield/`:

| File | What it does |
|---|---|
| `Solver.swift` | Proof-of-work solver — finds a nonce whose `sha256(challenge + ":" + nonce)` has N leading zeros |
| `Turnstile.swift` | Cloudflare Turnstile helper |
| `Passkey.swift` | Hosted V1.2 passkey ceremony at `auth.akedly.io/pk` |

Backend lives in a separate repo (`Akedly`). This SDK never talks to Akedly directly on the
customer's behalf — the customer's own backend proxies, holding the API key.

## Build and test

```bash
swift test
swift build
```

There is **no CI in this repo**. Never claim a build or test run you did not actually see succeed.

## Conventions

- No code comments **except** doc comments (`///`). This is a public SDK — the doc comment on every
  public symbol is the contract customers read, so it is load-bearing. Change behaviour and you
  change the doc comment in the same edit. The few inline `//` comments all explain a non-obvious
  *why* (a double-resume guard, a cancel-vs-error distinction) — match that bar or omit.
- `AkedlyPasskey` is `@MainActor`-isolated, deliberately: `ASWebAuthenticationSession.start()` and
  presentation-anchor access must happen on the main actor. Do not remove the isolation.
- Platform-conditional code is fenced with `#if canImport(AuthenticationServices)` / `UIKit` /
  `AppKit` so the pure parsing layer builds where those are unavailable. Keep pure parsing outside
  the fences so it stays testable everywhere.
- Parsers are fed hostile external input (a callback URL). They must **never** trap — return a
  failed result instead.

## The browser requirement (non-negotiable, all platforms)

The ceremony runs in **`ASWebAuthenticationSession`** on this platform — not a `WKWebView`, not
`SFSafariViewController`, not `UIApplication.open`. The session shares the system credential store,
so platform passkeys (Face ID / Touch ID / device PIN) work, and it captures the return-URL deep link
internally, so the customer needs no `Info.plist` URL scheme or `AppDelegate` plumbing beyond the
`callbackScheme` they pass. Moving the ceremony into a WebView breaks passkeys outright.

The equivalent rule binds the sibling SDKs: Android must use **Chrome Custom Tabs**, Flutter
delegates to both via `flutter_web_auth_2`.

## The cross-SDK contract (identical in kotlin / dart / js — do not diverge)

1. **A verified result MUST carry a `resultToken`** (`Passkey.swift:90`). A claimed-verified callback
   with no token is reported `verified: false`, `reason: "no_proof"` — never as a trusted success.
   **Fail closed. This is the whole security property of the relayed result**, since the callback
   arrives over a custom scheme that cannot be trusted on its own.
2. **The relayed signal is not authoritative.** The customer confirms a sign-in by sending
   `resultToken` to their own backend, which verifies it **offline** by recomputing an HMAC with
   their Akedly API key. No polling, no server-to-server callback needed.
3. **`reason` vocabulary — this SDK's is legitimately richer than Android's.** `nil` when verified,
   else `"closed"` (user dismissed), `"start_failed"` (session could not start, or any non-cancel
   error — e.g. a bad presentation context), `"no_proof"`, `"failed"` (unparseable callback), or a
   server `code`.
   - `"closed"` is a genuine platform difference, **not** an inconsistency to "fix": iOS reports a
     user cancel via `ASWebAuthenticationSessionError.canceledLogin`, while Android's Custom Tab is
     fire-and-forget and cannot signal dismissal at all. Keep the distinction.
   - The cancel-vs-error split at `Passkey.swift:104-116` is deliberate — only `canceledLogin` maps
     to `"closed"`, so an integration bug is never silently reported as "the user changed their mind".
   - ⚠️ **`ineligible` is not a real value — and THIS REPO had it too.** `README.md:131` documented it
     until 2026-07-28. An earlier note here claimed the defect was Dart-only and that this repo was
     clean; that was wrong, and it is why this repo was nearly skipped. Do not reintroduce it.
     Precisely: all three native test suites assert `reason == "ineligible"` when the server sends
     `code=ineligible`, so the SDK *can* surface it by server-`code` passthrough — it is unreachable
     only because **no server sends that code**. The real set is `NO_PASSKEY`, `PASSKEY_DISABLED`,
     `INSUFFICIENT_QUOTA`, `BILLING_FAILED`, `CANCELLED`, `FAILED`.

## Gotchas

- `Passkey.swift:184` carries a double-resume guard: the completion handler and the `start()`-failed
  path can both fire. Removing it risks resuming a continuation twice, which traps in Swift.
- `prefersEphemeralWebBrowserSession = false` is intentional (`Passkey.swift:205`) — it shares Safari
  cookies. Passkeys are OS-level either way, so this is about session continuity, not passkey access.
- `ceremonyOrigin` is injectable so tests and QA can point at a local Auth-Gateway
  (e.g. `http://localhost:5174`) instead of production. Keep it injectable.
