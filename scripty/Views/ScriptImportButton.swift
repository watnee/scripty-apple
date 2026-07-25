//
//  ScriptImportButton.swift
//  scripty
//
//  Imports a screenplay file into the open project. The server replaces
//  every block with the parsed result, so — like the web app's import
//  button — this asks before uploading anything.
//
//  The picker, confirmation and status live in a view modifier rather than in
//  the toolbar button, so a File-menu command (⌘⇧I) can open the importer even
//  when the toolbar has cleared out: focus mode removes the import button, but
//  the menu route still works, matching the web's always-available ⌘⇧I.
//

import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Attach the screenplay importer, opened by flipping `isPresented`. The
    /// same flag is set by the toolbar's Import button and the File menu's
    /// "Import Script…" command, so both drive one picker and one model.
    func scriptImporter(app: AppModel, project: Project,
                        isPresented: Binding<Bool>,
                        onImported: @escaping (Project) async -> Void) -> some View {
        modifier(ScriptImporter(app: app, project: project,
                                isPresented: isPresented, onImported: onImported))
    }
}

private struct ScriptImporter: ViewModifier {
    @State private var model: ScriptImportModel
    @Binding var isPresented: Bool
    /// Run after a successful import. The caller MUST reload the script here:
    /// every block in the project has just been replaced.
    private let onImported: (Project) async -> Void

    @State private var pending: PendingScriptFile?
    @State private var statusMessage: String?

    init(app: AppModel, project: Project, isPresented: Binding<Bool>,
         onImported: @escaping (Project) async -> Void) {
        _model = State(initialValue: ScriptImportModel(app: app, project: project))
        _isPresented = isPresented
        self.onImported = onImported
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented,
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
