//
//  CapitalizationSettingsView.swift
//  scripty
//
//  Editor preferences: the face the app writes in, and which elements are
//  typed in ALL CAPS. The web app puts the capitals on a menu; on iOS they
//  read better as a settings sheet of toggles, and the typeface — which the
//  web has no setting for at all — belongs with them.
//
//  The two halves are stored in different places on purpose. Capitalization is
//  the server's, because exports bake the case into the file; the default font
//  is this device's, like the type size and the appearance, because it changes
//  how a script is drawn and nothing about what is stored on it. So the caps
//  section appears only once the preference has somewhere to save to, and the
//  font section always does.
//
//  Each control persists on the spot — the toggles post only the field that
//  changed, the picker writes straight to UserDefaults.
//

import SwiftUI

struct CapitalizationSettingsView: View {
    let app: AppModel

    @Environment(\.dismiss) private var dismiss

    private var settings: CapitalizationSettings { CapitalizationSettings.shared }
    private var presentation: PresentationSettings { PresentationSettings.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default Font", selection: fontBinding) {
                        ForEach(ScriptFont.allCases) { option in
                            // Each name set in the face it names: a font list
                            // that does not show the fonts asks the writer to
                            // remember what Courier looks like.
                            Text(option.label)
                                .font(.custom(option.postScriptName, size: 17))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    // An inline picker draws its own label as a row above the
                    // options, which under a section of the same name is the
                    // words "Default Font" twice. The section header keeps it;
                    // the picker keeps it for VoiceOver.
                    .labelsHidden()
                } header: {
                    Text("Default Font")
                } footer: {
                    Text("The typeface everything is written in, unless an element is "
                         + "given a font of its own from the Format bar. Songs, notes "
                         + "and a script printed from this device follow it too. It is "
                         + "a choice about this device, not about the screenplay.")
                }

                // Only where it can be saved: the preference lives on the
                // account, and the link to store it arrives with the account.
                // A demo session, or a server that does not offer it, gets the
                // font section alone rather than toggles that post to nowhere.
                if settings.updateLink != nil {
                    Section {
                        ForEach(CapitalizedElement.allCases, id: \.self) { element in
                            Toggle(element.label, isOn: binding(for: element))
                        }
                    } header: {
                        Text("Automatic Capitalization")
                    } footer: {
                        Text("Type these elements in capitals. Exports carry the same case, so a change here also changes the PDF, Word and Final Draft files you export.")
                    }
                }
            }
            .navigationTitle("Editor Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var fontBinding: Binding<ScriptFont> {
        Binding(
            get: { presentation.defaultFont },
            set: { presentation.defaultFont = $0 })
    }

    private func binding(for element: CapitalizedElement) -> Binding<Bool> {
        Binding(
            get: { settings.isOn(element) },
            set: { newValue in
                Task { await settings.set(element, on: newValue, using: app.client) }
            })
    }
}
