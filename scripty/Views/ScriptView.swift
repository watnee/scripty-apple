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
    @State private var showingTitlePage = false
    /// The outline sheet, presented *by* the list it should open on — ⌘⇧C,
    /// ⌘⇧A and ⌘⇧M each name a different one. Deliberately `.sheet(item:)`
    /// rather than a bool plus a separate tab: with `isPresented` the content
    /// closure is built from the body snapshot taken before the tab change
    /// propagates, so every shortcut opened the sheet on whichever list it was
    /// showing last.
    @State private var outlineSheet: ScriptOutlineView.Tab?
    /// Songs & Notes, presented by its list for the same reason (⌘⇧S / ⌘⇧D).
    @State private var songsSheet: DocumentType?
    @State private var showingStats = false
    @State private var showingShortcuts = false
    @State private var isSearching = false
    @State private var showingRead = false
    /// Raised by ⌘⇧I and read by the import button's picker binding.
    @State private var importRequest = false
    /// A keyboard export in flight, and its finished file.
    ///
    /// Run here rather than by the export menu itself: that lives in a
    /// `ToolbarItemGroup`, where an `.onChange` is not reliably evaluated, so
    /// a trigger handed to it was simply never seen. The menu keeps its own
    /// copy of this flow for taps; this is the keyboard's way in.
    @State private var exportedFile: ExportButton.ExportedFile?
    @State private var showingPageSetup = false
    @State private var showingVersions = false
    /// Presented from the link the block collection advertised.
    @State private var trashLink: HALLink?
    @State private var showingEditions = false
    /// The element whose comment thread is open, if any.
    @State private var commentTarget: Block?
    @State private var activityLink: HALLink?
    /// Only present when the server has invitations over the API turned on.
    @State private var shareLink: HALLink?
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
        .safeAreaInset(edge: .top, spacing: 0) { editionBanner }
        // Behind the page rather than in the toolbar: a shortcut has to keep
        // working when the control it mirrors is hidden by focus mode or
        // dropped at phone width.
        .background { ScriptShortcutLayer(isEnabled: isEnabled, perform: perform) }
        .preferredColorScheme(settings.appearance.colorScheme)
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable {
            await model.loadBlocks()
            await model.refreshUndoRedo()
        }
        .task {
            // Loaded before the blocks so the first element a writer touches
            // already knows whether it types in capitals. `load()` is a no-op
            // once it has answered, so opening a second script costs nothing.
            await model.app.capitalization.load()
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
        // Pagination is skipped while the editor is up, so switching into page
        // view is the first point at which it can be computed. Today the mode
        // switch changes this view's identity and re-runs the .task above,
        // which happens to repaginate — but that is incidental, and the sheets
        // would come up empty if the Group were ever restructured.
        .onChange(of: settings.isPageView) { _, _ in repaginate() }
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
        .sheet(item: $shareLink) { link in
            ShareView(app: model.app, source: link,
                      projectTitle: model.project.displayTitle)
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
        .sheet(item: $songsSheet) { listType in
            SongsView(model: model, listType: listType)
        }
        .sheet(isPresented: $showingShortcuts) {
            ShortcutsReferenceView(isEnabled: isEnabled)
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showingTitlePage) {
            TitlePageView(app: model.app, project: model.project) { updated in
                model.adopt(updated)
            }
        }
        .sheet(item: $outlineSheet) { tab in
            ScriptOutlineView(model: model, navigator: navigator, tab: tab)
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

    // MARK: - Keyboard shortcuts

    /// The element the caret is in, which is what the format, element-type and
    /// reordering shortcuts act on. Nil while nothing is focused — the same
    /// rule the web app applies, where those keys need "an active block".
    private var focusedBlock: Block? {
        guard let id = model.focusedBlockId else { return nil }
        return model.blocks.first { $0.id == id }
    }

    /// Whether the page can act on a shortcut right now.
    ///
    /// Shared with the reference sheet, so what is greyed out there is exactly
    /// what is inert here — and doing the gating once means a shortcut cannot
    /// be listed as working while quietly doing nothing.
    private func isEnabled(_ action: ScriptShortcutAction) -> Bool {
        switch action {
        case .undo: return model.undoRedo?.canUndo ?? false
        case .redo: return model.undoRedo?.canRedo ?? false

        case .search, .findReplace:
            return model.hasScriptContent
        case .nextMatch, .previousMatch:
            return isSearching && search.hasMatches
        case .focusMode, .pageView:
            return true
        case .readScript:
            return model.hasScriptContent
        case .wordCount, .elementLabels:
            return true
        case .outline(let tab):
            // Songs and characters have their own sheets elsewhere, but every
            // outline tab is derived from the blocks we already hold.
            return tab == .outline ? true : model.hasScriptContent
        case .documents:
            return model.canViewDocuments
        case .shortcutsReference:
            return true

        case .titlePage:
            // Not focus-gated: the sheet hangs off this view, not off the
            // overflow menu, so it opens fine with the chrome cleared away.
            return true
        case .versionHistory:
            return model.project.hasLink(.versions)
        case .importFile:
            // The button that owns the picker is in the overflow menu, which
            // focus mode clears out along with everything else.
            return model.project.hasLink(.importScript) && !settings.isFocusMode
        case .printScript:
            return model.printOption != nil
        case .export(let rel):
            // Likewise: ScriptView runs keyboard exports itself and presents
            // its own share sheet, so focus mode does not take them away.
            return model.exportOptions.contains { $0.rel == rel }

        case .biggerText: return settings.canIncreaseTextSize
        case .smallerText: return settings.canDecreaseTextSize

        case .bold, .italic, .underline, .align:
            return focusedBlock?.hasLink(.update) ?? false
        case .setType:
            return focusedBlock?.hasLink(.setType) ?? false
        case .moveUp:
            return focusedBlock.map { model.canMoveUp($0) } ?? false
        case .moveDown:
            return focusedBlock.map { model.canMoveDown($0) } ?? false
        }
    }

    private func perform(_ action: ScriptShortcutAction) {
        switch action {
        case .undo: Task { await model.undo() }
        case .redo: Task { await model.redo() }

        case .search:
            isSearching = true
        case .findReplace:
            isSearching = true
            search.isReplacing = true
        case .nextMatch:
            if let match = search.next() { navigator.jump(to: match.blockId) }
        case .previousMatch:
            if let match = search.previous() { navigator.jump(to: match.blockId) }

        case .focusMode: settings.isFocusMode.toggle()
        case .pageView: settings.isPageView.toggle()
        case .readScript: showingRead = true
        case .wordCount: settings.showsWordCount.toggle()
        case .elementLabels: settings.showsElementLabels.toggle()
        case .outline(let tab):
            outlineSheet = tab
        case .documents(let kind):
            songsSheet = kind
        case .shortcutsReference:
            showingShortcuts = true

        case .titlePage: showingTitlePage = true
        case .versionHistory: showingVersions = true
        case .importFile: importRequest = true
        case .printScript: printScript()
        case .export(let rel): exportFromKeyboard(rel)

        case .biggerText: settings.increaseTextSize()
        case .smallerText: settings.decreaseTextSize()

        // Formatting and retyping act on the focused element and leave the
        // caret where it was, so a writer can bold a word mid-sentence and
        // keep typing — the reason these are worth having on the keyboard.
        case .bold:
            withFocusedBlock { await model.toggleBold($0) }
        case .italic:
            withFocusedBlock { await model.toggleItalic($0) }
        case .underline:
            withFocusedBlock { await model.toggleUnderline($0) }
        case .align(let align):
            withFocusedBlock { await model.setAlign($0, to: align) }
        case .setType(let type):
            withFocusedBlock { await model.changeType($0, to: type) }
        case .moveUp:
            withFocusedBlock { await model.moveBlockUp($0) }
        case .moveDown:
            withFocusedBlock { await model.moveBlockDown($0) }
        }
    }

    /// Downloads one export format and hands the file to a share sheet — the
    /// same thing tapping the format in the export menu does.
    private func exportFromKeyboard(_ rel: Rel) {
        guard let option = model.exportOptions.first(where: { $0.rel == rel }) else { return }
        Task {
            do {
                exportedFile = ExportButton.ExportedFile(url: try await model.export(option))
            } catch {
                // Reported through the page's own error alert rather than a
                // second one: a view may carry only one `.alert`, and adding
                // another silently stopped every sheet on this page from
                // presenting at all — including from the toolbar.
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Downloads the PDF export and opens the system print panel on it.
    private func printScript() {
        guard let option = model.printOption else { return }
        Task {
            do {
                let url = try await model.export(option)
                ScriptPrinter.present(pdf: url, jobName: model.project.displayTitle)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs `body` against whatever holds the caret, or does nothing. Read at
    /// the moment the key is pressed rather than captured earlier, since focus
    /// moves while a shortcut's own work is still in flight.
    private func withFocusedBlock(_ body: @escaping (Block) async -> Void) {
        guard let block = focusedBlock else { return }
        Task { await body(block) }
    }

    /// Says which edition is open, but only when it is not the default one.
    ///
    /// This started as a suffix on the navigation title and did not survive
    /// contact with an iPad: an inline title shares the bar with eight toolbar
    /// icons, so the edition name — the part that mattered — was the part that
    /// got truncated. A banner has room for the whole name, and being harder to
    /// miss is the point rather than a side effect: a writer who does not
    /// notice they are typing into a revision instead of the shooting draft has
    /// a worse afternoon than one who reads a line of text.
    @ViewBuilder
    private var editionBanner: some View {
        if let edition = editions.selected, !edition.isTheDefault {
            Button {
                showingEditions = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                    Text("Editing")
                        .foregroundStyle(.secondary)
                    Text(edition.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if edition.isThePublished {
                        Text("Published")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(.tint.opacity(0.10))
                .overlay(alignment: .bottom) {
                    // An explicit rule rather than a Divider: Divider takes its
                    // orientation from the surrounding layout, and inside this
                    // overlay it came out vertical — a stray line down the
                    // middle of the banner.
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editing the \(edition.displayName) edition. Change edition.")
        }
    }

    /// The writing surface: one continuous column you type into.
    private var editor: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.blocks) { block in
                        row(for: block)
                            .padding(.horizontal, 24)
                            // Labels live in a gutter of their own. Widening
                            // the leading inset shifts the column across but
                            // does not change its width, so the lines break
                            // in exactly the same places with labels on.
                            .padding(.leading, settings.showsElementLabels ? 44 : 0)
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
        .safeAreaInset(edge: .bottom) { wordCountBar }
        .safeAreaInset(edge: .bottom) { editingBars }
        .safeAreaInset(edge: .bottom) { searchBar }
        .safeAreaInset(edge: .bottom) { bulkBar }
        .environment(\.scriptTextScale, settings.textScale)
    }

    /// A running word count, when asked for.
    ///
    /// Off by default and deliberately plain: a number that moves while you
    /// write is either useful or a distraction depending on the writer, which
    /// is exactly why the web app makes it a toggle rather than a fixture.
    @ViewBuilder
    private var wordCountBar: some View {
        if settings.showsWordCount && !selection.isSelecting {
            let count = model.liveWordCount
            Text("^[\(count) word](inflect: true)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(.bar)
                .accessibilityLabel("\(count) words in the screenplay")
        }
    }

    @ViewBuilder
    private var bulkBar: some View {
        if selection.isSelecting {
            BulkActionBar(model: model,
                          selection: selection,
                          selectableIds: selectableIds,
                          isFiltered: isSearchNarrowingSelection)
        }
    }

    /// A live search narrows what select-all means, matching the web app,
    /// where selecting all while filtered selects only the rows on screen.
    private var isSearchNarrowingSelection: Bool {
        isSearching && search.hasQuery && search.hasMatches
    }

    /// Selecting all reaches the search hits while a search is running and the
    /// whole script otherwise. A query that matches nothing deliberately
    /// leaves the set empty rather than silently selecting everything.
    private var selectableIds: [Int] {
        guard isSearching && search.hasQuery else { return model.blocks.map(\.id) }
        let hits = Set(search.matches.map(\.blockId))
        return model.blocks.map(\.id).filter { hits.contains($0) }
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
            .blockReorderDrag(block, in: model)
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
                // Above the format bar, so it sits nearest the keyboard and
                // nearest the text it completes.
                let suggestions = model.suggestions
                if !suggestions.isEmpty {
                    AutocompleteBar(suggestions: suggestions) { model.accept($0) }
                    Divider()
                }
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

                Button {
                    outlineSheet = .outline
                } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                }

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
                    songsSheet = .song
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

                if let share = model.project.link(.invitations) {
                    Button {
                        shareLink = share
                    } label: {
                        Label("Share", systemImage: "person.badge.plus")
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

                ScriptImportButton(app: model.app, project: model.project,
                                   trigger: $importRequest) { updated in
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

                Toggle(isOn: focusModeBinding) {
                    Label("Focus Mode", systemImage: "moon")
                }

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

                Button {
                    settings.decreaseTextSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!settings.canDecreaseTextSize)

                Button {
                    settings.resetTextSize()
                } label: {
                    Label("Actual Size (\(settings.textSize)%)", systemImage: "textformat")
                }
                .disabled(settings.textSize == PresentationSettings.defaultTextSize)
            }

            Section {
                Toggle(isOn: wordCountBinding) {
                    Label("Word Count", systemImage: "textformat.123")
                }

                Toggle(isOn: elementLabelsBinding) {
                    Label("Element Labels", systemImage: "tag")
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(PresentationSettings.Appearance.allCases) { option in
                        Label(option.label, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                Button {
                    showingPageSetup = true
                } label: {
                    Label("Page Setup…", systemImage: "ruler")
                }

                // The shortcuts have their own shortcut, but a writer who does
                // not know the shortcuts cannot be expected to know that one.
                Button {
                    showingShortcuts = true
                } label: {
                    Label("Keyboard Shortcuts", systemImage: "keyboard")
                }
            }
        } label: {
            Label("View", systemImage: "eye")
        }
    }

    private var pageViewBinding: Binding<Bool> {
        Binding(get: { settings.isPageView }, set: { settings.isPageView = $0 })
    }

    private var wordCountBinding: Binding<Bool> {
        Binding(get: { settings.showsWordCount }, set: { settings.showsWordCount = $0 })
    }

    private var elementLabelsBinding: Binding<Bool> {
        Binding(get: { settings.showsElementLabels },
                set: { settings.showsElementLabels = $0 })
    }

    private var appearanceBinding: Binding<PresentationSettings.Appearance> {
        Binding(get: { settings.appearance }, set: { settings.appearance = $0 })
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
