//
//  ExportButton.swift
//  scripty
//
//  Export menu and print button, built from whichever export rels the server
//  advertised. Downloads run through the authenticated client (Basic auth),
//  so a plain ShareLink on the URL wouldn't work.
//
//  The work itself lives in ScriptExportModel, because the Mac menu bar
//  starts the same exports without going through this button.
//

import SwiftUI
import UIKit

struct ExportButton: View {
    let exporter: ScriptExportModel

    var body: some View {
        Menu {
            ForEach(exporter.options) { option in
                Button(option.label) {
                    exporter.export(option)
                }
            }
        } label: {
            if exporter.isExporting {
                ProgressView()
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(exporter.isExporting)
    }
}

/// Print, beside the export menu rather than inside it. The menu is a list of
/// file formats to carry away; print is an errand, not a format, and buried
/// in there it read as one more of them. The Mac menu bar has always kept the
/// two apart — its Print… item (⌘P) sits outside the Export submenu.
///
/// Nothing without a PDF rel to print from, just as the menu is nothing
/// without export rels. Shares the exporter's in-flight state, so starting
/// either holds both until the download settles.
struct PrintButton: View {
    let exporter: ScriptExportModel

    var body: some View {
        if let printable = exporter.printableOption {
            Button {
                exporter.print(printable)
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .disabled(exporter.isExporting)
        }
    }
}

/// The share sheet and failure alert for exports, attached once by the screen
/// that owns the exporter so every entry point reports through the same place.
struct ExportPresentation: ViewModifier {
    let exporter: ScriptExportModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { exporter.exportedFile },
                set: { exporter.exportedFile = $0 })) { file in
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
    func exportPresentation(_ exporter: ScriptExportModel) -> some View {
        modifier(ExportPresentation(exporter: exporter))
    }
}

/// Shared by the script export button and the per-song export menu, so a
/// downloaded file reaches the system share sheet the same way from both.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
