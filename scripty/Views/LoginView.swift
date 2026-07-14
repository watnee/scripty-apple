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
}
