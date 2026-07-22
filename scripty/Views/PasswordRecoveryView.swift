//
//  PasswordRecoveryView.swift
//  scripty
//
//  Getting back in when the password is gone.
//
//  Two steps rather than one screen, because they are separated by a trip
//  through an email client: ask for the email, then come back with the token
//  from it. Presenting both at once would show a writer a token field before
//  they have anything to put in it.
//

import SwiftUI

struct PasswordRecoveryView: View {
    @State private var model: PasswordRecoveryModel

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var token = ""
    @State private var password = ""

    init(client: APIClient, request: HALLink) {
        _model = State(initialValue: PasswordRecoveryModel(client: client, request: request))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.step {
                case .askForEmail: askForEmail
                case .enterToken: enterToken
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
    private var enterToken: some View {
        Section {
            // The server's own wording, which says nothing about whether the
            // address is registered — and neither should this screen.
            Text(model.message ?? "Check your email for a reset link.")
                .font(.callout)
        }
        Section {
            TextField("Code from the email", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await model.check(token) } }
            SecureField("New password", text: $password)
                .textContentType(.newPassword)
        } header: {
            Text("Set a new password")
        } footer: {
            // Which account, once the server has confirmed the token: a writer
            // with two of them should see which one is about to change.
            if let account = model.tokenEmail {
                Text("This will change the password for \(account).")
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
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty
                      || password.isEmpty || model.isWorking)
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

    private func reset() {
        Task { await model.resetPassword(token: token, to: password) }
    }
}
