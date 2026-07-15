//
//  PasskeyService.swift
//  scripty
//
//  Drives the WebAuthn ceremonies against Spring Security's passkey endpoints,
//  bridging Apple's AuthenticationServices to the exact JSON the framework's
//  own browser client (spring-security-webauthn.js) sends.
//
//  Sign-in is a two-request ceremony (options → assertion) and registration is
//  likewise (options → attestation). Spring keeps the per-ceremony challenge in
//  the HTTP session, so both calls of a ceremony must ride the same JSESSIONID —
//  hence a dedicated cookie-carrying URLSession per PasskeyService instance,
//  distinct from APIClient's deliberately cookieless one.
//

import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class PasskeyService: NSObject {
    enum PasskeyError: LocalizedError {
        case cancelled
        case malformedServerResponse
        case notAuthenticated
        case server(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Passkey sign-in was cancelled."
            case .malformedServerResponse:
                return "The server sent an unexpected passkey response."
            case .notAuthenticated:
                return "The passkey wasn't accepted."
            case .server(let message):
                return message
            }
        }
    }

    /// Sent so the backend knows to mint an API token in the /login/webauthn body.
    static let clientHeader = "X-Scripty-Client"
    static let clientValue = "ios"

    private let baseURL: URL
    private let session: URLSession
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    init(baseURL: URL = AppConfig.baseURL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
        super.init()
    }

    // MARK: - Sign in (cold, discoverable)

    /// Runs a passkey assertion and returns the bearer credential the backend
    /// minted for it. No prior authentication required.
    func signIn() async throws -> Credentials {
        let options = try await post(AuthenticationOptions.self,
                                     path: "webauthn/authenticate/options",
                                     authorization: nil)
        guard let challenge = Data(base64URL: options.challenge) else {
            throw PasskeyError.malformedServerResponse
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = (options.allowCredentials ?? []).compactMap { credential in
            guard let id = Data(base64URL: credential.id) else { return nil }
            return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id)
        }

        let authorization = try await perform(request)
        guard let assertion = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.malformedServerResponse
        }

        let body = AssertionRequest(
            id: assertion.credentialID.base64URLString,
            rawId: assertion.credentialID.base64URLString,
            response: .init(
                authenticatorData: assertion.rawAuthenticatorData.base64URLString,
                clientDataJSON: assertion.rawClientDataJSON.base64URLString,
                signature: assertion.signature.base64URLString,
                userHandle: assertion.userID.base64URLString))

        let result = try await post(LoginResponse.self,
                                    path: "login/webauthn",
                                    authorization: nil,
                                    body: body)
        guard result.authenticated, let token = result.token,
              let username = result.username else {
            throw PasskeyError.notAuthenticated
        }
        return Credentials(token: token, username: username)
    }

    // MARK: - Register (while signed in)

    /// Registers a new passkey for the already-signed-in user. `authorization`
    /// is the session's current credential (Basic or Bearer).
    func register(label: String, authorization: Credentials) async throws {
        let options = try await post(RegistrationOptions.self,
                                     path: "webauthn/register/options",
                                     authorization: authorization)
        guard let challenge = Data(base64URL: options.challenge),
              let userID = Data(base64URL: options.user.id) else {
            throw PasskeyError.malformedServerResponse
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rp.id)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: options.user.name, userID: userID)

        let authz = try await perform(request)
        guard let registration = authz.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = registration.rawAttestationObject else {
            throw PasskeyError.malformedServerResponse
        }

        let body = RegistrationRequest(publicKey: .init(
            credential: .init(
                id: registration.credentialID.base64URLString,
                rawId: registration.credentialID.base64URLString,
                response: .init(
                    attestationObject: attestationObject.base64URLString,
                    clientDataJSON: registration.rawClientDataJSON.base64URLString,
                    transports: ["internal", "hybrid"])),
            label: label))

        _ = try await postRaw(path: "webauthn/register", authorization: authorization, body: body)
    }

    // MARK: - AuthenticationServices bridge

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Networking

    private func post<T: Decodable>(_ type: T.Type, path: String,
                                    authorization: Credentials?,
                                    body: (any Encodable)? = nil) async throws -> T {
        let data = try await postRaw(path: path, authorization: authorization, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PasskeyError.malformedServerResponse
        }
    }

    @discardableResult
    private func postRaw(path: String, authorization: Credentials?,
                         body: (any Encodable)? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientValue, forHTTPHeaderField: Self.clientHeader)
        if let authorization {
            request.setValue(authorization.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PasskeyError.malformedServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw PasskeyError.server("Passkey request failed (\(http.statusCode)). \(detail)")
        }
        return data
    }
}

// MARK: - Delegate & presentation

extension PasskeyService: ASAuthorizationControllerDelegate,
                          ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            continuation?.resume(throwing: PasskeyError.cancelled)
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}

// MARK: - Wire formats (mirror spring-security-webauthn.js exactly)

private struct AuthenticationOptions: Decodable {
    let challenge: String
    let rpId: String
    let allowCredentials: [AllowCredential]?

    struct AllowCredential: Decodable {
        let id: String
    }
}

private struct RegistrationOptions: Decodable {
    let challenge: String
    let rp: RelyingParty
    let user: UserEntity

    struct RelyingParty: Decodable {
        let id: String
        let name: String
    }

    struct UserEntity: Decodable {
        let id: String
        let name: String
        let displayName: String
    }
}

private struct LoginResponse: Decodable {
    let authenticated: Bool
    let token: String?
    let username: String?
}

private struct EmptyObject: Encodable {}

private struct AssertionRequest: Encodable {
    let id: String
    let rawId: String
    let response: Response
    let credType = "public-key"
    let clientExtensionResults = EmptyObject()
    let authenticatorAttachment = "platform"

    struct Response: Encodable {
        let authenticatorData: String
        let clientDataJSON: String
        let signature: String
        let userHandle: String?
    }
}

private struct RegistrationRequest: Encodable {
    let publicKey: PublicKey

    struct PublicKey: Encodable {
        let credential: Credential
        let label: String
    }

    struct Credential: Encodable {
        let id: String
        let rawId: String
        let response: Response
        let type = "public-key"
        let clientExtensionResults = EmptyObject()
        let authenticatorAttachment = "platform"

        struct Response: Encodable {
            let attestationObject: String
            let clientDataJSON: String
            let transports: [String]
        }
    }
}

// MARK: - base64url

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
