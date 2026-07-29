//
//  PasswordRecoveryView.swift
//  scripty
//
//  Getting back in when the password is gone.
//
//  Steps rather than one screen, because they are separated by a trip through
//  an email client: ask for the email, then come back through the link in it.
//  Presenting the password field first would show a writer a form they have no
//  way to submit yet.
//
//  Coming back is usually not a step at all — the link opens this app straight
//  at the password field. What is left on the waiting screen is the fallback
//  for a writer whose mail is somewhere this app isn't.
//

import SwiftUI

struct PasswordRecoveryView: View {
    @State private var model: PasswordRecoveryModel

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var pastedLink = ""
    @State private var password = ""

    /// Called once the password has actually changed — not on a cancel, and not
    /// on a failed attempt. A session opened with the old password uses this to
    /// end itself.
    private let onReset: (() -> Void)?

    /// From the "Forgot password?" button.
    init(client: APIClient, request: HALLink, onReset: (() -> Void)? = nil) {
        _model = State(initialValue: PasswordRecoveryModel(client: client, request: request))
        self.onReset = onReset
    }

    /// From the link in a recovery email, which carries the token.
    init(client: APIClient, reset: HALLink, token: String, onReset: (() -> Void)? = nil) {
        _model = State(initialValue:
            PasswordRecoveryModel(client: client, reset: reset, token: token))
        self.onReset = onReset
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.step {
                case .askForEmail: askForEmail
                case .waitForLink: waitForLink
                case .setPassword: setPassword
                case .finished: finished
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Reset Password")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.step == .finished ? "Done" : "Cancel") { dismiss() }
                }
            }
            // Arriving by link means the token has never been checked. Doing it
            // here says "that link has expired" while their hands are still
            // empty, rather than after they have thought of a password.
            .task {
                if model.step == .setPassword { await model.checkToken() }
            }
            .onChange(of: model.step) { _, step in
                if step == .finished { onReset?() }
            }
        }
    }

    @ViewBuilder
    private var askForEmail: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(send)
        } footer: {
            Text("We'll send a link to the address on your account.")
        }
        Section {
            Button(action: send) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Text("Send Reset Link")
                }
            }
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
        }
    }

    @ViewBuilder
    private var waitForLink: some View {
        Section {
            // The server's own wording, which says nothing about whether the
            // address is registered — and neither should this screen.
            Text(model.message ?? "If that address is registered, a reset link is on its way.")
                .font(.callout)
        } footer: {
            Text("Open the email and tap Reset Password. It opens right back here.")
        }
        Section {
            TextField("Paste the link from the email", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(usePastedLink)
            Button(action: usePastedLink) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Text("Continue")
                }
            }
            .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
        } header: {
            Text("Reading your email somewhere else?")
        } footer: {
            Text("Copy the link out of the email and paste it here instead.")
        }
    }

    @ViewBuilder
    private var setPassword: some View {
        Section {
            // Which account, once the server has confirmed the token: a writer
            // with two of them should see which one is about to change. It is a
            // field rather than a line of text, and inert — the address comes
            // from the token, not from typing — because the Passwords app reads
            // a username field to decide which saved entry the new password
            // below replaces. Without one it saves a second, nameless entry.
            if let account = model.tokenEmail {
                LabeledContent("Account") {
                    TextField("", text: .constant(account))
                        .textContentType(.username)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }
            }
            SecureField("New password", text: $password)
                .textContentType(.newPassword)
        } header: {
            Text("Set a new password")
        } footer: {
            if model.tokenRejected {
                Text("Ask for a new reset link and try again.")
            }
        }
        Section {
            Button(action: reset) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Text("Reset Password")
                }
            }
            .disabled(password.isEmpty || model.isWorking || model.tokenRejected)
        }
    }

    @ViewBuilder
    private var finished: some View {
        Section {
            Label(model.message ?? "Your password has been reset.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        Section {
            Button("Back to Sign In") { dismiss() }
        }
    }

    private func send() {
        Task { await model.sendEmail(to: email) }
    }

    private func usePastedLink() {
        Task { await model.accept(pasted: pastedLink) }
    }

    private func reset() {
        Task { await model.resetPassword(to: password) }
    }
}
