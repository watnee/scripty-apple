//
//  ScriptExportModel.swift
//  scripty
//
//  Export and print, held apart from the button that usually starts them.
//
//  The toolbar menu is no longer the only way in — the Mac menu bar reaches
//  the same actions — so the in-flight state and the resulting file live here
//  rather than inside a view. Whoever starts an export, one share sheet and
//  one alert answer for it.
//

import SwiftUI
import UIKit

@Observable
@MainActor
final class ScriptExportModel {
    private let model: ScriptModel

    /// The finished file, waiting to be shared. Presented as a sheet.
    var exportedFile: ExportedFile?
    var isExporting = false
    var errorMessage: String?

    struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    init(model: ScriptModel) {
        self.model = model
    }

    var options: [ScriptModel.ExportOption] { model.exportOptions }
    var printableOption: ScriptModel.ExportOption? { model.printableOption }

    func export(_ option: ScriptModel.ExportOption) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                exportedFile = ExportedFile(url: try await model.export(option))
            } catch {
                // Nothing cancelled is ever shown — see `isCancelledRequest`.
                if !error.isCancelledRequest { errorMessage = error.localizedDescription }
            }
            isExporting = false
        }
    }

    /// Downloads the PDF and hands it to the system print panel.
    ///
    /// The file is fetched whole rather than streamed because the print
    /// controller counts pages up front to build its preview.
    ///
    /// Offline, the download fails fast and the fallback takes over: the
    /// cached blocks are paginated and drawn into a PDF on the device
    /// (ScreenplayPDF shares the paginator's arithmetic, so the sheets match
    /// the server's). Only the no-route case falls back — a reachable network
    /// with a failing server keeps its alert, because there the honest answer
    /// is that the export the writer asked for didn't happen.
    func print(_ option: ScriptModel.ExportOption) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                presentPrintPanel(for: try await model.export(option))
            } catch {
                if error.isRetryableAPIError, !model.app.connectivity.isOnline,
                   let url = offlinePrintFile() {
                    presentPrintPanel(for: url)
                } else if !error.isCancelledRequest {
                    errorMessage = error.localizedDescription
                }
            }
            isExporting = false
        }
    }

    private func presentPrintPanel(for url: URL) {
        PrintPanel.present(url, jobName: model.project.displayTitle) { message in
            self.errorMessage = message
        }
    }

    /// The script on screen drawn into a PDF here on the device, for printing
    /// with no route to the server. Page setup and casing are read at the
    /// moment of printing, exactly as the online path sends them along with
    /// the export request; the default face is read the same way, though it
    /// has no counterpart to send — the server sets its own exports in Courier
    /// whatever any block says, so this is the one PDF the setting reaches. Nil when there is nothing to put on paper — no
    /// pages and no cover — or the file cannot be written; the caller shows
    /// the ordinary failure alert then.
    private func offlinePrintFile() -> URL? {
        let setup = PresentationSettings.shared.pageSetup
        let pages = ScriptPagination.paginate(blocks: model.blocks, setup: setup)
        let cover = ScreenplayCover(project: model.project)
        guard !pages.isEmpty || cover != nil else { return nil }

        let title = model.project.displayTitle
        let data = ScreenplayPDF.render(
            pages: pages, cover: cover, setup: setup, title: title,
            defaultFont: PresentationSettings.shared.defaultFont,
            cased: { CapitalizationSettings.shared.displayCased($0, forBlockType: $1) })
        guard !data.isEmpty else { return nil }

        let url = model.shareableFileURL(named: title.isEmpty ? "script" : title,
                                         fileExtension: "pdf")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
