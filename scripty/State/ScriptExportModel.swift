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
    func print(_ option: ScriptModel.ExportOption) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                let url = try await model.export(option)
                let info = UIPrintInfo.printInfo()
                info.outputType = .general
                info.jobName = model.project.displayTitle

                let controller = UIPrintInteractionController.shared
                controller.printInfo = info
                controller.printingItem = url
                controller.present(animated: true) { _, _, error in
                    MainActor.assumeIsolated {
                        if let error { self.errorMessage = error.localizedDescription }
                    }
                }
            } catch {
                if !error.isCancelledRequest { errorMessage = error.localizedDescription }
            }
            isExporting = false
        }
    }
}
