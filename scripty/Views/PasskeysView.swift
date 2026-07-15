//
//  PasskeysView.swift
//  scripty
//
//  Manage the signed-in account's passkeys: list, add, and remove. Registration
//  and deletion go through Spring Security's WebAuthn filters; listing uses the
//  app's own /api/passkeys endpoint.
//

import SwiftUI
import UIKit

/// A single registered passkey, as returned by GET /api/passkeys. Dates are
/// intentionally omitted here to keep decoding robust across server date formats.
struct Passkey: Identifiable, Decodable, Equatable {
    let id: String
    let label: String
}

struct PasskeysView: View {
    let app: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var passkeys: [Passkey] = []
    @State private var isLoading = true
    @State private var isRegistering = false
    @State private var errorMessage: String?
    @State private var promptingLabel = false
    @State private var newLabel = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(passkeys) { passkey in
                        Label(passkey.label.isEmpty ? "Passkey" : passkey.label,
                              systemImage: "key.horizontal")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await delete(passkey) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("Passkeys let you sign in with Face ID or Touch ID instead of a password.")
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if passkeys.isEmpty {
                    ContentUnavailableView(
                        "No Passkeys",
                        systemImage: "person.badge.key",
                        description: Text("Add a passkey to sign in without a password."))
                }
            }
            .navigationTitle("Passkeys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isRegistering {
                        ProgressView()
                    } else {
                        Button {
                            newLabel = UIDevice.current.name
                            promptingLabel = true
                        } label: {
                            Label("Add a Passkey", systemImage: "plus")
                        }
                    }
                }
            }
            .alert("Name this passkey", isPresented: $promptingLabel) {
                TextField("Label", text: $newLabel)
                Button("Cancel", role: .cancel) {}
                Button("Add") { register() }
            } message: {
                Text("Choose a name so you can recognize this device later.")
            }
            .alert("Passkey Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func load() async {
        isLoading = true
        do {
            passkeys = try await app.client.fetch([Passkey].self, from: app.passkeysLink)
        } catch {
            // A backend without the /api/passkeys endpoint simply shows an empty list.
            passkeys = []
        }
        isLoading = false
    }

    private func register() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        isRegistering = true
        Task {
            do {
                try await app.registerPasskey(label: label)
                await load()
            } catch PasskeyService.PasskeyError.cancelled {
                // User dismissed the system sheet.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isRegistering = false
        }
    }

    private func delete(_ passkey: Passkey) async {
        do {
            try await app.deletePasskey(passkey)
            passkeys.removeAll { $0 == passkey }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
