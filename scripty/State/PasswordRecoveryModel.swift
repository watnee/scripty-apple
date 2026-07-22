//
//  PasswordRecoveryModel.swift
//  scripty
//
//  Getting back in without a password.
//
//  The only flow in the app that runs with no credentials at all, which makes
//  it the only one that cannot start from the API root — every document there
//  is behind the sign-in. It starts instead from the link the server puts on
//  its 401 challenge, handed in by whoever presents this.
//

import Foundation
import Observation

@Observable
@MainActor
final class PasswordRecoveryModel {
    enum Step {
        /// Asking which account, before anything has been sent.
        case askForEmail
        /// A recovery email has gone out, and we are waiting for the token
        /// from it.
        case enterToken
        /// Done — the password is changed and sign-in is the next move.
        case finished
    }

    private(set) var step: Step = .askForEmail
    private(set) var isWorking = false
    /// What the server said, good or bad. Its wording names the actual rule
    /// — how long a token lasts, what a password must contain — so it is shown
    /// rather than replaced.
    private(set) var message: String?
    private(set) var errorMessage: String?
    /// Whose account the token belongs to, once the server has confirmed it.
    /// Worth showing: a writer with two accounts should see which one they are
    /// about to change.
    private(set) var tokenEmail: String?

    private let client: APIClient
    private let request: HALLink
    /// Where a new password goes, learned from the answer to the request. The
    /// server offers it only where there is something to reset.
    private var reset: HALLink?

    init(client: APIClient, request: HALLink) {
        self.client = client
        self.request = request
    }

    /// Asks for a recovery email.
    ///
    /// Always reports success, because the server always reports success:
    /// telling the writer that an address is not registered would tell anyone
    /// else the same thing.
    func sendEmail(to address: String) async {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        do {
            let answer: RecoveryAnswer = try await client.fetch(
                from: request, method: "POST", body: ForgotPasswordCommand(email: email))
            reset = answer.link(.resetPassword)
            message = answer.message
            step = .enterToken
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Checks a token before asking anyone to think of a new password — an
    /// expired link is worth saying so about while their hands are still empty.
    func check(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reset, !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let link = reset.addingQuery(["token": trimmed])
        do {
            let answer: RecoveryAnswer = try await client.fetch(from: link)
            tokenEmail = answer.valid == true ? answer.email : nil
            errorMessage = answer.valid == true ? nil : answer.message
        } catch {
            // A check that could not be made is not a token that is wrong;
            // leave it to the reset itself to say.
            tokenEmail = nil
        }
    }

    func resetPassword(token: String, to password: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reset, !trimmed.isEmpty, !password.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        do {
            let answer: RecoveryAnswer = try await client.fetch(
                from: reset, method: "POST",
                body: ResetPasswordCommand(token: trimmed, password: password))
            message = answer.message
            step = .finished
        } catch APIError.validation(let fields) {
            // One field, and its message names the rule that was broken.
            errorMessage = fields.values.first ?? "That could not be used."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ForgotPasswordCommand: Encodable {
    var email: String
}

struct ResetPasswordCommand: Encodable {
    var token: String
    var password: String
}

/// Every step of the flow answers with the same shape: something to say, and
/// sometimes a link onward.
struct RecoveryAnswer: Decodable, HALResource {
    var message: String?
    var valid: Bool?
    var email: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case message, valid, email
        case links = "_links"
    }
}
