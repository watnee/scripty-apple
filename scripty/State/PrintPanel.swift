//
//  PrintPanel.swift
//  scripty
//
//  The system print panel, wherever a PDF came from.
//
//  Its own type because there are two things to print now — the screenplay,
//  and a song or a note — reached from a list, two editors, two workspaces and
//  the menu bar. All of them want the same panel with the same job name, and
//  the one thing they must not do is each configure the shared controller
//  slightly differently.
//

import UIKit

enum PrintPanel {
    /// Hands a file to the print panel, naming the job after whatever is being
    /// printed so it is recognisable in the printer queue.
    ///
    /// `onError` hears only about a print that failed after the panel took the
    /// job; a writer who cancels the panel has not hit a problem and is told
    /// nothing.
    @MainActor
    static func present(_ url: URL, jobName: String, onError: @escaping (String) -> Void) {
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true) { _, _, error in
            MainActor.assumeIsolated {
                if let error { onError(error.localizedDescription) }
            }
        }
    }
}
