//
//  DocumentPrintButton.swift
//  scripty
//
//  Print, for a song or a note. The screenplay's `PrintButton` under a
//  different noun, and it keeps that button's decision: print sits beside the
//  export menu rather than inside it, because it is an errand rather than one
//  more file format to carry away.
//
//  Nothing without something to print — a PDF rel from the server, or words
//  this device is holding to draw itself. The failure alert is attached once,
//  by whichever screen owns the printer, so every door reports through the same
//  place.
//

import SwiftUI

/// One song or note, from a row's menu.
///
/// The editors write their own item rather than using this: they print the
/// words on screen, which are fresher than anything the cache holds, and
/// gathering those on every redraw to decide whether to draw a button is work
/// per keystroke.
struct DocumentPrintButton: View {
    let printer: DocumentPrintModel
    let document: TextDocument

    var body: some View {
        if printer.canPrint(document) {
            Button {
                printer.print(document)
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .disabled(printer.isPrinting)
        }
    }
}

/// The failure alert for prints, attached once by the screen that owns the
/// printer. A cancelled panel says nothing — see `PrintPanel`.
struct DocumentPrintPresentation: ViewModifier {
    let printer: DocumentPrintModel

    func body(content: Content) -> some View {
        content
            .alert("Print Failed", isPresented: Binding(
                get: { printer.errorMessage != nil },
                set: { if !$0 { printer.errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(printer.errorMessage ?? "")
                }
    }
}

extension View {
    func documentPrintPresentation(_ printer: DocumentPrintModel) -> some View {
        modifier(DocumentPrintPresentation(printer: printer))
    }
}
