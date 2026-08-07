//
//  DocumentExportMenu.swift
//  scripty
//
//  Export, for a song or a note — the sibling of `DocumentPrintButton`, and
//  built to match it, because the two are always drawn next to each other.
//
//  The house rule the print button states is that print sits *beside* the
//  export menu rather than inside it: one is an errand, the other is a choice
//  of format. Print was rolled out to four more surfaces on the strength of
//  that rule and export was not, so the two editors and both workspaces ended
//  up offering half the pair — while the help promised, in as many words, that
//  "Print sits beside Export wherever Export is… in either editor's '…' menu
//  for the one you have open, and in the list's and the workspace's menus."
//
//  Three pieces, exactly as printing has three: a model that holds the download
//  in flight and whatever came back, a menu the surfaces drop into their "…",
//  and one presentation modifier the owning screen attaches once. The share
//  sheet has to be presented by a view that outlives the menu — a menu is torn
//  down the moment an item in it is chosen — which is why it is a modifier on
//  the screen rather than something the menu carries itself.
//

import SwiftUI
import Observation

/// A download in flight, and the file it produced.
///
/// One of these per screen, held the way `DocumentPrintModel` is: the alert and
/// the share sheet are attached once, so every door reports through the same
/// place rather than each surface growing its own pair of `@State`s.
@Observable
@MainActor
final class DocumentExportModel {
    private let model: ScriptModel

    /// The finished file, waiting to be handed to the share sheet. Cleared when
    /// the sheet goes.
    var exported: ExportedFile?
    var errorMessage: String?
    /// True from the tap until the bytes are on disk. The menu closes on the
    /// tap, so this is not there to disable anything — it stops a second
    /// download being started from a different door while the first is running.
    private(set) var isExporting = false

    init(model: ScriptModel) {
        self.model = model
    }

    /// Downloads one format and puts the file up to be shared. `named` is what
    /// the file is called, which is the document's title for a single document
    /// and the collection's name for a gathering.
    func export(_ option: ScriptModel.ExportOption, named name: String) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await model.downloadExport(option, named: name)
                exported = ExportedFile(url: url)
            } catch {
                // Cancellation is this app's own doing and never news — the
                // screen was left while the bytes were coming down.
                guard !error.isCancelledRequest else { return }
                errorMessage = "Could not export “\(name)”."
            }
        }
    }
}

/// A downloaded file, identified by where it landed so the sheet can be driven
/// by `item:` rather than by a flag and a separate value.
struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The "Export…" menu, for a "…" menu or a toolbar's overflow.
///
/// Draws nothing at all where the server advertised no formats, which is what
/// keeps it out of a read-only collaborator's menu without every caller having
/// to ask.
struct DocumentExportMenu: View {
    let exporter: DocumentExportModel
    let options: [ScriptModel.ExportOption]
    /// What the downloaded file should be called.
    let name: String

    var body: some View {
        if !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    Button(option.label) { exporter.export(option, named: name) }
                }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// The share sheet and the failure alert, attached once by the screen that owns
/// the exporter — the same arrangement `documentPrintPresentation` uses, and
/// for the same reason: the menu that started the download is gone by the time
/// there is anything to show.
struct DocumentExportPresentation: ViewModifier {
    let exporter: DocumentExportModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { exporter.exported },
                set: { exporter.exported = $0 })) { file in
                    ShareSheet(items: [file.url])
                }
            .alert("Export Failed", isPresented: Binding(
                get: { exporter.errorMessage != nil },
                set: { if !$0 { exporter.errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(exporter.errorMessage ?? "")
                }
    }
}

extension View {
    func documentExportPresentation(_ exporter: DocumentExportModel) -> some View {
        modifier(DocumentExportPresentation(exporter: exporter))
    }
}
