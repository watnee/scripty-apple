//
//  DocumentPrintModel.swift
//  scripty
//
//  Printing a song or a note — `ScriptExportModel`'s counterpart for the other
//  two things this app writes, and it works the same way for the same reasons.
//
//  Online, the PDF export is downloaded and handed to the system print panel,
//  so the paper is the file the writer would have exported rather than a second
//  rendering of the same words. Offline, the download fails fast and
//  `DocumentPDF` draws the copy this device already has: a song from its cached
//  lyric lines, a note from its cached text, and either of them from the words
//  in the editor that asked, which are fresher than anything on disk.
//
//  Held apart from the views because there are five doors to it — the list's
//  row menu, its Print All, the two editors and the two workspaces — and one
//  in-flight state and one failure alert should answer for all of them.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class DocumentPrintModel {
    private let model: ScriptModel

    /// Set while a download is in flight, so the buttons that started it can
    /// say so and refuse a second press.
    var isPrinting = false
    var errorMessage: String?

    init(model: ScriptModel) {
        self.model = model
    }

    /// Whether a row offers printing: the server advertised a PDF for this
    /// document. Deliberately only the link, and not "or this device has words
    /// it could draw" — that question reads the cache off disk, and a row menu
    /// is rebuilt with the list. It costs nothing offline either, since the
    /// links come back with the cached list; the draw-it-here fallback is what
    /// answers when the download then fails.
    func canPrint(_ document: TextDocument) -> Bool {
        model.documentPrintOption(for: document) != nil
    }

    /// One song or note.
    ///
    /// `lines` is what the caller has on screen, where it has any: an editor
    /// knows the words better than the cache does, including the ones typed
    /// since the last save. It is only ever reached for offline — online the
    /// server's own file is what gets printed, exactly as it is for the script.
    func print(_ document: TextDocument, lines: [String]? = nil) {
        let title = document.displayTitle
        start(jobName: title,
              option: model.documentPrintOption(for: document),
              named: title) { [self] in
            section(for: document, lines: lines).map { [$0] } ?? []
        }
    }

    /// Words that are not a document on the server yet — a note being written
    /// for the first time, whose save has not landed. There is no rel to ask
    /// for, so this is always drawn here on the device.
    func print(title: String, lines: [String]) {
        start(jobName: title, option: nil, named: title) {
            let section = DocumentPDF.Section(title: title, lines: lines)
            return section.isEmpty ? [] : [section]
        }
    }

    /// A whole list — every song in the project, or every note.
    ///
    /// `lines` is the same offer the single-document print makes, asked once
    /// per document: a workspace has several of them open and knows their words
    /// better than the cache does. Nil for the ones it has nothing for, which
    /// then fall back to the cache like everything else.
    func print(all documents: [TextDocument], of type: DocumentType, named: String,
               lines: ((TextDocument) -> [String]?)? = nil) {
        printCollection(documents, of: type, ids: [], named: named, lines: lines)
    }

    /// The ticked rows only. The server's file is narrowed by the same ids the
    /// export menu appends, so the paper holds what the writer chose.
    func print(selected documents: [TextDocument], of type: DocumentType, named: String,
               lines: ((TextDocument) -> [String]?)? = nil) {
        printCollection(documents, of: type, ids: documents.map(\.id), named: named,
                        lines: lines)
    }

    private func printCollection(_ documents: [TextDocument], of type: DocumentType,
                                 ids: [Int], named: String,
                                 lines: ((TextDocument) -> [String]?)?) {
        start(jobName: named,
              option: model.collectionPrintOption(for: type, ids: ids),
              named: named) { [self] in
            documents.compactMap { document in
                section(for: document, lines: lines.flatMap { onScreen in onScreen(document) })
            }
        }
    }

    /// Downloads the PDF and hands it to the print panel, falling back to what
    /// this device can draw when there is no route to the server.
    ///
    /// Only the no-route case falls back, as in `ScriptExportModel.print`: a
    /// reachable server that refuses keeps its alert, because there the honest
    /// answer is that the print the writer asked for did not happen. With no
    /// print rel at all — an older server, or a demo that never advertised one
    /// — the fallback is the whole of it.
    private func start(jobName: String, option: ScriptModel.ExportOption?,
                       named: String, sections: @escaping () -> [DocumentPDF.Section]) {
        guard !isPrinting else { return }
        isPrinting = true
        Task {
            do {
                guard let option else { throw PrintUnavailable() }
                let url = try await model.downloadExport(option, named: named)
                present(url, jobName: jobName)
            } catch {
                if let url = offlineFile(sections(), named: named),
                   option == nil || (error.isRetryableAPIError && !model.app.connectivity.isOnline) {
                    present(url, jobName: jobName)
                } else if !error.isCancelledRequest {
                    errorMessage = message(for: error)
                }
            }
            isPrinting = false
        }
    }

    /// There is no server file and nothing on this device to draw instead.
    private struct PrintUnavailable: Error {}

    private func message(for error: Error) -> String {
        error is PrintUnavailable
            ? "There is nothing to print, or this needs a connection."
            : error.localizedDescription
    }

    private func present(_ url: URL, jobName: String) {
        PrintPanel.present(url, jobName: jobName) { [self] message in
            errorMessage = message
        }
    }

    /// What this device can put on paper for a document: the words handed over,
    /// else the copy it cached. Nil where it holds neither, and where what it
    /// holds is blank — a sheet with nothing but a title on it is not what
    /// anyone pressed Print for.
    private func section(for document: TextDocument,
                         lines: [String]? = nil) -> DocumentPDF.Section? {
        guard let lines = lines ?? model.cachedDocumentLines(document) else { return nil }
        let section = DocumentPDF.Section(title: document.displayTitle, lines: lines)
        return section.isEmpty ? nil : section
    }

    /// The sections drawn into a PDF here on the device. Nil when there is
    /// nothing to draw or the file cannot be written; the caller reports the
    /// original failure then.
    private func offlineFile(_ sections: [DocumentPDF.Section], named: String) -> URL? {
        guard !sections.isEmpty else { return nil }
        let data = DocumentPDF.render(sections, title: named)
        guard !data.isEmpty else { return nil }
        let url = model.shareableFileURL(named: named.isEmpty ? "document" : named,
                                         fileExtension: "pdf")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
