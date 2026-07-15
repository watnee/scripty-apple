//
//  ChangePasswordSheet.swift
//  scripty
//
//  Self-service password change, mirroring the web account page. Posts to
//  `PUT /api/account/password` via AppModel; the server enforces the strength
//  policy and current-password check, and this sheet surfaces those messages.
//

import SwiftUI

struct ChangePasswordSheet: View {
    let app: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case current, new, confirm }

    /// Match the server's minimum so the obvious cases fail fast without a round trip.
    private static let minLength = 8

    private var localValidationError: String? {
        if newPassword.count < Self.minLength {
            return "New password must be at least \(Self.minLength) characters."
        }
        if newPassword != confirm {
            return "New password and confirmation do not match."
        }
        if newPassword == current {
            return "New password must be different from the current password."
        }
        return nil
    }

    private var canSubmit: Bool {
        !current.isEmpty && !newPassword.isEmpty && !confirm.isEmpty
            && localValidationError == nil && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current)
                        .textContentType(.password)
                        .focused($focused, equals: .current)
                        .submitLabel(.next)
                        .onSubmit { focused = .new }
                }
                Section {
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                        .focused($focused, equals: .new)
                        .submitLabel(.next)
                        .onSubmit { focused = .confirm }
                    SecureField("Confirm new password", text: $confirm)
                        .textContentType(.newPassword)
                        .focused($focused, equals: .confirm)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { save() } }
                } footer: {
                    Text("Use at least \(Self.minLength) characters. Avoid common passwords or your username.")
                }

                if let message = errorMessage ?? localValidationErrorIfDirty {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { focused = .current }
        }
        .presentationDetents([.medium])
    }

    /// Only nudge with the local rule once the user has started confirming, so
    /// the mismatch/length hints don't shout while the fields are still empty.
    private var localValidationErrorIfDirty: String? {
        guard !newPassword.isEmpty, !confirm.isEmpty else { return nil }
        return localValidationError
    }

    private func save() {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await app.changePassword(current: current, new: newPassword)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
