import Foundation

/// Errors raised by the native iOS passkey ceremony APIs.
public enum AkedlyPasskeyError: Error {
    /// The current operating system cannot provide native platform passkeys.
    case unsupported
    /// The user dismissed the native passkey sheet, no matching iOS credential was available,
    /// or the surrounding task was cancelled.
    case cancelled
    /// The ceremony options or native response could not be mapped to the WebAuthn JSON shape.
    case invalidOptions
    /// Authentication Services returned a non-cancellation failure.
    case failed(Error)
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        let scalars = value.unicodeScalars
        guard scalars.allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                return true
            default:
                return false
            }
        }) else {
            return nil
        }

        let remainder = value.utf8.count % 4
        guard remainder != 1 else { return nil }
        let padding = (4 - remainder) % 4
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: padding)
        guard let decoded = Data(base64Encoded: standard),
              decoded.base64URLEncodedString() == value else {
            return nil
        }
        self = decoded
    }
}

struct AkedlyPasskeyNativeRegistrationOptions {
    let challenge: Data
    let rpId: String
    let userName: String
    let userID: Data
    let excludedCredentialIDs: [Data]
}

struct AkedlyPasskeyNativeAssertionOptions {
    let challenge: Data
    let rpId: String
    let allowedCredentialIDs: [Data]
}

struct AkedlyPasskeyNativeRegistrationResult {
    let credentialID: Data
    let clientDataJSON: Data
    let attestationObject: Data
}

struct AkedlyPasskeyNativeAssertionResult {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    let userID: Data?
}

enum AkedlyPasskeyNativeMapper {
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AkedlyPasskeyError.invalidOptions
        }
        return dictionary
    }

    static func data(from object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AkedlyPasskeyError.invalidOptions
        }
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw AkedlyPasskeyError.invalidOptions
        }
    }

    static func registrationOptions(from object: [String: Any]) throws -> AkedlyPasskeyNativeRegistrationOptions {
        guard let challengeValue = object["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeValue),
              !challenge.isEmpty,
              let relyingParty = object["rp"] as? [String: Any],
              let rpId = relyingParty["id"] as? String,
              !rpId.isEmpty,
              let user = object["user"] as? [String: Any],
              let userName = user["name"] as? String,
              !userName.isEmpty,
              let userIDValue = user["id"] as? String,
              let userID = Data(base64URLEncoded: userIDValue),
              !userID.isEmpty else {
            throw AkedlyPasskeyError.invalidOptions
        }

        let excludedCredentialIDs = try credentialIDs(
            from: object["excludeCredentials"],
            required: false
        )
        return AkedlyPasskeyNativeRegistrationOptions(
            challenge: challenge,
            rpId: rpId,
            userName: userName,
            userID: userID,
            excludedCredentialIDs: excludedCredentialIDs
        )
    }

    static func assertionOptions(from object: [String: Any]) throws -> AkedlyPasskeyNativeAssertionOptions {
        guard let challengeValue = object["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeValue),
              !challenge.isEmpty,
              let rpId = object["rpId"] as? String,
              !rpId.isEmpty else {
            throw AkedlyPasskeyError.invalidOptions
        }

        let allowedCredentialIDs = try credentialIDs(
            from: object["allowCredentials"],
            required: true
        )
        return AkedlyPasskeyNativeAssertionOptions(
            challenge: challenge,
            rpId: rpId,
            allowedCredentialIDs: allowedCredentialIDs
        )
    }

    static func registrationObject(from result: AkedlyPasskeyNativeRegistrationResult) -> [String: Any] {
        let credentialID = result.credentialID.base64URLEncodedString()
        return [
            "id": credentialID,
            "rawId": credentialID,
            "type": "public-key",
            "response": [
                "clientDataJSON": result.clientDataJSON.base64URLEncodedString(),
                "attestationObject": result.attestationObject.base64URLEncodedString()
            ],
            "clientExtensionResults": [:],
            "authenticatorAttachment": "platform"
        ]
    }

    static func assertionObject(from result: AkedlyPasskeyNativeAssertionResult) -> [String: Any] {
        let credentialID = result.credentialID.base64URLEncodedString()
        var response: [String: Any] = [
            "clientDataJSON": result.clientDataJSON.base64URLEncodedString(),
            "authenticatorData": result.authenticatorData.base64URLEncodedString(),
            "signature": result.signature.base64URLEncodedString()
        ]
        if let userID = result.userID {
            response["userHandle"] = userID.base64URLEncodedString()
        }
        return [
            "id": credentialID,
            "rawId": credentialID,
            "type": "public-key",
            "response": response,
            "clientExtensionResults": [:],
            "authenticatorAttachment": "platform"
        ]
    }

    private static func credentialIDs(
        from value: Any?,
        required: Bool
    ) throws -> [Data] {
        guard let value else {
            if required { throw AkedlyPasskeyError.invalidOptions }
            return []
        }
        guard let descriptors = value as? [Any] else {
            throw AkedlyPasskeyError.invalidOptions
        }
        if required && descriptors.isEmpty {
            throw AkedlyPasskeyError.invalidOptions
        }
        return try descriptors.map { descriptor in
            guard let dictionary = descriptor as? [String: Any],
                  let idValue = dictionary["id"] as? String,
                  let id = Data(base64URLEncoded: idValue),
                  !id.isEmpty else {
                throw AkedlyPasskeyError.invalidOptions
            }
            return id
        }
    }
}

#if canImport(AuthenticationServices)
import AuthenticationServices

@available(iOS 13.0, macOS 10.15, *)
public extension AkedlyPasskey {
    /// Indicates whether this process can run the native platform passkey ceremony.
    nonisolated static var isNativeSupported: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) { return true }
        #endif
        return false
    }

    /// Registers a platform passkey from the WebAuthn registration options returned by Akedly.
    /// The data must be the JSON object from `data.options`; the SDK does not make a network
    /// request or carry an Akedly API key.
    ///
    /// - Parameters:
    ///   - options: JSON registration options returned by the merchant backend.
    ///   - presentationAnchor: Optional window provider for the native authorization sheet.
    /// - Throws: `AkedlyPasskeyError.unsupported` below iOS 16 or on macOS,
    ///   `AkedlyPasskeyError.cancelled` when the user dismisses the sheet, iOS finds no matching
    ///   credential, or the surrounding task is cancelled,
    ///   `AkedlyPasskeyError.invalidOptions` for malformed WebAuthn JSON, or
    ///   `AkedlyPasskeyError.failed` for another Authentication Services failure.
    /// - Returns: The JSON object to send as `attResp` to the merchant backend.
    static func register(
        options: Data,
        presentationAnchor: (() -> ASPresentationAnchor)? = nil
    ) async throws -> Data {
        #if os(iOS)
        guard #available(iOS 16.0, *) else { throw AkedlyPasskeyError.unsupported }
        let object = try AkedlyPasskeyNativeMapper.object(from: options)
        let mapped = try AkedlyPasskeyNativeMapper.registrationOptions(from: object)
        return try await AkedlyPasskeyNativePlatform.register(
            options: mapped,
            presentationAnchor: presentationAnchor
        )
        #else
        throw AkedlyPasskeyError.unsupported
        #endif
    }

    /// Registers a platform passkey from a WebAuthn registration options dictionary.
    /// This is a convenience wrapper around the data-first overload.
    ///
    /// - Parameters:
    ///   - options: Registration options returned by the merchant backend.
    ///   - presentationAnchor: Optional window provider for the native authorization sheet.
    /// - Throws: The same errors as the data-first `register(options:presentationAnchor:)` overload.
    /// - Returns: The response dictionary to send as `attResp` to the merchant backend.
    @MainActor
    static func register(
        options: [String: Any],
        presentationAnchor: (() -> ASPresentationAnchor)? = nil
    ) async throws -> [String: Any] {
        let optionsData = try AkedlyPasskeyNativeMapper.data(from: options)
        let responseData = try await register(
            options: optionsData,
            presentationAnchor: presentationAnchor
        )
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AkedlyPasskeyError.invalidOptions
        }
        return response
    }

    /// Authenticates a platform passkey from the WebAuthn assertion options returned by Akedly.
    /// The data must be the JSON object from `data.options`; the SDK does not make a network
    /// request or carry an Akedly API key.
    ///
    /// - Parameters:
    ///   - options: JSON assertion options returned by the merchant backend.
    ///   - presentationAnchor: Optional window provider for the native authorization sheet.
    /// - Throws: `AkedlyPasskeyError.unsupported` below iOS 16 or on macOS,
    ///   `AkedlyPasskeyError.cancelled` when the user dismisses the sheet, iOS finds no matching
    ///   credential, or the surrounding task is cancelled,
    ///   `AkedlyPasskeyError.invalidOptions` for malformed WebAuthn JSON, or
    ///   `AkedlyPasskeyError.failed` for another Authentication Services failure.
    /// - Returns: The JSON object to send as `authResp` to the merchant backend.
    static func authenticate(
        options: Data,
        presentationAnchor: (() -> ASPresentationAnchor)? = nil
    ) async throws -> Data {
        #if os(iOS)
        guard #available(iOS 16.0, *) else { throw AkedlyPasskeyError.unsupported }
        let object = try AkedlyPasskeyNativeMapper.object(from: options)
        let mapped = try AkedlyPasskeyNativeMapper.assertionOptions(from: object)
        return try await AkedlyPasskeyNativePlatform.authenticate(
            options: mapped,
            presentationAnchor: presentationAnchor
        )
        #else
        throw AkedlyPasskeyError.unsupported
        #endif
    }

    /// Authenticates a platform passkey from a WebAuthn assertion options dictionary.
    /// This is a convenience wrapper around the data-first overload.
    ///
    /// - Parameters:
    ///   - options: Assertion options returned by the merchant backend.
    ///   - presentationAnchor: Optional window provider for the native authorization sheet.
    /// - Throws: The same errors as the data-first `authenticate(options:presentationAnchor:)` overload.
    /// - Returns: The response dictionary to send as `authResp` to the merchant backend.
    @MainActor
    static func authenticate(
        options: [String: Any],
        presentationAnchor: (() -> ASPresentationAnchor)? = nil
    ) async throws -> [String: Any] {
        let optionsData = try AkedlyPasskeyNativeMapper.data(from: options)
        let responseData = try await authenticate(
            options: optionsData,
            presentationAnchor: presentationAnchor
        )
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AkedlyPasskeyError.invalidOptions
        }
        return response
    }
}

#if os(iOS)
@available(iOS 16.0, *)
@MainActor
private enum AkedlyPasskeyNativePlatform {
    static func register(
        options: AkedlyPasskeyNativeRegistrationOptions,
        presentationAnchor: (() -> ASPresentationAnchor)?
    ) async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: options.challenge,
            name: options.userName,
            userID: options.userID
        )
        request.userVerificationPreference = .required
        if #available(iOS 17.4, *) {
            request.excludedCredentials = options.excludedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        let authorization = try await run(
            request: request,
            presentationAnchor: presentationAnchor
        )
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = credential.rawAttestationObject else {
            throw AkedlyPasskeyError.failed(AkedlyPasskeyNativeError.unexpectedCredential)
        }
        return try AkedlyPasskeyNativeMapper.data(from: AkedlyPasskeyNativeMapper.registrationObject(
            from: AkedlyPasskeyNativeRegistrationResult(
                credentialID: credential.credentialID,
                clientDataJSON: credential.rawClientDataJSON,
                attestationObject: attestationObject
            )
        ))
    }

    static func authenticate(
        options: AkedlyPasskeyNativeAssertionOptions,
        presentationAnchor: (() -> ASPresentationAnchor)?
    ) async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)
        request.allowedCredentials = options.allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        request.userVerificationPreference = .required
        let authorization = try await run(
            request: request,
            presentationAnchor: presentationAnchor
        )
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AkedlyPasskeyError.failed(AkedlyPasskeyNativeError.unexpectedCredential)
        }
        return try AkedlyPasskeyNativeMapper.data(from: AkedlyPasskeyNativeMapper.assertionObject(
            from: AkedlyPasskeyNativeAssertionResult(
                credentialID: credential.credentialID,
                clientDataJSON: credential.rawClientDataJSON,
                authenticatorData: credential.rawAuthenticatorData,
                signature: credential.signature,
                userID: credential.userID
            )
        ))
    }

    private static func run(
        request: ASAuthorizationRequest,
        presentationAnchor: (() -> ASPresentationAnchor)?
    ) async throws -> ASAuthorization {
        let coordinator = AkedlyPasskeyNativeCoordinator(
            presentationAnchor: presentationAnchor ?? { AkedlyPasskey.defaultPresentationAnchor() }
        )
        return try await withTaskCancellationHandler(operation: {
            try await coordinator.perform(request: request)
        }, onCancel: {
            Task { @MainActor in coordinator.cancel() }
        })
    }
}

@available(iOS 16.0, *)
private enum AkedlyPasskeyNativeError: Error {
    case unexpectedCredential
}

@available(iOS 16.0, *)
@MainActor
private final class AkedlyPasskeyNativeCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let presentationAnchor: () -> ASPresentationAnchor
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    init(presentationAnchor: @escaping () -> ASPresentationAnchor) {
        self.presentationAnchor = presentationAnchor
        super.init()
    }

    func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        if Task.isCancelled {
            throw AkedlyPasskeyError.cancelled
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func cancel() {
        controller?.cancel()
        finish(.failure(AkedlyPasskeyError.cancelled))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            finish(.failure(AkedlyPasskeyError.cancelled))
        } else {
            finish(.failure(AkedlyPasskeyError.failed(error)))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(with: result)
    }
}
#endif
#endif
