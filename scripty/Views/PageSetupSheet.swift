//
//  PageSetupSheet.swift
//  scripty
//
//  Paper size, margins and page numbering — the web app's page-setup dialog.
//  Choices apply live to the page view behind the sheet, and the line budget
//  is spelled out because changing margins is really a decision about how much
//  script fits on a page.
//

import SwiftUI

struct PageSetupSheet: View {
    @Bindable var settings: PresentationSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Paper") {
                    Picker("Paper Size", selection: $settings.pageSetup.paper) {
                        ForEach(PaperSize.allCases) { paper in
                            VStack(alignment: .leading) {
                                Text(paper.label)
                                Text(paper.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(paper)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Margins") {
                    Picker("Margins", selection: $settings.pageSetup.margins) {
                        ForEach(MarginPreset.allCases) { preset in
                            VStack(alignment: .leading) {
                                Text(preset.label)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(preset)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Page Numbers") {
                    Picker("Page Numbers", selection: $settings.pageSetup.pageNumbers) {
                        ForEach(PageNumberPlacement.allCases) { placement in
                            Text(placement.label).tag(placement)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    LabeledContent("Text column",
                                   value: measurement(settings.pageSetup.textWidthIn))
                    LabeledContent("Lines per page",
                                   value: "\(settings.pageSetup.linesPerPage)")
                } header: {
                    Text("Result")
                } footer: {
                    Text("Page one is never numbered, by screenplay convention.")
                }

                Section {
                    Button("Reset to Standard", role: .destructive) {
                        settings.resetPageSetup()
                    }
                    .disabled(settings.pageSetup == .default)
                }
            }
            .navigationTitle("Page Setup")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func measurement(_ inches: Double) -> String {
        String(format: "%.2f in", inches)
    }
}
