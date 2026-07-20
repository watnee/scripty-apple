//
//  ScriptImportButton.swift
//  scripty
//
//  Imports a screenplay file into the open project. The server replaces
//  every block with the parsed result, so — like the web app's import
//  button — this asks before uploading anything.
//

import SwiftUI
import UniformTypeIdentifiers

struct ScriptImportButton: View {
    @State private var model: ScriptImportModel
    /// Run after a successful import. The caller MUST reload the script here:
    /// every block in the project has just been replaced.
    private let onImported: (Project) async -> Void

    /// Raised from outside — by ⌘⇧I — to open the file picker without pressing
    /// the button. The button owns the picker, the confirmation and the upload,
    /// so the keyboard reaches in rather than duplicating any of that.
    ///
    /// Folded into the picker's presentation binding rather than watched with
    /// an `.onChange`: this view is hosted inside a `ToolbarItemGroup`, and an
    /// `.onChange` attached to toolbar content is not reliably evaluated —
    /// ⌘⇧I did nothing at all while the trigger was observed that way. A
    /// binding is read wherever the value is needed, so it has no such gap.
    @Binding private var trigger: Bool

    @State private var showingImporter = false
    @State private var pending: PendingScriptFile?
    @State private var statusMessage: String?

    init(app: AppModel, project: Project,
         trigger: Binding<Bool> = .constant(false),
         onImported: @escaping (Project) async -> Void) {
        _model = State(initialValue: ScriptImportModel(app: app, project: project))
        _trigger = trigger
        self.onImported = onImported
    }

    var body: some View {
        Group {
            if model.canImport {
                Button {
                    showingImporter = true
                } label: {
                    if model.isImporting {
                        ProgressView()
                    } else {
                        Label("Import Script", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                .disabled(model.isImporting)
            }
        }
        .fileImporter(isPresented: pickerBinding,
                      allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
        .confirmationDialog("Replace this screenplay?",
                            isPresented: confirmBinding,
                            titleVisibility: .visible,
                            presenting: pending) { file in
            Button("Replace Script", role: .destructive) { upload(file) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { file in
            Text("Importing \"\(file.name)\" replaces every element in this script. This cannot be undone.")
        }
        .alert("Import Script",
               isPresented: Binding(get: { statusMessage != nil },
                                    set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: - Actions

    /// Reads the picked file up front — the security scope is only valid
    /// inside this callback, so the bytes are held until the user confirms.
    private func handlePick(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            statusMessage = "Couldn't read that file."
            return
        }
        pending = PendingScriptFile(name: url.lastPathComponent,
                                    data: data,
                                    mimeType: url.scriptMimeType)
    }

    private func upload(_ file: PendingScriptFile) {
        pending = nil
        Task {
            let updated = await model.importScript(fileName: file.name,
                                                   data: file.data,
                                                   mimeType: file.mimeType)
            if let updated {
                await onImported(updated)
                statusMessage = "Imported \"\(file.name)\"."
            } else {
                statusMessage = model.errorMessage ?? "Could not import that file."
            }
        }
    }

    /// Open when either the button or ⌘⇧I asked. Lowering the trigger on
    /// dismissal is what lets the shortcut work twice running.
    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { showingImporter || (trigger && !model.isImporting) },
            set: { showingImporter = $0; if !$0 { trigger = false } })
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    /// The formats the server's import pipeline accepts.
    private static var importTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .pdf]
        for ext in ["fountain", "fdx", "docx", "doc"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

/// A picked file waiting on the destructive confirmation.
private struct PendingScriptFile: Identifiable {
    let name: String
    let data: Data
    let mimeType: String

    var id: String { name }
}

private extension URL {
    var scriptMimeType: String {
        if let type = UTType(filenameExtension: pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
