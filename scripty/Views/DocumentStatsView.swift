//
//  DocumentStatsView.swift
//  scripty
//
//  How long a song or a note is — `ScriptStatsView` for the other two writing
//  surfaces, and deliberately its sibling rather than its own idea of a stats
//  screen: the same adaptive tile strip, the same tile, the same empty state, so
//  the three read as one family however a writer arrives at them.
//
//  One sheet for both kinds. A song and a note differ in three rows and in what
//  a couple of the labels are called, which is not enough to be worth two files
//  that would then drift apart.
//

import SwiftUI

struct DocumentStatsView: View {
    let title: String
    let stats: DocumentStats

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if stats.hasNothingToMeasure {
                    ContentUnavailableView(
                        "Nothing to Measure",
                        systemImage: "chart.bar",
                        description: Text("Start writing and the numbers will show up here."))
                } else {
                    statsList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statsList: some View {
        List {
            Section {
                tiles
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if !stats.longestLine.isEmpty {
                Section(stats.longestLineLabel) {
                    Text(stats.longestLine)
                        .font(.callout)
                    Text("\(stats.formatted(stats.longestLineWords)) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Characters") {
                    Text(stats.formatted(stats.characters)).monospacedDigit()
                }
                LabeledContent("Characters, no spaces") {
                    Text(stats.formatted(stats.charactersNoSpaces)).monospacedDigit()
                }
                LabeledContent("Blank lines") {
                    Text(stats.formatted(stats.blankLines)).monospacedDigit()
                }
                if stats.kind == .note {
                    LabeledContent("Headings") {
                        Text(stats.formatted(stats.headings)).monospacedDigit()
                    }
                    LabeledContent("List items") {
                        Text(stats.formatted(stats.listItems)).monospacedDigit()
                    }
                }
            }

            Section {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Adaptive so the strip reads as one row on iPad and wraps to two columns
    /// at phone width — the same grid the screenplay's sheet uses.
    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            tile(value: stats.formatted(stats.words), label: "Words",
                 hint: "\(stats.formatted(stats.uniqueWords)) different")
            tile(value: stats.formatted(stats.lines), label: stats.linesLabel,
                 hint: stats.blankLines > 0 ? "\(stats.formatted(stats.blankLines)) blank" : nil)
            tile(value: stats.formatted(stats.sections), label: "Sections",
                 hint: nil)
            tile(value: stats.readingTimeText, label: "Read aloud",
                 hint: "at \(DocumentStats.wordsPerMinute) words a minute")
        }
    }

    private func tile(value: String, label: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Says what "Sections" counted, and why there is no page estimate — the
    /// question the screenplay's sheet answers in its own footnote.
    private var footnote: String {
        let measured = stats.kind == .song
            ? "A song is measured in lines rather than pages."
            : "A note is measured in paragraphs rather than pages."
        return "\(stats.sectionsHint) \(measured)"
    }
}
