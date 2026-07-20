//
//  CapitalizationSettingsView.swift
//  scripty
//
//  Which element types are typed in capitals — the web app's capitalization
//  preferences, as a sheet.
//
//  Worth spelling out in the footer that this reaches the exports, because it
//  is the part a writer cannot see from here: turning scene headings off looks
//  like a display choice until the PDF comes out lowercase too.
//

import SwiftUI

struct CapitalizationSettingsView: View {
    let model: CapitalizationModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(CapitalizationPreferences.coveredTypes) { type in
                        Toggle(label(for: type), isOn: binding(for: type))
                    }
                    .disabled(!model.canEdit)
                } header: {
                    Text("Type in Capitals")
                } footer: {
                    Text(model.canEdit
                         ? "Applies as you type and to exported scripts — PDF, "
                           + "Word and Final Draft all bake the case in."
                         : "These are set on your account and cannot be changed here.")
                }
            }
            .navigationTitle("Capitalization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .alert("Capitalization", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    /// "Character Cues" rather than "Characters", because the flag covers dual
    /// dialogue too and both are cues — naming one element type would promise
    /// something narrower than the switch delivers.
    private func label(for type: BlockType) -> String {
        type == .character ? "Character Cues" : type.label + "s"
    }

    private func binding(for type: BlockType) -> Binding<Bool> {
        Binding(
            get: { model.preferences.flag(for: type) },
            set: { value in Task { await model.setCapitalization(type, to: value) } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
