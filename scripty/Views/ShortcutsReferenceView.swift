//
//  ShortcutsReferenceView.swift
//  scripty
//
//  The web app's Shortcuts page, as a sheet. Built from `ScriptShortcutAction`
//  rather than from a hand-written list, so it can only ever show keys that are
//  actually bound.
//
//  Bindings that need something the server didn't advertise — export when there
//  is no export link, version history on a project without versions — are shown
//  dimmed rather than hidden. A writer looking for "why didn't ⌘⇧1 work" is
//  better served by seeing the shortcut greyed out than by finding no trace of
//  it at all.
//

import SwiftUI

struct ShortcutsReferenceView: View {
    /// Whether the script page would act on this shortcut right now.
    let isEnabled: (ScriptShortcutAction) -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ScriptShortcutAction.Group.allCases) { group in
                    Section {
                        ForEach(ScriptShortcutAction.inGroup(group)) { action in
                            row(action)
                        }
                    } header: {
                        Label(group.title, systemImage: group.systemImage)
                    } footer: {
                        if let footnote = group.footnote {
                            Text(footnote)
                        }
                    }
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ action: ScriptShortcutAction) -> some View {
        let available = isEnabled(action)
        return LabeledContent {
            Text(action.displayKeys)
                .font(.body.monospaced())
                .foregroundStyle(available ? .secondary : .tertiary)
        } label: {
            Text(action.title)
                .foregroundStyle(available ? .primary : .secondary)
        }
        .accessibilityLabel(
            "\(action.title). \(action.displayKeys)"
            + (available ? "" : ". Not available in this script."))
    }
}
