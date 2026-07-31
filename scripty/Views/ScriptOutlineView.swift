//
//  ScriptOutlineView.swift
//  scripty
//
//  The web app's outline sidebars — outline, characters, locations, songs,
//  bookmarks and pins — collapsed into one sheet with a segmented picker, plus
//  a list of the elements people have commented on.
//  Tapping any row dismisses and sends the script page to that block.
//

import SwiftUI

struct ScriptOutlineView: View {
    let model: ScriptModel
    let navigator: ScriptNavigator
    /// Where the last-shown list is remembered. Optional so callers without a
    /// project's options (previews, say) still get a working sheet.
    var options: ScriptViewOptions?

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab

    init(model: ScriptModel, navigator: ScriptNavigator, options: ScriptViewOptions? = nil) {
        self.model = model
        self.navigator = navigator
        self.options = options
        // Reopen on the list the writer left, falling back to Outline for a
        // first open or a stored name a later build no longer knows.
        let remembered = options?.rememberedOutlineTab.flatMap(Tab.init(rawValue:))
        _tab = State(initialValue: remembered ?? .outline)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case outline, characters, locations, songs, bookmarks, pins, comments

        var id: String { rawValue }

        var label: String {
            switch self {
            case .outline: return "Outline"
            case .characters: return "Characters"
            case .locations: return "Locations"
            case .songs: return "Songs"
            case .bookmarks: return "Bookmarks"
            case .pins: return "Pins"
            case .comments: return "Comments"
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
            case .comments: return "bubble.left.and.bubble.right"
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
            case .comments: return "Notes people leave on an element are collected here."
            }
        }
    }

    var body: some View {
        // Computed once per evaluation: building the outline walks the whole
        // script, and the tabs below read it several times.
        let outline = model.outline
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
                .onChange(of: tab) { _, newTab in
                    options?.rememberOutlineTab(newTab.rawValue)
                }

                markVisibilityToggle

                list(outline)
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

    /// Whether the marks are drawn beside the script's lines, offered next to
    /// the list of them rather than in the View menu: a writer thinking about
    /// pins or bookmarks is already looking at this panel, and the list here
    /// keeps working as a way back to a line whose mark is hidden on the page.
    ///
    /// It sits above the list rather than in it so that an empty tab — the very
    /// case where a writer wonders where their marks went — still shows it,
    /// instead of losing it under the "Nothing Here Yet" overlay.
    @ViewBuilder
    private var markVisibilityToggle: some View {
        if let binding = markVisibility {
            Toggle(isOn: binding) {
                Label("Show \(tab.label) in the Script", systemImage: tab.systemImage)
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// The per-project setting behind the toggle, for the two tabs that have
    /// one. nil elsewhere, and nil without a project's options — previews pass
    /// none, and there is nothing to remember the choice in.
    private var markVisibility: Binding<Bool>? {
        guard let options else { return nil }
        switch tab {
        case .pins:
            return Binding(get: { options.showsPins }, set: { options.showsPins = $0 })
        case .bookmarks:
            return Binding(get: { options.showsBookmarks },
                           set: { options.showsBookmarks = $0 })
        default:
            return nil
        }
    }

    @ViewBuilder
    private func list(_ outline: ScriptOutline) -> some View {
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
            let marked = model.bookmarkedBlocks
            let scenes = sceneContexts(for: marked)
            rows(marked, empty: tab.emptyMessage) { block in
                jumpRow(to: block.id) {
                    blockLabel(block, icon: "bookmark.fill", scene: scenes[block.id])
                }
                .swipeActions(edge: .trailing) {
                    unmark(block, rel: .toggleBookmark,
                           title: "Remove", systemImage: "bookmark.slash") {
                        await model.toggleBookmark(block)
                    }
                }
            }

        case .pins:
            let marked = model.pinnedBlocks
            let scenes = sceneContexts(for: marked)
            rows(marked, empty: tab.emptyMessage) { block in
                jumpRow(to: block.id) {
                    blockLabel(block, icon: "pin.fill", scene: scenes[block.id])
                }
                .swipeActions(edge: .trailing) {
                    unmark(block, rel: .togglePinned,
                           title: "Unpin", systemImage: "pin.slash") {
                        await model.togglePinned(block)
                    }
                }
            }

        case .comments:
            let commented = model.commentedBlocks
            let scenes = sceneContexts(for: commented)
            rows(commented, empty: tab.emptyMessage) { block in
                jumpRow(to: block.id) {
                    blockLabel(block, icon: "bubble.left.fill", tint: .secondary,
                               scene: scenes[block.id],
                               trailing: model.commentCount(for: block))
                }
            }
        }
    }

    private func sceneContexts(for blocks: [Block]) -> [Int: OutlineSceneContext] {
        ScriptOutline.sceneContexts(for: Set(blocks.map(\.id)), in: model.blocks)
    }

    /// Cues carry the speaker's name as their text, but one linked to a
    /// character record may carry none — fall back to the name the script row
    /// shows in its place, rather than calling the line untitled.
    private func previewText(_ block: Block) -> String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    /// "Dialogue · Scene 2 · EXT. STUDIO PARKING LOT - NIGHT" — what kind of
    /// line it is and where in the script it sits.
    ///
    /// A scene heading is its own answer to "where": it says only which scene
    /// it is, rather than naming itself twice over.
    private func context(_ block: Block, scene: OutlineSceneContext?) -> String {
        guard let scene else { return block.blockType.label }
        if block.blockType == .scene { return "Scene \(scene.number)" }
        return "\(block.blockType.label) · Scene \(scene.number) · \(scene.heading)"
    }

    /// A marked element: what it says, what kind of element it is, and — the
    /// part a preview of the line alone never tells you — which scene it is in.
    private func blockLabel(_ block: Block,
                            icon: String,
                            tint: Color = .orange,
                            scene: OutlineSceneContext?,
                            trailing count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScriptOutline.preview(previewText(block)))
                Text(context(block, scene: scene))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let count, count > 0 {
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Taking a mark off from the list it appears in — the counterpart of the
    /// element menu's Unpin/Remove Bookmark, so a writer clearing out old marks
    /// doesn't have to visit each line to do it. Offered only where the server
    /// says the element can be marked at all.
    @ViewBuilder
    private func unmark(_ block: Block, rel: Rel, title: String, systemImage: String,
                        action: @escaping () async -> Void) -> some View {
        if block.hasLink(rel) {
            Button {
                Task { await action() }
            } label: {
                Label(title, systemImage: systemImage)
            }
            .tint(.orange)
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
