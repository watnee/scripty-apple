//
//  ScriptStatsView.swift
//  scripty
//
//  The web app's Script Stats page as a sheet: overview tiles, the dialogue /
//  action balance, then the character and location breakdowns. Everything is
//  computed from the blocks already in memory.
//

import SwiftUI

struct ScriptStatsView: View {
    let model: ScriptModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Computed once per evaluation: building ScriptStats walks the whole
        // script, and the sections below read it dozens of times.
        let stats = model.stats
        NavigationStack {
            Group {
                if stats.hasNothingToMeasure {
                    ContentUnavailableView(
                        "Nothing to Measure",
                        systemImage: "chart.bar",
                        description: Text("Start writing and your stats will show up here."))
                } else {
                    statsList(stats)
                }
            }
            .navigationTitle("Script Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statsList(_ stats: ScriptStats) -> some View {
        List {
            Section {
                tiles(stats)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if stats.dialogueWords > 0 || stats.actionWords > 0 {
                Section("Dialogue vs. Action") { balance(stats) }
            }

            if !stats.characters.isEmpty {
                Section("Characters") {
                    ForEach(stats.characters) { character in
                        characterRow(character)
                    }
                }
            }

            if !stats.locations.isEmpty {
                Section("Locations") {
                    ForEach(stats.locations) { location in
                        LabeledContent(location.name) {
                            Text(location.sceneCount, format: .number)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section {
                Text("""
                     Page count is an estimate based on standard screenplay \
                     formatting (Courier 12, ~55 lines per page). One page \
                     roughly equals one minute of screen time.
                     """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Overview tiles

    /// Adaptive so the row reads as one wide strip on iPad and wraps to two
    /// columns at phone width.
    private func tiles(_ stats: ScriptStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            tile(value: stats.pageEstimate.formatted(), label: "Estimated pages",
                 hint: "~\(stats.pageEstimate) min screen time")
            tile(value: stats.sceneCount.formatted(), label: "Scenes",
                 hint: stats.interiorSceneCount > 0 || stats.exteriorSceneCount > 0
                     ? "\(stats.interiorSceneCount) INT · \(stats.exteriorSceneCount) EXT"
                     : nil)
            tile(value: stats.totalWords.formatted(), label: "Words",
                 hint: "\(stats.blockCount.formatted()) elements")
            tile(value: stats.speakingCharacterCount.formatted(), label: "Speaking characters",
                 hint: nil)
            tile(value: stats.locationCount.formatted(), label: "Locations",
                 hint: stats.daySceneCount > 0 || stats.nightSceneCount > 0
                     ? "\(stats.daySceneCount) day · \(stats.nightSceneCount) night"
                     : nil)
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

    // MARK: - Balance

    private func balance(_ stats: ScriptStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(stats.dialoguePercent) / 100)
                    Rectangle()
                        .fill(.quaternary)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .accessibilityLabel("\(stats.dialoguePercent)% dialogue, \(stats.actionPercent)% action")

            HStack(spacing: 12) {
                legend(color: Color.accentColor,
                       text: "Dialogue \(stats.dialoguePercent)% (\(stats.dialogueWords.formatted()) words)")
                legend(color: Color(.quaternaryLabel),
                       text: "Action \(stats.actionPercent)% (\(stats.actionWords.formatted()) words)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: - Characters

    private func characterRow(_ character: CharacterStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(character.name)
                    .font(.headline)
                Spacer()
                Text("\(character.dialogueSharePercent)%")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geometry.size.width * CGFloat(character.dialogueSharePercent) / 100))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 4)
            .background(.quaternary, in: Capsule())

            Text("\(character.speechCount.formatted()) speeches · \(character.wordCount.formatted()) words · \(character.sceneCount.formatted()) scenes")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
