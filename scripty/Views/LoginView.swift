//
//  LoginView.swift
//  scripty
//

import SwiftUI

struct LoginView: View {
    let app: AppModel

    @State private var username = ""
    @State private var password = ""
    /// Which button's work is in flight, so the spinner lands on the button
    /// that was tapped rather than always on Sign In.
    @State private var busy: Busy?
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

    private enum Busy {
        case password, passkey, savedPassword
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && busy == nil
    }

    var body: some View {
        // The scroll view only matters when the keyboard leaves too little
        // room — the minHeight frame keeps everything centered whenever the
        // content does fit, so a full-height screen looks exactly as before.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 16)

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
                            .keyboardType(.emailAddress)
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
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: 360, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button {
                        signIn()
                    } label: {
                        busyLabel(if: .password) {
                            Text("Sign In")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit)

                    if let passkeyLink {
                        VStack(spacing: 10) {
                            Button {
                                signInWithPasskey(using: passkeyLink)
                            } label: {
                                busyLabel(if: .passkey) {
                                    Label("Sign in with a Passkey",
                                          systemImage: "person.badge.key")
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(busy != nil)

                            Button {
                                signInWithSavedPassword(returnTo: passkeyLink)
                            } label: {
                                busyLabel(if: .savedPassword) {
                                    Label("Use a Saved Password",
                                          systemImage: "key.fill")
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(busy != nil)
                        }
                    }

                    if let recoveryLink {
                        Button("Forgot password?") {
                            focusedField = nil
                            self.presentedRecovery = recoveryLink
                        }
                        .font(.callout)
                        .disabled(busy != nil)
                    }

                    Spacer(minLength: 16)
                    Spacer(minLength: 0)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .animation(.snappy, value: app.signInError == nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        // A failure sticks around only until the writer starts fixing it.
        .onChange(of: username) { _, _ in app.signInError = nil }
        .onChange(of: password) { _, _ in app.signInError = nil }
        // The message sits below the fields, where VoiceOver focus isn't —
        // say it, or a failed attempt is silence.
        .onChange(of: app.signInError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
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

    /// The button's own label, replaced by a spinner while its work runs —
    /// laid over each other so the button doesn't change size mid-swap.
    private func busyLabel(if action: Busy,
                           @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            content()
                .opacity(busy == action ? 0 : 1)
            if busy == action {
                ProgressView()
            }
        }
        .frame(maxWidth: 360)
        .padding(.vertical, 6)
    }

    private func signIn() {
        focusedField = nil
        busy = .password
        Task {
            await app.signIn(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password)
            busy = nil
        }
    }

    /// Opens the system's passkey sheet. The keyboard's standing offer has to
    /// come down first — the platform runs one authorization request at a
    /// time — and goes back up if this attempt didn't end in a session.
    private func signInWithPasskey(using link: HALLink) {
        focusedField = nil
        busy = .passkey
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
            busy = nil
        }
    }

    /// Opens the system's saved-password sheet. Same standing-offer dance as
    /// the passkey sheet — one authorization request at a time — which is why
    /// this needs the link despite the ceremony itself never using it.
    private func signInWithSavedPassword(returnTo link: HALLink) {
        focusedField = nil
        busy = .savedPassword
        autoFill.cancel()
        Task {
            switch await PasskeySignInFlow(app: app).signInWithSavedPassword() {
            case .signedIn:
                break
            case .canceled:
                startAutoFill(using: link)
            case .failed(let message):
                app.signInError = message
                startAutoFill(using: link)
            }
            busy = nil
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
