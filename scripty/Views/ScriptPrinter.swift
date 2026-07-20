//
//  ScriptPrinter.swift
//  scripty
//
//  Printing, via the PDF the server already renders.
//
//  The app can paginate a script itself — page view does — but printing from
//  that would mean a second layout engine drawing into Core Graphics, and two
//  renderers of the same screenplay drift. The PDF export is the layout the
//  server, the web app's print, and page view all already agree on, so
//  printing downloads it and hands it to UIKit. Page setup rides along,
//  because a paged export carries it as a query.
//
//  Gated on `exportPdf`: a server that does not offer the PDF cannot be
//  printed from, and shows no Print entry rather than one that fails.
//

import UIKit

enum ScriptPrinter {

    /// Presents the system print panel for a PDF on disk.
    ///
    /// `jobName` is what shows in the print queue and in Printer Setup, so it
    /// is the screenplay's title rather than the temp file's name.
    @MainActor
    static func present(pdf url: URL, jobName: String) {
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url

        // On iPad the panel is a popover and needs something to point at. The
        // key window's root view is the honest anchor here: printing is
        // reached from a menu that has already closed by now, so there is no
        // live source view left to hang it off.
        if let root = anchorView {
            controller.present(from: root.bounds, in: root, animated: true)
        } else {
            controller.present(animated: true)
        }
    }

    private static var anchorView: UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .view
    }
}
