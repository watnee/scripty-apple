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
                .contentTransition(.symbolEffect(.replace))
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
        .animation(.snappy(duration: 0.15), value: isSelected)
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

    /// Whether this is a phone-shaped width, decided by the host.
    ///
    /// Not `@Environment(\.horizontalSizeClass)`: inside a `NavigationSplitView`
    /// column that reads `.compact` even on a full-width iPad, which is why
    /// every other surface in the app threads this down by hand. Read from the
    /// environment, this bar drew the stacked phone layout on every iPad there
    /// has ever been, and `regularBar` below was unreachable code.
    let isCompact: Bool

    @State private var isTagging = false
    @State private var tagText = ""
    @State private var confirmDelete = false
    @State private var isWorking = false

    var body: some View {
        // A phone cannot hold the count, six actions and Done on one line —
        // squeezed that far, every label wraps to letter fragments — so
        // compact widths split the bar in two: what is selected on top, what
        // can be done to it below. Regular widths keep the web toolbar's
        // single labelled row.
        Group {
            if isCompact {
                compactBar
            } else {
                regularBar
            }
        }
        // No background of its own: the host mounts it with `.safeAreaBar`,
        // which supplies the Liquid Glass and the separation from the script.
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

    /// Count and mode controls above, actions below. The actions drop their
    /// titles — six icons share a phone's width evenly, the way a toolbar
    /// spreads its items — and each `Label` keeps its title for VoiceOver.
    private var compactBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                countText
                selectAllButton
                Spacer(minLength: 8)
                doneButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(spacing: 0) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Group { actions }
                        .frame(maxWidth: .infinity)
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 2)
    }

    /// The one-line form: everything the compact bar shows, side by side.
    ///
    /// Regular width is not the same as room: with the sidebar open, an iPad's
    /// script pane can be too narrow for six titled actions, and the titles
    /// wrap to fragments. So the titled row is offered first and the icon-only
    /// row stands in wherever it will not fit.
    ///
    /// The stacked layout is the last resort rather than the phone's alone. A
    /// two-column split on the narrow side leaves a pane that will not hold
    /// even six icons, a count and Done on one line, and `ViewThatFits` takes
    /// its final candidate whether it fits or not — so without this the bar
    /// would run off the edge of its own pane rather than fall back to the
    /// arrangement that was built for exactly that much room.
    private var regularBar: some View {
        ViewThatFits(in: .horizontal) {
            regularRow(iconOnly: false)
            regularRow(iconOnly: true)
            compactBar
        }
    }

    private func regularRow(iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            countText
            selectAllButton

            Spacer(minLength: 12)

            if isWorking {
                ProgressView().controlSize(.small)
            } else if iconOnly {
                HStack(spacing: 22) { actions }
                    .labelStyle(.iconOnly)
                    .font(.title3)
            } else {
                HStack(spacing: 12) { actions }
                    .fixedSize()
            }

            doneButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countText: some View {
        Text(countLabel)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: selection.count)
            .foregroundStyle(selection.isEmpty ? .secondary : .primary)
            .lineLimit(1)
    }

    private var doneButton: some View {
        Button("Done") {
            selection.isSelecting = false
        }
        .font(.body.weight(.medium))
        .fixedSize()
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
            .lineLimit(1)
            .fixedSize()
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
                    // Named for the same reason the format bar names it: this
                    // clears the override, and what the elements fall back to
                    // is the writer's own choice in Editor Preferences.
                    Button("Default (\(PresentationSettings.shared.defaultFont.label))") {
                        run { await model.bulkClearFont(ids) }
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
