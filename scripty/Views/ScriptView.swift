//
//  ScriptView.swift
//  scripty
//
//  The screenplay page for one project. Editable elements are typed into
//  directly — Return, Backspace and Tab split, merge and retype the way the
//  web editor does — so writing is continuous rather than one block at a
//  time. Every affordance is still gated by the links the server advertised.
//

import SwiftUI

struct ScriptView: View {
    @State private var model: ScriptModel
    @State private var showingCharacters = false
    @State private var showingSongs = false
    @State private var showingTitlePage = false
    @State private var showingOutline = false
    @State private var showingStats = false
    @State private var isSearching = false
    @State private var showingRead = false
    @State private var showingPageSetup = false
    @State private var showingVersions = false
    /// Presented from the link the block collection advertised.
    @State private var trashLink: HALLink?
    @State private var showingEditions = false
    /// The element whose comment thread is open, if any.
    @State private var commentTarget: Block?
    @State private var activityLink: HALLink?
    @State private var editions: EditionsModel
    @State private var navigator = ScriptNavigator()
    @State private var search = ScriptSearchModel()
    @State private var selection = BlockSelectionModel()

    /// Presentation is a device preference shared across every project, so the
    /// model is the app-wide one rather than one per script.
    private let settings = PresentationSettings.shared

    /// Pagination is recomputed when the script or the paper changes rather
    /// than on every redraw — it walks the whole script.
    @State private var pages: [ScriptPage] = []
    @State private var currentPage = 1

    init(app: AppModel, project: Project) {
        _model = State(initialValue: ScriptModel(app: app, project: project))
        _editions = State(initialValue: EditionsModel(app: app, project: project))
    }

    var body: some View {
        Group {
            if settings.isPageView {
                pageView
            } else {
                editor
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable {
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            await model.loadEverything()
            model.startSyncPolling()
            repaginate()
            // Loaded quietly: most projects have a single edition and should
            // show no sign of the feature at all.
            await editions.load()
        }
        .onDisappear { model.stopSyncPolling() }
        .onChange(of: model.blocks) { _, _ in repaginate() }
        .onChange(of: settings.pageSetup) { _, _ in repaginate() }
        .sheet(isPresented: $showingRead) {
            ReadScriptView(
                title: model.project.displayTitle,
                blocks: model.blocks,
                textScale: settings.textScale)
        }
        .sheet(isPresented: $showingPageSetup) {
            PageSetupSheet(settings: settings)
        }
        .sheet(item: $trashLink) { link in
            TrashView<DeletedBlock, DeletedBlockRow>(
                app: model.app,
                source: link,
                title: "Deleted Elements",
                emptyMessage: "Elements you delete can be restored from here.",
                // A restored element rejoins the script behind us.
                onChanged: {
                    await model.loadBlocks()
                    await model.refreshUndoRedo()
                    repaginate()
                }) { block in
                    DeletedBlockRow(block: block)
                }
        }
        .sheet(item: $activityLink) { link in
            ActivityView(app: model.app, source: link)
        }
        .sheet(item: $commentTarget) { block in
            // Presented from the link the block advertised, so the thread
            // cannot open for an element the server never offered one for.
            if let source = block.link(.comments) {
                CommentsView(app: model.app, block: block, source: source)
            }
        }
        .sheet(isPresented: $showingEditions) {
            EditionsView(model: editions) { edition in
                // The choice travels as the link the server gave for that
                // edition; changing it reloads the script.
                model.editionBlocksLink = editions.blocksLink(for: edition)
                await model.refreshUndoRedo()
                repaginate()
            }
        }
        .sheet(isPresented: $showingVersions) {
            VersionHistoryView(app: model.app, project: model.project) {
                // A restore rewrites the script, so reload rather than trusting
                // what is on screen.
                await model.loadBlocks()
                await model.refreshUndoRedo()
                repaginate()
            }
        }
        .sheet(isPresented: $showingCharacters) {
            CharactersView(model: model)
        }
        .sheet(isPresented: $showingSongs) {
            SongsView(model: model)
        }
        .sheet(isPresented: $showingTitlePage) {
            TitlePageView(app: model.app, project: model.project) { updated in
                model.adopt(updated)
            }
        }
        .sheet(isPresented: $showingOutline) {
            ScriptOutlineView(model: model, navigator: navigator)
        }
        .sheet(isPresented: $showingStats) {
            ScriptStatsView(model: model)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Names the edition only when it is not the default one — a writer who
    /// has moved off the main draft should be able to see that, and everyone
    /// else should not have to read about it.
    private var navigationTitle: String {
        let title = model.project.displayTitle
        guard let edition = editions.selected, !edition.isTheDefault else { return title }
        return "\(title) · \(edition.displayName)"
    }

    /// The writing surface: one continuous column you type into.
    private var editor: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.blocks) { block in
                        row(for: block)
                            .padding(.horizontal, 24)
                            .id(block.id)
                    }
                }
                .padding(.vertical, 12)
                // Focus mode pulls the column in to a single measure and
                // drops the surrounding chrome, as the web app does.
                .frame(maxWidth: settings.isFocusMode ? 720 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: navigator.pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                // Clearing the target is what lets the same block be jumped
                // to twice in a row.
                navigator.consumeScrollTarget()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { editingBars }
        .safeAreaInset(edge: .bottom) { searchBar }
        .safeAreaInset(edge: .bottom) { bulkBar }
        .environment(\.scriptTextScale, settings.textScale)
    }

    @ViewBuilder
    private var bulkBar: some View {
        if selection.isSelecting {
            BulkActionBar(model: model, selection: selection)
        }
    }

    /// The paper surface: read-only sheets with a pager.
    private var pageView: some View {
        ScrollViewReader { proxy in
            ScreenplayPageView(
                pages: pages,
                setup: settings.pageSetup,
                zoomScale: settings.zoomScale,
                onVisiblePageChanged: { currentPage = $0 })
            .overlay(alignment: .bottom) {
                if pages.count > 0 {
                    PageNavigatorBar(
                        settings: settings,
                        pageCount: pages.count,
                        currentPage: $currentPage) { page in
                            withAnimation { proxy.scrollTo(page, anchor: .top) }
                        }
                }
            }
            .overlay { pageEmptyState }
        }
    }

    @ViewBuilder
    private var pageEmptyState: some View {
        if pages.isEmpty {
            ContentUnavailableView(
                "Nothing to Paginate",
                systemImage: "doc.richtext",
                description: Text("This script has no elements yet."))
        }
    }

    /// Pagination walks the whole script, so it is only worth doing while the
    /// pages are actually on screen — in the editor the writer is typing and
    /// nothing would read the result.
    private func repaginate() {
        guard settings.isPageView else { return }
        pages = ScriptPagination.paginate(blocks: model.blocks, setup: settings.pageSetup)
        currentPage = min(max(1, currentPage), max(1, pages.count))
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        if selection.isSelecting {
            SelectableBlockRow(block: block, isSelected: selection.isSelected(block.id)) {
                selection.toggle(block.id)
            }
        } else if block.isEditable {
            EditableBlockRow(model: model, block: block) { commented in
                commentTarget = commented
            }
        } else {
            BlockRowView(block: block)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.blocks.isEmpty {
            if model.isLoading {
                ProgressView()
            } else if model.canSeedScript {
                ContentUnavailableView {
                    Label("Empty Script", systemImage: "doc.plaintext")
                } description: {
                    Text("Start writing to add the first element.")
                } actions: {
                    Button("Start Writing") {
                        Task { await model.seedInitialBlock() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Empty Script",
                    systemImage: "doc.plaintext",
                    description: Text("This script has no elements yet."))
            }
        }
    }

    /// Formatting sits above the element-type bar, both only while a block is
    /// focused and only for the affordances the server actually advertised.
    @ViewBuilder
    private var editingBars: some View {
        // Selection mode has its own bar, and nothing is focused for typing.
        if !selection.isSelecting,
           let id = model.focusedBlockId,
           let block = model.blocks.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                if block.hasLink(.update) {
                    FormatBar(model: model, block: block)
                    Divider()
                }
                if block.hasLink(.setType) {
                    ElementTypeBar(model: model, block: block)
                }
            }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if isSearching {
            ScriptSearchBar(model: model, navigator: navigator, search: search) {
                isSearching = false
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // The View menu stays put in focus mode — it is the way back out.
            viewMenu

            if !settings.isPageView {
                Button {
                    Task { await model.appendBlock() }
                } label: {
                    Label("Add Element", systemImage: "plus")
                }
            }

            if model.hasScriptContent && !settings.isFocusMode {
                Button {
                    isSearching.toggle()
                    if !isSearching { search.clear() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)

                Button {
                    showingOutline = true
                } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                if model.canSelectBlocks && !settings.isPageView {
                    Button {
                        selection.isSelecting.toggle()
                    } label: {
                        Label("Select Elements", systemImage: "checklist")
                    }
                }
            }

            if model.canViewCharacters && !settings.isFocusMode {
                Button {
                    showingCharacters = true
                } label: {
                    Label("Characters", systemImage: "person.2")
                }
            }

            if model.canViewDocuments && !settings.isFocusMode {
                Button {
                    showingSongs = true
                } label: {
                    Label("Songs & Notes", systemImage: "music.note.list")
                }
            }

            if !model.exportOptions.isEmpty && !settings.isFocusMode {
                ExportButton(model: model)
            }
        }

        // Front matter, import and stats are occasional actions — they live in
        // the overflow so the writing controls stay reachable on iPhone width.
        // Focus mode clears the overflow out entirely.
        if !settings.isFocusMode {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    showingTitlePage = true
                } label: {
                    Label("Title Page", systemImage: "doc.text")
                }

                if model.hasScriptContent {
                    Button {
                        showingStats = true
                    } label: {
                        Label("Script Stats", systemImage: "chart.bar")
                    }
                }

                // Only worth surfacing once there is more than one edition, or
                // the writer can make one. A single-edition project should show
                // no sign of the feature.
                if editions.hasChoice || editions.canCreate {
                    Button {
                        showingEditions = true
                    } label: {
                        Label("Editions", systemImage: "doc.on.doc")
                    }
                }

                if model.project.hasLink(.versions) {
                    Button {
                        showingVersions = true
                    } label: {
                        Label("Version History", systemImage: "clock.arrow.circlepath")
                    }
                }

                if let activity = model.project.link(.activity) {
                    Button {
                        activityLink = activity
                    } label: {
                        Label("Recent Activity", systemImage: "clock")
                    }
                }

                if let trash = model.blocksLinks[.trash] {
                    Button {
                        trashLink = trash
                    } label: {
                        Label("Deleted Elements", systemImage: "trash")
                    }
                }

                ScriptImportButton(app: model.app, project: model.project) { updated in
                    model.adopt(updated)
                    await model.loadBlocks()
                    await model.refreshUndoRedo()
                }
            }
        }

        if let undoRedo = model.undoRedo, !settings.isPageView {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    Task { await model.undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!(undoRedo.canUndo ?? false))

                Button {
                    Task { await model.redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!(undoRedo.canRedo ?? false))
            }
        }
    }

    /// How the script is presented, gathered into one menu the way the web
    /// editor gathers them under View.
    private var viewMenu: some View {
        Menu {
            Section {
                Toggle(isOn: pageViewBinding) {
                    Label("Page View", systemImage: "doc.richtext")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Toggle(isOn: focusModeBinding) {
                    Label("Focus Mode", systemImage: "moon")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    showingRead = true
                } label: {
                    Label("Read Script", systemImage: "book")
                }
                .disabled(!model.hasScriptContent)
            }

            Section("Text Size") {
                Button {
                    settings.increaseTextSize()
                } label: {
                    Label("Bigger", systemImage: "textformat.size.larger")
                }
                .disabled(!settings.canIncreaseTextSize)
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    settings.decreaseTextSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!settings.canDecreaseTextSize)
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    settings.resetTextSize()
                } label: {
                    Label("Actual Size (\(settings.textSize)%)", systemImage: "textformat")
                }
                .disabled(settings.textSize == PresentationSettings.defaultTextSize)
            }

            Section {
                Button {
                    showingPageSetup = true
                } label: {
                    Label("Page Setup…", systemImage: "ruler")
                }
            }
        } label: {
            Label("View", systemImage: "eye")
        }
    }

    private var pageViewBinding: Binding<Bool> {
        Binding(get: { settings.isPageView }, set: { settings.isPageView = $0 })
    }

    private var focusModeBinding: Binding<Bool> {
        Binding(get: { settings.isFocusMode }, set: { settings.isFocusMode = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
