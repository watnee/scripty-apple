//
//  CapitalizationSettingsView.swift
//  scripty
//
//  Editor preferences: whether a document comes up to be read or to be typed
//  in, the face the app writes in, and which elements are typed in ALL CAPS.
//  The web app puts the capitals on a menu; on iOS they read better as a
//  settings sheet of toggles, and the typeface — which the web has no setting
//  for at all — belongs with them, as does the opening question, which is a
//  standing answer rather than something you do to the script in front of you.
//
//  The sections are stored in different places on purpose. Capitalization is
//  the server's, because exports bake the case into the file; the default font
//  and the opening view are this device's, like the type size and the
//  appearance, because they change how a script is drawn and nothing about
//  what is stored on it. So the caps section appears only once the preference
//  has somewhere to save to, and the other two always do.
//
//  Each control persists on the spot — the toggles post only the field that
//  changed, the pickers and the switch write straight to UserDefaults.
//

import SwiftUI

struct CapitalizationSettingsView: View {
    let app: AppModel

    @Environment(\.dismiss) private var dismiss

    private var settings: CapitalizationSettings { CapitalizationSettings.shared }
    private var presentation: PresentationSettings { PresentationSettings.shared }
    private var readingViews: ReadingViewSettings { ReadingViewSettings.shared }

    var body: some View {
        NavigationStack {
            Form {
                // First, because it is the question a document answers before
                // any of the typography below it applies.
                Section {
                    Toggle("Open in Edit View", isOn: editViewBinding)
                } header: {
                    Text("Opening Documents")
                } footer: {
                    Text("Documents open to be read, so a screenplay you are "
                         + "scrolling through cannot be typed into by accident. "
                         + "Turn this on to have them open ready to write in "
                         + "instead. It answers for documents you have never "
                         + "made a choice about: one you have tapped Edit in "
                         + "already opens for writing, and one you have put "
                         + "back up to be read stays that way.")
                }

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

    private var editViewBinding: Binding<Bool> {
        Binding(
            get: { readingViews.opensInEditView },
            set: { readingViews.opensInEditView = $0 })
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
