//
//  TitlePageView.swift
//  scripty
//
//  The screenplay's front matter — title, writers, contact info, draft
//  version — with the live page preview the web editor shows beside its
//  form. Save is only offered when the server advertised an `update` link.
//

import SwiftUI

struct TitlePageView: View {
    @State private var model: TitlePageModel
    /// Handed the refreshed project after a successful save, so the caller
    /// can pick up the new title.
    private let onSaved: ((Project) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, project: Project, onSaved: ((Project) -> Void)? = nil) {
        _model = State(initialValue: TitlePageModel(app: app, project: project))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project Name", text: $model.projectName)
                        .textInputAutocapitalization(.words)
                        .disabled(!model.canEdit)
                } header: {
                    Text("Project")
                } footer: {
                    Text("What this screenplay is called in your projects list. "
                         + "It never appears on the printed page.")
                }

                Section {
                    TextField("Screenplay Title", text: $model.screenplayTitle)
                        .textInputAutocapitalization(.words)
                        .disabled(!model.canEdit)
                    TextField("Writers", text: $model.writers)
                        .textInputAutocapitalization(.words)
                        .disabled(!model.canEdit)
                } header: {
                    Text("Screenplay")
                } footer: {
                    Text("Leave the title blank to fall back to the project name.")
                }

                Section("Draft") {
                    HStack {
                        TextField("Version", text: $model.screenplayVersion)
                            .disabled(!model.canEdit)
                        if model.canEdit {
                            versionMenu
                        }
                    }
                }

                Section("Contact Information") {
                    TextField("Contact info…", text: $model.contactInfo, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(!model.canEdit)
                }

                Section("Preview") {
                    TitlePagePreview(model: model)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Title Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.canEdit ? "Cancel" : "Done") { dismiss() }
                }
                if model.canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { save() }
                                .disabled(!model.hasChanges || !model.canSave)
                        }
                    }
                }
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    /// The web form offers the standard draft colours from a `<datalist>`;
    /// a menu is the same affordance on a touch keyboard.
    private var versionMenu: some View {
        Menu {
            ForEach(TitlePageModel.versionSuggestions, id: \.self) { suggestion in
                Button(suggestion) { model.screenplayVersion = suggestion }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Choose a draft version")
    }

    private func save() {
        Task {
            let saved = await model.save()
            if saved {
                onSaved?(model.project)
                dismiss()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}

/// A title page as it would be typeset: the title centered on the upper
/// third, "written by" beneath it, and the contact block in the bottom-left
/// corner. Typography follows BlockRowView's screenplay conventions.
private struct TitlePagePreview: View {
    let model: TitlePageModel

    private static let bodyFont = Font.custom(ScriptFont.default.postScriptName,
                                              fixedSize: 14)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            VStack(spacing: 12) {
                Text(model.previewTitle)
                    .font(Self.bodyFont.weight(.bold))
                    .multilineTextAlignment(.center)

                if let writers = model.previewWriters {
                    Text("written by")
                        .font(Self.bodyFont)
                    Text(writers)
                        .font(Self.bodyFont)
                        .multilineTextAlignment(.center)
                }

                if let version = model.previewVersion {
                    Text(version)
                        .font(Self.bodyFont)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 36)

            Text(model.previewContact ?? " ")
                .font(Self.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(minHeight: 320)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Title page preview")
    }
}
