import Foundation

/// The result of a hosted V1.2 passkey ceremony (auth.akedly.io/pk), relayed back to the
/// app through the return-URL deep link.
///
/// The relayed signal is **non-authoritative on its own**. Confirm a sign-in by sending
/// `resultToken` to YOUR backend, which verifies it **offline** by recomputing an HMAC with
/// your Akedly API key — no polling, no server-to-server callback. See the README
/// "Verify the result".
public struct AkedlyPasskeyResult: Equatable {
    /// True only on a completed, server-verified ceremony.
    public let verified: Bool
    /// "auth" | "enroll" (nil if the page didn't report it).
    public let purpose: String?
    /// The passkey transaction/request id.
    public let transactionId: String?
    /// Signed, offline-verifiable proof of a verified outcome. Hand it to your backend.
    /// `nil` on any non-verified outcome.
    public let resultToken: String?
    /// `nil` when verified; otherwise a fall-back reason: "closed" (user cancelled),
    /// "busy" (a ceremony is already in flight on this instance), "invalid_url",
    /// "start_failed", "no_proof" (verified with no result token), "failed" (unparseable
    /// callback), or a server code.
    public let reason: String?

    public init(
        verified: Bool,
        purpose: String? = nil,
        transactionId: String? = nil,
        resultToken: String? = nil,
        reason: String? = nil
    ) {
        self.verified = verified
        self.purpose = purpose
        self.transactionId = transactionId
        self.resultToken = resultToken
        self.reason = reason
    }
}

/// Pure, platform-free helpers for the passkey ceremony (so they are unit-tested directly).
/// The actual browser launch lives in `AkedlyPasskey` (ASWebAuthenticationSession).
public enum AkedlyPasskeyCeremony {
    /// Build the hosted ceremony URL: `<origin>/pk?token=…&returnUrl=<scheme>://akedly-passkey`.
    ///
    /// `returnUrl` is passed as a query param so the integration needs no server-side
    /// returnTarget config. For stricter setups, omit `callbackScheme`-as-query and configure
    /// `returnTarget` on `POST /auth-options` instead (it is signed into the ceremony token).
    public static func buildURL(origin: String, token: String, callbackScheme: String) -> URL? {
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        let tok = encodeQueryValue(token)
        let returnUrl = encodeQueryValue("\(callbackScheme)://akedly-passkey")
        return URL(string: "\(trimmed)/pk?token=\(tok)&returnUrl=\(returnUrl)")
    }

    /// Percent-encode a query value so its wire bytes match the Kotlin and Dart SDKs for the
    /// ceremony's ASCII inputs (e.g. `myapp://akedly-passkey` → `myapp%3A%2F%2Fakedly-passkey`).
    /// `URLComponents.queryItems` encodes against `urlQueryAllowed`, which *leaves `:` `/` `&` `=`
    /// `+` literal* — so a returnUrl (or any value carrying a reserved char) would be emitted
    /// un-escaped and corrupt the query. Allow only the unreserved marks (`-._~`) beyond
    /// alphanumerics so every reserved char is escaped — byte-identical to `URLEncoder.encode`
    /// / `Uri.encodeQueryComponent` for the ASCII token and `scheme://akedly-passkey` the
    /// ceremony uses (space→`%20` vs the siblings' `+` only diverges on inputs those values
    /// never contain).
    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Map the deep-link callback URL's query params to a result.
    ///
    /// A result is only reported `verified` when the page also delivered a non-empty
    /// `resultToken` — the offline-verifiable proof. A bare `…?verified=true` with no token
    /// (a malformed or externally-triggered intent) is surfaced as `verified: false`,
    /// `reason: "no_proof"`, never as a trusted success.
    public static func parseResult(from url: URL) -> AkedlyPasskeyResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        let claimedVerified = (q("verified") ?? "false") == "true"
        let token = q("resultToken")
        let hasProof = !((token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
        let verified = claimedVerified && hasProof
        return AkedlyPasskeyResult(
            verified: verified,
            purpose: q("purpose"),
            transactionId: q("transactionId"),
            resultToken: verified ? token : nil,
            reason: verified ? nil : (claimedVerified ? "no_proof" : (q("code") ?? "failed"))
        )
    }
}

#if canImport(AuthenticationServices)
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Runs the hosted V1.2 passkey ceremony in an `ASWebAuthenticationSession`. The session
/// shares the system credential store, so platform passkeys (Face ID / Touch ID / device
/// PIN) work, and it captures the page's return-URL deep link internally — no Info.plist
/// URL scheme or `AppDelegate` plumbing required beyond the `callbackScheme` you pass.
@available(iOS 13.0, macOS 10.15, *)
@MainActor
public final class AkedlyPasskey: NSObject {
    private let ceremonyOrigin: String
    private let presentationAnchorProvider: (() -> ASPresentationAnchor)?
    private var session: ASWebAuthenticationSession?

    /// - Parameters:
    ///   - ceremonyOrigin: hosted ceremony origin. Defaults to production; point it at the
    ///     QA Auth-Gateway (e.g. `http://localhost:5174`) for testing.
    ///   - presentationAnchor: optional provider for the window the session presents from.
    ///     Defaults to a best-effort anchor; provide your key window for reliable presentation.
    public init(
        ceremonyOrigin: String = "https://auth.akedly.io",
        presentationAnchor: (() -> ASPresentationAnchor)? = nil
    ) {
        self.ceremonyOrigin = ceremonyOrigin
        self.presentationAnchorProvider = presentationAnchor
        super.init()
    }

    /// Run a hosted passkey ceremony. Resolves when the page deep-links the result back via
    /// `callbackScheme`. **Never throws on a user cancel** — it returns `verified: false`,
    /// `reason: "closed"` so you can fall straight through to OTP.
    ///
    /// Calling this while a ceremony from the same instance is still in flight resolves
    /// immediately with `reason: "busy"` and leaves the running ceremony untouched — start a
    /// second `AkedlyPasskey` if you need concurrent ceremonies.
    ///
    /// The whole `AkedlyPasskey` class is `@MainActor`-isolated: `ASWebAuthenticationSession.start()`,
    /// the `session` reentrancy state, and presentation-anchor resolution all touch
    /// AuthenticationServices/UIKit, which require the main thread. Callers on any executor can
    /// `await` it — the hop is implicit.
    ///
    /// - Parameters:
    ///   - token: the ceremony token (`POST /auth-options`) or enrollment token (OTP `/verify`).
    ///   - callbackScheme: your app's URL scheme (e.g. `"myapp"`).
    @available(iOS 13.0, macOS 10.15, *)
    public func openPasskeyCeremony(token: String, callbackScheme: String) async -> AkedlyPasskeyResult {
        guard let url = AkedlyPasskeyCeremony.buildURL(
            origin: ceremonyOrigin, token: token, callbackScheme: callbackScheme
        ) else {
            return AkedlyPasskeyResult(verified: false, reason: "invalid_url")
        }

        // Reentrancy guard: one ceremony per instance. Starting a second over a live one would
        // overwrite `session`, releasing the in-flight session and orphaning its continuation.
        // `@MainActor` serializes this check with the assignment below, so it cannot race.
        if session != nil {
            return AkedlyPasskeyResult(verified: false, reason: "busy")
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<AkedlyPasskeyResult, Never>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, _ in
                if let callbackURL = callbackURL {
                    continuation.resume(returning: AkedlyPasskeyCeremony.parseResult(from: callbackURL))
                } else {
                    // user cancelled or the session failed — a retryable, non-fatal outcome
                    continuation.resume(returning: AkedlyPasskeyResult(verified: false, reason: "closed"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // share the credential store
            self.session = session
            if !session.start() {
                continuation.resume(returning: AkedlyPasskeyResult(verified: false, reason: "start_failed"))
            }
        }
        self.session = nil // ceremony resolved — release for the next call (main-actor-isolated)
        return result
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension AkedlyPasskey: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let provider = presentationAnchorProvider { return provider() }
        return AkedlyPasskey.defaultPresentationAnchor()
    }

    /// Best-effort foreground window for the auth session. `ASWebAuthenticationSession`
    /// rejects a detached anchor (a bare `UIWindow()`/`NSWindow()` not attached to a
    /// foreground scene), so resolve the app's active key window instead. Pass an explicit
    /// `presentationAnchor` to `init` if you manage windows yourself.
    static func defaultPresentationAnchor() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = windowScenes.first(where: { $0.activationState == .foregroundActive }) ?? windowScenes.first
        if let scene = scene {
            return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first ?? UIWindow(windowScene: scene)
        }
        return UIWindow()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
