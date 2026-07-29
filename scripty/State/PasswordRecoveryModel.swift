//
//  PasswordRecoveryModel.swift
//  scripty
//
//  Getting back in without a password.
//
//  The only flow in the app that runs with no credentials at all, which makes
//  it the only one that cannot start from the API root — every document there
//  is behind the sign-in. It starts instead from the links the server puts on
//  its 401 challenge, handed in by whoever presents this.
//
//  It can also start in the middle. The recovery email's link opens this app,
//  so the common path is the writer tapping it in Mail and arriving with the
//  token already in hand, having asked this screen for nothing. That is why
//  there are two ways in.
//

import Foundation
import Observation

@Observable
@MainActor
final class PasswordRecoveryModel {
    enum Step {
        /// Asking which account, before anything has been sent.
        case askForEmail
        /// A recovery email has gone out. The way on is the link in it, which
        /// re-enters this flow at `setPassword`.
        case waitForLink
        /// The token is in hand — from the link, or pasted out of it — and all
        /// that is left is the new password.
        case setPassword
        /// Done — the password is changed and sign-in is the next move.
        case finished
    }

    private(set) var step: Step
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
    /// Set when the server has said the token is no good — expired, or already
    /// spent. Distinct from simply not having checked: a check that could not
    /// be made leaves this false, because a lost connection is not a verdict.
    private(set) var tokenRejected = false

    private let client: APIClient
    /// Where a recovery email is asked for. Absent when the flow started from
    /// the link in one, since by then it has already been sent.
    private let request: HALLink?
    /// Where a new password goes. Learned from the answer to the request, or
    /// handed in up front when the link brought us here.
    private var reset: HALLink?
    /// The token from the email, once there is one.
    private(set) var token: String?

    /// From the "Forgot password?" button: start at the top.
    init(client: APIClient, request: HALLink) {
        self.client = client
        self.request = request
        self.step = .askForEmail
    }

    /// From the link in the email: the token is already in hand, so there is
    /// nothing to ask for and nothing to send.
    init(client: APIClient, reset: HALLink, token: String) {
        self.client = client
        self.request = nil
        self.reset = reset
        self.token = token
        self.step = .setPassword
    }

    /// Asks for a recovery email.
    ///
    /// Always reports success, because the server always reports success:
    /// telling the writer that an address is not registered would tell anyone
    /// else the same thing.
    func sendEmail(to address: String) async {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let request, !email.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        do {
            let answer: RecoveryAnswer = try await client.fetch(
                from: request, method: "POST", body: ForgotPasswordCommand(email: email))
            reset = answer.link(.resetPassword)
            message = answer.message
            step = .waitForLink
        } catch {
            // Nothing cancelled is ever shown — see `isCancelledRequest`.
            guard !error.isCancelledRequest else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Takes a token the writer supplied by hand, out of the link in the email.
    ///
    /// The fallback for a writer reading their mail somewhere this app isn't —
    /// a desktop, a phone without it installed. Anything that isn't a reset
    /// link is refused here rather than sent on as if it were a token.
    func accept(pasted text: String) async {
        guard !isWorking else { return }
        guard let token = PasswordResetLink.token(inPasted: text) else {
            errorMessage = "That doesn't look like the link from the email. "
                + "Copy the whole link and paste it here."
            return
        }
        errorMessage = nil
        self.token = token
        step = .setPassword
        await checkToken()
    }

    /// Checks the token before asking anyone to think of a new password — an
    /// expired link is worth saying so about while their hands are still empty.
    func checkToken() async {
        guard let reset, let token, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let link = reset.addingQuery(["token": token])
        do {
            let answer: RecoveryAnswer = try await client.fetch(from: link)
            let valid = answer.valid == true
            tokenEmail = valid ? answer.email : nil
            tokenRejected = !valid
            errorMessage = valid ? nil : answer.message
        } catch {
            // A check that could not be made is not a token that is wrong;
            // leave it to the reset itself to say.
            tokenEmail = nil
            tokenRejected = false
        }
    }

    func resetPassword(to password: String) async {
        guard let reset, let token, !password.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        do {
            let answer: RecoveryAnswer = try await client.fetch(
                from: reset, method: "POST",
                body: ResetPasswordCommand(token: token, password: password))
            message = answer.message
            step = .finished
        } catch APIError.validation(let fields) {
            // One field, and its message names the rule that was broken.
            errorMessage = fields.values.first ?? "That could not be used."
        } catch {
            // Nothing cancelled is ever shown — see `isCancelledRequest`.
            guard !error.isCancelledRequest else { return }
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
