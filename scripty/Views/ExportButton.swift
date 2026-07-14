//
//  ExportButton.swift
//  scripty
//
//  Export menu built from whichever export rels the server advertised.
//  Downloads run through the authenticated client (Basic auth), so a
//  plain ShareLink on the URL wouldn't work.
//

import SwiftUI
import UIKit

struct ExportButton: View {
    let model: ScriptModel

    @State private var exportedFile: ExportedFile?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        Menu {
            ForEach(model.exportOptions) { option in
                Button(option.label) {
                    export(option)
                }
            }
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(isExporting)
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Export Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private func export(_ option: ScriptModel.ExportOption) {
        isExporting = true
        Task {
            do {
                let url = try await model.export(option)
                exportedFile = ExportedFile(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
