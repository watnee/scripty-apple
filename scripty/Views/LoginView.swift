//
//  LoginView.swift
//  scripty
//

import SwiftUI

struct LoginView: View {
    let app: AppModel

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    /// Where password recovery lives, if this server offers it. Learned from
    /// the 401 challenge — it is the only document a caller with no credentials
    /// can read, so it is the only place the link could come from.
    @State private var recoveryLink: HALLink?
    @State private var presentedRecovery: HALLink?
    /// Where passkey sign-in begins, if this server offers it — learned from
    /// the same challenge, for the same reason.
    @State private var passkeyLink: HALLink?
    /// The standing offer in the keyboard, live for as long as this screen is.
    @State private var autoFill = PasskeyAutoFill()
    @FocusState private var focusedField: Field?

    private enum Field {
        case username, password
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSigningIn
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("Scripty")
                    .font(.largeTitle.bold())
                Text("Collaborative Screenwriting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSubmit { signIn() } }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            if let error = app.signInError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                signIn()
            } label: {
                Group {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Text("Sign In")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: 360)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)

            if let passkeyLink {
                Button {
                    signInWithSavedCredential(using: passkeyLink)
                } label: {
                    // The sheet lists this domain's passkeys and the passwords
                    // the Passwords app has saved for it, so the button can't
                    // promise only one of them.
                    Label("Use a Saved Passkey or Password",
                          systemImage: "person.badge.key")
                        .frame(maxWidth: 360)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(isSigningIn)
            }

            if let recoveryLink {
                Button("Forgot password?") {
                    focusedField = nil
                    self.presentedRecovery = recoveryLink
                }
                .font(.callout)
                .disabled(isSigningIn)
            }

            VStack(spacing: 6) {
                Button {
                    enterDemo()
                } label: {
                    Label("Try the Demo", systemImage: "sparkles")
                        .frame(maxWidth: 360)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(isSigningIn)

                Text("Explore a sample screenplay — no account needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Spacer()
        }
        .padding()
        // Asked for once, on the way in. A server that offers nothing simply
        // leaves the buttons out.
        .task {
            let links = await app.client.signedOutLinks()
            recoveryLink = links[.forgotPassword]
            passkeyLink = links[.passkeyLogin]
            // A passkey needs a challenge before the system can offer it, so
            // asking for one is the price of the offer appearing in the
            // keyboard at all — one POST, on a screen that has just made one.
            if let passkeyLink { startAutoFill(using: passkeyLink) }
        }
        .onDisappear { autoFill.cancel() }
        // Only the "Forgot password?" route is presented here. A token arriving
        // from the link in an email is RootView's, because that one can land in
        // any phase — including one where this screen doesn't exist.
        .sheet(item: $presentedRecovery) { link in
            PasswordRecoveryView(client: app.client, request: link)
        }
    }

    private func enterDemo() {
        focusedField = nil
        isSigningIn = true
        Task {
            await app.enterDemo()
            isSigningIn = false
        }
    }

    private func signIn() {
        focusedField = nil
        isSigningIn = true
        Task {
            await app.signIn(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password)
            isSigningIn = false
        }
    }

    /// Opens the system sheet. The keyboard's standing offer has to come down
    /// first — the platform runs one authorization request at a time — and goes
    /// back up if this attempt didn't end in a session.
    private func signInWithSavedCredential(using link: HALLink) {
        focusedField = nil
        isSigningIn = true
        autoFill.cancel()
        Task {
            switch await PasskeySignInFlow(app: app).signIn(using: link) {
            case .signedIn:
                break
            case .canceled:
                startAutoFill(using: link)
            case .failed(let message):
                app.signInError = message
                startAutoFill(using: link)
            }
            isSigningIn = false
        }
    }

    private func startAutoFill(using link: HALLink) {
        autoFill.start(app: app, using: link) { outcome in
            // Only the server refusing a credential the writer actually picked
            // reaches here as a failure; everything quieter is already a cancel.
            // Say so, then offer again with a fresh challenge — the likeliest
            // refusal is the one this screen sets itself up for, a challenge
            // minted on arrival and picked against much later.
            if case .failed(let message) = outcome {
                app.signInError = message
                startAutoFill(using: link)
            }
        }
    }
}
