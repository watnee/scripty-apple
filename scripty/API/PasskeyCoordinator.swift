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
//  That same association is what puts this app and the Passwords app on the
//  same domain, so alongside the passkey ceremony this coordinator can open a
//  sheet of the saved passwords the Passwords app holds for it. Each kind has
//  its own request; the login screen offers them as separate buttons.
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

/// What a sign-in ceremony came back with. A passkey is verified against the
/// server's challenge; a password is the same pair the sign-in form asks for
/// and takes the ordinary sign-in path.
enum SavedCredential {
    case passkey(PasskeyCredentialPayload)
    case password(username: String, password: String)
}

@MainActor
final class PasskeyCoordinator: NSObject {

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    /// The controller holds no strong reference to its delegate; keeping
    /// ourselves alive for the duration of the ceremony is on us.
    private var retainedSelf: PasskeyCoordinator?
    /// Held only so a ceremony still waiting can be taken down — the
    /// AutoFill-assisted one, which has no sheet to dismiss and would
    /// otherwise sit there past the screen that started it.
    private var controller: ASAuthorizationController?

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

    /// Signs in with a passkey already saved on this device. No credential
    /// list is passed: this is the discoverable flow, where the system offers
    /// the accounts it holds passkeys for.
    func signIn(options: PasskeyCeremonyOptions) async throws -> SavedCredential {
        try credential(from: try await perform(try assertionRequest(from: options)))
    }

    /// Signs in with a password the Passwords app has saved for this domain.
    /// Nothing WebAuthn about it — no challenge, no options — the sheet hands
    /// back the same pair the sign-in form asks for.
    func signInWithSavedPassword() async throws -> SavedCredential {
        try credential(from: try await perform(ASAuthorizationPasswordProvider().createRequest()))
    }

    /// The same sign-in, offered without a button: the system folds this
    /// account's passkeys into the keyboard's QuickType bar over the sign-in
    /// fields, beside the saved passwords already there.
    ///
    /// No password request rides along this time — an AutoFill-assisted
    /// request takes passkeys only, and it doesn't need one: the passwords in
    /// that bar are put there by the fields' own `textContentType`.
    ///
    /// Waits until the writer picks something or `cancel()` is called. Mac
    /// Catalyst has no QuickType bar and no such request; there it is a cancel,
    /// and the button is the only way in.
    func signInWithAutoFill(options: PasskeyCeremonyOptions) async throws -> SavedCredential {
        #if targetEnvironment(macCatalyst)
        throw PasskeyCeremonyError.canceled
        #else
        let request = try assertionRequest(from: options)
        return try credential(from: try await perform([request], autoFillAssisted: true))
        #endif
    }

    /// Takes down a ceremony that is still waiting. The controller reports the
    /// cancel through the delegate, but the caller is resumed here rather than
    /// there: a coordinator let go of at the same moment shouldn't leave whoever
    /// awaited it hanging on a callback that may never arrive.
    func cancel() {
        controller?.cancel()
        controller = nil
        continuation?.resume(throwing: PasskeyCeremonyError.canceled)
        continuation = nil
    }

    private func assertionRequest(
        from options: PasskeyCeremonyOptions
    ) throws -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        guard let rpId = options.relyingPartyId,
              let challenge = options.challenge else {
            throw PasskeyCeremonyError.badOptions
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId)
        return provider.createCredentialAssertionRequest(challenge: challenge)
    }

    private func credential(from authorization: ASAuthorization) throws -> SavedCredential {
        switch authorization.credential {
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            return .passkey(.assertion(credentialId: assertion.credentialID,
                                       clientDataJSON: assertion.rawClientDataJSON,
                                       authenticatorData: assertion.rawAuthenticatorData,
                                       signature: assertion.signature,
                                       userHandle: assertion.userID))
        case let saved as ASPasswordCredential:
            return .password(username: saved.user, password: saved.password)
        default:
            throw PasskeyCeremonyError.failed("That saved sign-in could not be used.")
        }
    }

    private func perform(_ requests: [ASAuthorizationRequest],
                         autoFillAssisted: Bool = false) async throws -> ASAuthorization {
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        retainedSelf = self
        defer {
            retainedSelf = nil
            if self.controller === controller { self.controller = nil }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            #if targetEnvironment(macCatalyst)
            controller.performRequests()
            #else
            if autoFillAssisted {
                controller.performAutoFillAssistedRequests()
            } else {
                controller.performRequests()
            }
            #endif
        }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await perform([request])
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
        if let window { return window }
        // Nothing on screen to anchor to, which does not happen in practice.
        // Built from a scene where there is one: iOS 26 deprecates every way of
        // making a window without one, and a screenless window could not host
        // the sheet anyway — this only keeps the return non-optional.
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        return ASPresentationAnchor(frame: .zero)
    }
}
