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

/// Signing in with a passkey, from the login screen. Starts from the
/// `passkeyLogin` link the 401 challenge advertised; a verified assertion
/// answers a bearer token, which AppModel adopts as the session.
@MainActor
struct PasskeySignInFlow {
    let app: AppModel

    enum Outcome {
        case signedIn
        /// The writer dismissed the system sheet; not worth an error message.
        case canceled
        case failed(String)
    }

    func signIn(using optionsLink: HALLink) async -> Outcome {
        let client = app.client
        do {
            let options: PasskeyCeremonyOptions = try await client.fetch(
                from: optionsLink, method: "POST")
            guard let challengeId = options.challengeId,
                  let verify = options.verifyLink else {
                return .failed("This server's passkey sign-in is incomplete.")
            }
            let credential = try await PasskeyCoordinator().signIn(options: options)
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
        } catch PasskeyCeremonyError.canceled {
            return .canceled
        } catch PasskeyCeremonyError.badOptions {
            return .failed("This server's passkey sign-in is incomplete.")
        } catch PasskeyCeremonyError.failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
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
