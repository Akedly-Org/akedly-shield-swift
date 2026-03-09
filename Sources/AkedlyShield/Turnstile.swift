#if canImport(WebKit) && canImport(UIKit)
import Foundation
import WebKit

public class AkedlyTurnstile: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private let bridgeDomain: String

    public init(bridgeDomain: String = "turnstile.akedly.io") {
        self.bridgeDomain = bridgeDomain
        super.init()
    }

    public func getToken(siteKey: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            DispatchQueue.main.async {
                let config = WKWebViewConfiguration()
                config.userContentController.add(self, name: "turnstile")

                let webView = WKWebView(frame: .zero, configuration: config)
                self.webView = webView

                let urlString = "https://\(self.bridgeDomain)/challenge?sitekey=\(siteKey)"
                if let url = URL(string: urlString) {
                    webView.load(URLRequest(url: url))
                } else {
                    self.continuation?.resume(throwing: AkedlyTurnstileError.invalidURL)
                    self.continuation = nil
                    self.cleanup()
                }
            }
        }
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        switch event {
        case "verify":
            if let token = json["token"] as? String {
                continuation?.resume(returning: token)
                continuation = nil
                cleanup()
            }
        case "error":
            let errorMsg = json["error"] as? String ?? "Unknown error"
            continuation?.resume(throwing: AkedlyTurnstileError.verificationFailed(errorMsg))
            continuation = nil
            cleanup()
        case "expired":
            continuation?.resume(throwing: AkedlyTurnstileError.tokenExpired)
            continuation = nil
            cleanup()
        default:
            break
        }
    }

    private func cleanup() {
        DispatchQueue.main.async {
            self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
            self.webView?.stopLoading()
            self.webView = nil
        }
    }
}

public enum AkedlyTurnstileError: Error {
    case invalidURL
    case verificationFailed(String)
    case tokenExpired
}
#endif
