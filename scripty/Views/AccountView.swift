//
//  AccountView.swift
//  scripty
//
//  The signed-in user's own account: change the password, and see or revoke the
//  passkeys registered to it.
//
//  Reached from the projects sidebar whenever the API root advertised `account`
//  — which it does for anyone signed in, unlike the admin-only Users screen. The
//  passkey section appears only when the account resource carried a `passkeys`
//  link, so a deployment without passkeys shows the password form alone.
//
//  Adding a passkey is not offered: registration is a WebAuthn ceremony run
//  between the browser and the server's filters, so the API exposes listing and
//  revoking only, and the screen says as much rather than showing a dead button.
//

import SwiftUI

struct AccountView: View {
    @State private var model: AccountModel

    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var pendingDelete: Passkey?

    init(app: AppModel, source: HALLink) {
        _model = State(initialValue: AccountModel(app: app, source: source))
    }

    /// The server enforces its own policy; this is only enough to keep an
    /// obviously incomplete form from being sent.
    private var canSave: Bool {
        !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !model.isWorking
    }

    private var mismatch: Bool {
        !confirmPassword.isEmpty && newPassword != confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                if model.canChangePassword {
                    passwordSection
                }
                if model.showsPasskeys {
                    passkeySection
                }
            }
            .navigationTitle("Account")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Revoke Passkey", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Revoke", role: .destructive) {
                    let passkey = pendingDelete
                    pendingDelete = nil
                    Task {
                        guard let passkey else { return }
                        await model.deletePasskey(passkey)
                    }
                }
            } message: {
                Text("“\(pendingDelete?.displayLabel ?? "")” will no longer sign you in.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section {
            if model.isLoading && model.account == nil {
                ProgressView()
            } else if let account = model.account {
                LabeledContent("Name", value: account.displayName)
                if let username = account.username {
                    LabeledContent("Username", value: username)
                }
                if account.passwordChangeRequired == true {
                    Label("The server is asking you to change your password.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        Section {
            SecureField("Current password", text: $currentPassword)
            SecureField("New password", text: $newPassword)
            SecureField("Confirm new password", text: $confirmPassword)
            if mismatch {
                Text("The new passwords don't match.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.isWorking {
                ProgressView()
            } else {
                Button("Change Password") { changePassword() }
                    .disabled(!canSave)
            }
        } header: {
            Text("Password")
        } footer: {
            if model.didChangePassword {
                Text("Your password has been changed.")
                    .foregroundStyle(.green)
            } else {
                Text("At least 8 characters. Your current password is required.")
            }
        }
    }

    @ViewBuilder
    private var passkeySection: some View {
        Section {
            if model.passkeys.isEmpty {
                Text("No passkeys are registered to this account.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.passkeys) { passkey in
                VStack(alignment: .leading, spacing: 2) {
                    Text(passkey.displayLabel)
                    Text(subtitle(for: passkey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    if passkey.canDelete {
                        Button(role: .destructive) {
                            pendingDelete = passkey
                        } label: {
                            Label("Revoke", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Passkeys")
        } footer: {
            // Registration is a browser ceremony, so saying where to do it beats
            // offering a button that cannot work here.
            Text("Passkeys are added in the web app. You can revoke them here.")
        }
    }

    private func subtitle(for passkey: Passkey) -> String {
        var parts: [String] = []
        if let created = passkey.created {
            parts.append("Added \(created.formatted(date: .abbreviated, time: .omitted))")
        }
        if let lastUsed = passkey.lastUsed {
            parts.append("last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
        } else {
            parts.append("never used")
        }
        return parts.joined(separator: " · ")
    }

    private func changePassword() {
        guard canSave else { return }
        Task {
            let ok = await model.changePassword(current: currentPassword, new: newPassword)
            if ok {
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
