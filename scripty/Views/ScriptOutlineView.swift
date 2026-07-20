//
//  ScriptOutlineView.swift
//  scripty
//
//  The web app's outline sidebars — outline, characters, locations, songs,
//  bookmarks and pins — collapsed into one sheet with a segmented picker.
//  Tapping any row dismisses and sends the script page to that block.
//

import SwiftUI

struct ScriptOutlineView: View {
    let model: ScriptModel
    let navigator: ScriptNavigator

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    /// Opens on `tab`, so the keyboard shortcuts that name a particular list
    /// (⌘⇧C for characters, ⌘⇧M for songs) land on it rather than on the
    /// outline with a segment left to press.
    init(model: ScriptModel, navigator: ScriptNavigator, tab: Tab = .outline) {
        self.model = model
        self.navigator = navigator
        _tab = State(initialValue: tab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case outline, characters, locations, songs, bookmarks, pins

        var id: String { rawValue }

        var label: String {
            switch self {
            case .outline: return "Outline"
            case .characters: return "Characters"
            case .locations: return "Locations"
            case .songs: return "Songs"
            case .bookmarks: return "Bookmarks"
            case .pins: return "Pins"
            }
        }

        var systemImage: String {
            switch self {
            case .outline: return "list.bullet.indent"
            case .characters: return "person.2"
            case .locations: return "mappin.and.ellipse"
            case .songs: return "music.note.list"
            case .bookmarks: return "bookmark"
            case .pins: return "pin"
            }
        }

        var emptyMessage: String {
            switch self {
            case .outline: return "Add a scene heading or a section to build an outline."
            case .characters: return "No character cues in the screenplay yet."
            case .locations: return "No scene headings with a location yet."
            case .songs: return "No lyrics in the screenplay yet."
            case .bookmarks: return "Bookmark an element to find it again quickly."
            case .pins: return "Pin an element to keep it close at hand."
            }
        }
    }

    private var outline: ScriptOutline { model.outline }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        // Icons only: six labels never fit at phone width.
                        Label(tab.label, systemImage: tab.systemImage)
                            .labelStyle(.iconOnly)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                list
            }
            .navigationTitle(tab.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch tab {
        case .outline:
            rows(outline.entries, empty: tab.emptyMessage) { entry in
                jumpRow(to: entry.blockId) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let number = entry.sceneNumber {
                            Text(number, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                        } else {
                            Text(entry.type.label.prefix(1))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 22, alignment: .trailing)
                        }
                        Text(entry.preview)
                            .font(entry.type == .scene ? .body.weight(.medium) : .body)
                            .foregroundStyle(entry.type == .scene ? .primary : .secondary)
                        Spacer(minLength: 0)
                        if entry.isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

        case .characters:
            rows(outline.characters, empty: tab.emptyMessage) { character in
                jumpRow(to: character.blockId) {
                    LabeledContent(character.name) {
                        Text(character.speechCount, format: .number)
                            .monospacedDigit()
                    }
                }
            }

        case .locations:
            rows(outline.locations, empty: tab.emptyMessage) { location in
                jumpRow(to: location.blockId) {
                    LabeledContent(location.name) {
                        Text(location.sceneCount, format: .number)
                            .monospacedDigit()
                    }
                }
            }

        case .songs:
            rows(outline.songs, empty: tab.emptyMessage) { song in
                jumpRow(to: song.blockId) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.name)
                        Text("\(song.lineCount) line\(song.lineCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .bookmarks:
            rows(model.bookmarkedBlocks, empty: tab.emptyMessage) { block in
                jumpRow(to: block.id) { blockLabel(block) }
            }

        case .pins:
            rows(model.pinnedBlocks, empty: tab.emptyMessage) { block in
                jumpRow(to: block.id) { blockLabel(block) }
            }
        }
    }

    private func blockLabel(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ScriptOutline.preview(block.content ?? ""))
            Text(block.blockType.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rows<Item: Identifiable, Row: View>(
        _ items: [Item],
        empty: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        List {
            ForEach(items) { row($0) }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: tab.systemImage,
                    description: Text(empty))
            }
        }
    }

    /// Every row does the same thing: close the sheet, then scroll the script.
    private func jumpRow<Content: View>(
        to blockId: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            dismiss()
            navigator.jump(to: blockId)
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
