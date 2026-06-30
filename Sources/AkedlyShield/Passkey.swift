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
    /// "invalid_url", "start_failed", or a server code.
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
        var comps = URLComponents(string: "\(trimmed)/pk")
        comps?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "returnUrl", value: "\(callbackScheme)://akedly-passkey"),
        ]
        return comps?.url
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

        return await withCheckedContinuation { (continuation: CheckedContinuation<AkedlyPasskeyResult, Never>) in
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
                self.session = nil
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // share the credential store
            self.session = session
            if !session.start() {
                self.session = nil // don't retain the failed session (it captures self)
                continuation.resume(returning: AkedlyPasskeyResult(verified: false, reason: "start_failed"))
            }
        }
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
