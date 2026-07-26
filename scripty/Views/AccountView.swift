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
//  Adding a passkey runs the platform WebAuthn ceremony (Face ID / Touch ID)
//  against the API's ceremony endpoints — offered only when the collection
//  advertised `registerPasskey`, which the demo backend deliberately never
//  does: the ceremony can only succeed against a domain this app is
//  associated with.
//

import SwiftUI

struct AccountView: View {
    @State private var model: AccountModel

    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var pendingDelete: Passkey?
    @State private var isNamingPasskey = false
    @State private var passkeyLabel = ""
    @State private var isAddingPasskey = false

    private let app: AppModel

    init(app: AppModel, source: HALLink) {
        self.app = app
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
            .alert("Name This Passkey", isPresented: $isNamingPasskey) {
                TextField("Label", text: $passkeyLabel)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addPasskey() }
            } message: {
                Text("A label tells your passkeys apart — this device's name is usually right.")
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
            if model.canAddPasskey {
                if isAddingPasskey {
                    ProgressView()
                } else {
                    Button {
                        passkeyLabel = UIDevice.current.name
                        isNamingPasskey = true
                    } label: {
                        Label("Add Passkey", systemImage: "person.badge.key")
                    }
                    .disabled(model.isWorking)
                }
            }
        } header: {
            Text("Passkeys")
        } footer: {
            if model.canAddPasskey {
                Text("A passkey signs you in with Face ID or Touch ID — no password typed, nothing to phish. Swipe to revoke one.")
            } else {
                // The demo, or a server without the ceremony endpoints.
                Text("Passkeys are added in the web app. You can revoke them here.")
            }
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

    private func addPasskey() {
        guard let link = model.registerPasskeyLink else { return }
        let label = passkeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        isAddingPasskey = true
        Task {
            let flow = PasskeyRegistrationFlow(account: model, client: app.client)
            switch await flow.register(using: link, label: label) {
            case .registered, .canceled:
                break
            case .failed(let message):
                model.errorMessage = message
            }
            isAddingPasskey = false
        }
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
