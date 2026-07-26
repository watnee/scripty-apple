//
//  PasskeyCoordinator.swift
//  scripty
//
//  The platform half of a WebAuthn ceremony: hands the server's challenge to
//  ASAuthorizationController and returns the authenticator's answer, already
//  in the wire shape the verify endpoint takes (PasskeyCeremony.swift).
//
//  Kept to this file on purpose — AuthenticationServices must not leak into
//  the models or AppModel, which Tests/run.sh compiles with plain swiftc.
//
//  The ceremony only succeeds when the relying party id the server sent is a
//  domain this app is associated with (webcredentials in the entitlements,
//  validated against /.well-known/apple-app-site-association on that domain).
//  Against any other server — a localhost override, the demo — the ceremony
//  fails with a platform error, which surfaces as an ordinary alert.
//

import AuthenticationServices
import UIKit

enum PasskeyCeremonyError: Error {
    /// The writer dismissed the system sheet; nothing to report.
    case canceled
    /// The options document was missing the pieces the platform needs.
    case badOptions
    case failed(String)
}

@MainActor
final class PasskeyCoordinator: NSObject {

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    /// The controller holds no strong reference to its delegate; keeping
    /// ourselves alive for the duration of the ceremony is on us.
    private var retainedSelf: PasskeyCoordinator?

    /// Registers a new passkey for the signed-in user described by the
    /// creation options.
    func register(options: PasskeyCeremonyOptions) async throws -> PasskeyCredentialPayload {
        guard let rpId = options.relyingPartyId,
              let challenge = options.challenge,
              let user = options.publicKey?.user,
              let userId = user.id.flatMap(Base64URL.decode),
              let name = user.name else {
            throw PasskeyCeremonyError.badOptions
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: name, userID: userId)
        let authorization = try await perform(request)
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else {
            throw PasskeyCeremonyError.failed("The passkey could not be created.")
        }
        return .attestation(credentialId: credential.credentialID,
                            clientDataJSON: credential.rawClientDataJSON,
                            attestationObject: attestation)
    }

    /// Signs in with an existing passkey. No credential list is passed: this
    /// is the discoverable flow, where the device offers the accounts it holds
    /// passkeys for.
    func signIn(options: PasskeyCeremonyOptions) async throws -> PasskeyCredentialPayload {
        guard let rpId = options.relyingPartyId,
              let challenge = options.challenge else {
            throw PasskeyCeremonyError.badOptions
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        let authorization = try await perform(request)
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyCeremonyError.failed("The passkey could not be used.")
        }
        return .assertion(credentialId: credential.credentialID,
                          clientDataJSON: credential.rawClientDataJSON,
                          authenticatorData: credential.rawAuthenticatorData,
                          signature: credential.signature,
                          userHandle: credential.userID)
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        retainedSelf = self
        defer { retainedSelf = nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
}

extension PasskeyCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let mapped: Error
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            mapped = PasskeyCeremonyError.canceled
        } else {
            mapped = PasskeyCeremonyError.failed(error.localizedDescription)
        }
        continuation?.resume(throwing: mapped)
        continuation = nil
    }
}

extension PasskeyCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The frontmost window; the ceremony is always started from one.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }
}
