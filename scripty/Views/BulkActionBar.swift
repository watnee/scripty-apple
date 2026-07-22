//
//  BulkActionBar.swift
//  scripty
//
//  What you can do to a set of selected elements — the iPad counterpart of the
//  web editor's selection toolbar. Every action is one request and one undo
//  step, and each is shown only when the server advertised it.
//

import SwiftUI

/// An element while the script is in selection mode: rendered read-only with a
/// checkmark, because a row you are selecting is not a row you are typing into.
struct SelectableBlockRow: View {
    let block: Block
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.top, 2)

            BlockRowView(block: block)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isSelected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct BulkActionBar: View {
    let model: ScriptModel
    @Bindable var selection: BlockSelectionModel

    /// What select-all reaches. The web app's select-all honours an active
    /// search filter — "all" means all the writer can see — but the iPad
    /// search walks hits instead of filtering rows out, so the caller decides
    /// what "all" currently means and says whether it narrowed the set.
    let selectableIds: [Int]
    let isFiltered: Bool

    @State private var isTagging = false
    @State private var tagText = ""
    @State private var confirmDelete = false
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(countLabel)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)

                selectAllButton

                Spacer(minLength: 0)

                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    actions
                }

                Button("Done") {
                    selection.isSelecting = false
                }
                .font(.body.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .alert("Add Tags", isPresented: $isTagging) {
            TextField("Tags, separated by commas", text: $tagText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { tagText = "" }
            Button("Add") {
                let tags = tagText
                tagText = ""
                run { await model.bulkAddTags(ids, tags: tags) }
            }
        } message: {
            Text("Tags are added to the \(countLabel.lowercased()), keeping any already there.")
        }
        .alert("Delete Elements", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                run { await model.bulkDelete(ids) }
            }
        } message: {
            Text("Delete \(countLabel.lowercased())? This can be undone.")
        }
        // A bulk delete or a background sync can remove blocks out from under
        // the selection; drop any id that no longer exists rather than posting it.
        .onChange(of: model.blocks) { _, blocks in
            selection.prune(toExisting: blocks.map(\.id))
        }
    }

    /// One button rather than a separate Select All and Deselect All: once
    /// everything is selected the only useful move is to start over, and a
    /// disabled button there would just be dead weight in a crowded bar.
    @ViewBuilder
    private var selectAllButton: some View {
        if !selectableIds.isEmpty && !isWorking {
            Button(selectAllLabel) {
                if isEverythingSelected {
                    selection.clear()
                } else {
                    selection.selectAll(selectableIds)
                }
            }
            .font(.subheadline)
        }
    }

    /// True only when the selection already covers everything select-all would
    /// add. Tested by containment rather than by count, because a selection
    /// made before a search was typed can be larger than the filtered set.
    private var isEverythingSelected: Bool {
        selection.selected.isSuperset(of: selectableIds)
    }

    private var selectAllLabel: String {
        if isEverythingSelected { return "Deselect All" }
        return isFiltered ? "Select Matches" : "Select All"
    }

    @ViewBuilder
    private var actions: some View {
        let disabled = selection.isEmpty

        if model.canBulkRetype {
            Menu {
                ForEach(BlockType.allCases) { type in
                    Button(type.label) {
                        run { await model.bulkRetype(ids, to: type) }
                    }
                }
            } label: {
                Label("Type", systemImage: "textformat.abc")
            }
            .disabled(disabled)
        }

        if model.canBulkFormat {
            Menu {
                Section("Style") {
                    ForEach(BlockTextStyle.allCases) { style in
                        Button {
                            run { await model.bulkToggleStyle(ids, style: style) }
                        } label: {
                            Label(style.label, systemImage: style.systemImage)
                        }
                    }
                }
                Section("Align") {
                    ForEach(TextAlign.allCases) { align in
                        Button {
                            run { await model.bulkSetAlign(ids, align: align) }
                        } label: {
                            Label(align.label, systemImage: align.systemImage)
                        }
                    }
                }
                Section("Font") {
                    ForEach(ScriptFont.allCases) { font in
                        Button(font.label) {
                            run { await model.bulkSetFont(ids, font: font) }
                        }
                    }
                }
                Section("Highlight") {
                    ForEach(BlockHighlight.allCases) { colour in
                        Button {
                            run { await model.bulkSetHighlight(ids, highlight: colour) }
                        } label: {
                            Label(colour.label, systemImage: "circle.fill")
                        }
                    }
                    Button("None") {
                        run { await model.bulkSetHighlight(ids, highlight: nil) }
                    }
                }
            } label: {
                Label("Format", systemImage: "paintbrush")
            }
            .disabled(disabled)
        }

        if model.canBulkTag {
            Button {
                isTagging = true
            } label: {
                Label("Tag", systemImage: "tag")
            }
            .disabled(disabled)
        }

        // Copying needs nothing from the server, so unlike everything else in
        // this bar it is offered even to a reader.
        Button {
            model.copyBlocks(selectedBlocks)
            selection.clear()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(disabled)

        if model.canBulkDelete {
            Button {
                let blocks = selectedBlocks
                isWorking = true
                Task {
                    await model.cutBlocks(blocks)
                    isWorking = false
                    selection.clear()
                }
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled(disabled)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(disabled)
        }
    }

    private var selectedBlocks: [Block] {
        let selected = Set(ids)
        return model.blocks.filter { selected.contains($0.id) }
    }

    private var ids: [Int] { selection.orderedIds(in: model.blocks) }

    private var countLabel: String {
        let count = selection.count
        guard count > 0 else { return "Select elements" }
        return "\(count) " + (count == 1 ? "element" : "elements")
    }

    /// Runs a bulk action, and clears the selection once it lands — leaving a
    /// stale selection highlighted after the script changed underneath it
    /// invites applying the next action to the wrong set.
    private func run(_ action: @escaping () async -> Bool) {
        guard !ids.isEmpty else { return }
        isWorking = true
        Task {
            let succeeded = await action()
            isWorking = false
            if succeeded { selection.clear() }
        }
    }
}
