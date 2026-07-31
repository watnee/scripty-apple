//
//  PasskeyFlows.swift
//  scripty
//
//  The two WebAuthn ceremonies end to end: options from the API, the platform
//  ceremony through PasskeyCoordinator, the authenticator's answer back to the
//  API's verify link. Views call these; the run.sh-compiled models and
//  AppModel stay free of AuthenticationServices.
//

import Foundation
import UIKit

/// Signing in with something the device already holds, from the login screen.
/// Starts from the `passkeyLogin` link the 401 challenge advertised; a verified
/// assertion answers a bearer token, which AppModel adopts as the session.
///
/// The Passwords app's saved passwords for this domain get their own sheet,
/// through `signInWithSavedPassword` — that one skips WebAuthn entirely, never
/// touching the server for options, and signs in the ordinary way.
@MainActor
struct PasskeySignInFlow {
    let app: AppModel

    enum Outcome {
        case signedIn
        /// The writer dismissed the system sheet, or the platform had nothing
        /// to offer; not worth an error message.
        case canceled
        case failed(String)
    }

    /// From the passkey button: a sheet listing this domain's passkeys.
    func signIn(using optionsLink: HALLink) async -> Outcome {
        await run(using: optionsLink, coordinator: PasskeyCoordinator()) { coordinator, options in
            try await coordinator.signIn(options: options)
        }
    }

    /// From the saved-password button: a sheet listing the passwords the
    /// Passwords app holds for this domain. No options link — there is no
    /// challenge to mint — the picked pair takes the same path typing it would.
    func signInWithSavedPassword() async -> Outcome {
        do {
            guard case .password(let username, let password) =
                    try await PasskeyCoordinator().signInWithSavedPassword() else {
                return .failed("That saved sign-in could not be used.")
            }
            await app.signIn(username: username, password: password)
            if let error = app.signInError { return .failed(error) }
            return .signedIn
        } catch PasskeyCeremonyError.canceled {
            return .canceled
        } catch PasskeyCeremonyError.failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// From the keyboard, with no button pressed: the passkeys appear in the
    /// QuickType bar over the sign-in fields. The coordinator comes from the
    /// caller because only the caller knows when the screen is going away, and
    /// this request runs until it is canceled.
    ///
    /// Platform failures are swallowed here. Nobody asked for this offer, and a
    /// device with nothing saved — or a build pointed at a server this app is
    /// not associated with — must not answer that with a red error above a form
    /// that works perfectly well.
    func autoFill(using optionsLink: HALLink, coordinator: PasskeyCoordinator) async -> Outcome {
        await run(using: optionsLink, coordinator: coordinator, silently: true) { coordinator, options in
            try await coordinator.signInWithAutoFill(options: options)
        }
    }

    private func run(
        using optionsLink: HALLink,
        coordinator: PasskeyCoordinator,
        silently: Bool = false,
        ceremony: (PasskeyCoordinator, PasskeyCeremonyOptions) async throws -> SavedCredential
    ) async -> Outcome {
        // The session on screen may be the local one, which answers in-process
        // and knows nothing about this writer's account — see `signInClient`.
        let client = app.signInClient
        do {
            let options: PasskeyCeremonyOptions = try await client.fetch(
                from: optionsLink, method: "POST")
            guard let challengeId = options.challengeId,
                  let verify = options.verifyLink else {
                return silently ? .canceled : .failed("This server's passkey sign-in is incomplete.")
            }
            switch try await ceremony(coordinator, options) {
            case .password(let username, let password):
                // Nothing WebAuthn about this one: the Passwords app handed
                // back the two strings the form asks for, so it takes the same
                // path typing them would. The challenge just minted goes
                // unspent and expires on its own.
                await app.signIn(username: username, password: password)
                if let error = app.signInError { return .failed(error) }
                return .signedIn
            case .passkey(let credential):
                // Past here the writer has picked something and is waiting on
                // an answer, so failures are theirs to see even in the silent
                // path — hence the separate catch.
                do {
                    let session: PasskeySession = try await client.fetch(
                        from: verify, method: "POST",
                        body: PasskeyLoginCommand(challengeId: challengeId,
                                                  label: UIDevice.current.name,
                                                  credential: credential))
                    guard let username = session.username, let token = session.token else {
                        return .failed("The server did not complete the sign-in.")
                    }
                    let adopted = await app.adoptPasskeySession(
                        username: username, token: token, revokeHref: session.revokeLink?.href)
                    return adopted ? .signedIn : .failed(app.signInError ?? "Sign-in failed.")
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        } catch PasskeyCeremonyError.canceled {
            return .canceled
        } catch PasskeyCeremonyError.badOptions {
            return silently ? .canceled : .failed("This server's passkey sign-in is incomplete.")
        } catch PasskeyCeremonyError.failed(let message) {
            return silently ? .canceled : .failed(message)
        } catch {
            return silently ? .canceled : .failed(error.localizedDescription)
        }
    }
}

/// Keeps one AutoFill-assisted sign-in alive for as long as a sign-in screen
/// is on screen. The view holds this; this holds the coordinator, which is the
/// only thing that can take the request down again.
///
/// One at a time: the request is started on appearance and canceled before any
/// sheet is opened, because the platform will not run both at once.
@MainActor
final class PasskeyAutoFill {
    private var coordinator: PasskeyCoordinator?

    /// Starts the offer unless one is already running. `onOutcome` is called
    /// with whatever ends it — which, given `autoFill` reports platform
    /// failures as cancels, means a `.failed` here is always the server turning
    /// down a credential the writer chose.
    func start(app: AppModel,
               using optionsLink: HALLink,
               onOutcome: @escaping (PasskeySignInFlow.Outcome) -> Void) {
        guard coordinator == nil else { return }
        let coordinator = PasskeyCoordinator()
        self.coordinator = coordinator
        Task {
            let outcome = await PasskeySignInFlow(app: app)
                .autoFill(using: optionsLink, coordinator: coordinator)
            if self.coordinator === coordinator { self.coordinator = nil }
            onOutcome(outcome)
        }
    }

    func cancel() {
        coordinator?.cancel()
        coordinator = nil
    }
}

/// Registering a new passkey, from the account screen. Starts from the
/// `registerPasskey` link on the passkeys collection; a verified attestation
/// answers the refreshed collection, which AccountModel adopts.
@MainActor
struct PasskeyRegistrationFlow {
    let account: AccountModel
    let client: APIClient

    enum Outcome {
        case registered
        case canceled
        case failed(String)
    }

    func register(using optionsLink: HALLink, label: String) async -> Outcome {
        do {
            let options: PasskeyCeremonyOptions = try await client.fetch(
                from: optionsLink, method: "POST")
            guard let challengeId = options.challengeId,
                  let verify = options.verifyLink else {
                return .failed("This server's passkey registration is incomplete.")
            }
            let credential = try await PasskeyCoordinator().register(options: options)
            let registered = await account.completePasskeyRegistration(
                verify: verify,
                command: RegisterPasskeyCommand(challengeId: challengeId,
                                                label: label,
                                                credential: credential))
            return registered ? .registered
                : .failed(account.errorMessage ?? "The passkey could not be registered.")
        } catch PasskeyCeremonyError.canceled {
            return .canceled
        } catch PasskeyCeremonyError.badOptions {
            return .failed("This server's passkey registration is incomplete.")
        } catch PasskeyCeremonyError.failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
