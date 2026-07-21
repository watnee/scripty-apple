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
    /// The sheet holds two things — who can already see the screenplay, and the
    /// invitations — and either one alone is worth opening it for. Inviting is
    /// only offered where the server has invitations over the API turned on.
    @State private var showingShare = false
    @State private var editions: EditionsModel
    @State private var exporter: ScriptExportModel
    @State private var navigator = ScriptNavigator()
    @State private var search = ScriptSearchModel()
    @State private var selection = BlockSelectionModel()

    /// Presentation is a device preference shared across every project, so the
    /// model is the app-wide one rather than one per script.
    private let settings = PresentationSettings.shared

    /// What this script shows and whether it can be typed into. Per project
    /// rather than shared, so marking up one draft leaves the others alone.
    @State private var options: ScriptViewOptions

    /// How much room the writing column actually has, for full-width mode.
    /// Zero until the first layout, which reads as "use the printed measure".
    @State private var availableWidth: CGFloat = 0

    /// Pagination is recomputed when the script or the paper changes rather
    /// than on every redraw — it walks the whole script.
    @State private var pages: [ScriptPage] = []
    @State private var currentPage = 1

    init(app: AppModel, project: Project) {
        let model = ScriptModel(app: app, project: project)
        _model = State(initialValue: model)
        _editions = State(initialValue: EditionsModel(app: app, project: project))
        _exporter = State(initialValue: ScriptExportModel(model: model))
        _options = State(initialValue: ScriptViewOptions(projectId: project.id))
    }

    var body: some View {
        Group {
            if settings.isPageView {
                pageView
            } else {
                editor
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                unsavedBanner
                editionBanner
            }
        }
        .navigationTitle(model.project.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .exportPresentation(exporter)
        .focusedSceneValue(\.scriptActions, menuActions)
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
        // Hidden notes are hidden on paper too — otherwise the page count in
        // the navigator disagrees with the script on screen.
        .onChange(of: options.showsNotes) { _, _ in repaginate() }
        // The editing lock is per edition, so it has to follow the switch.
        .onChange(of: editions.selectedId) { _, id in options.editionId = id }
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
        .sheet(isPresented: $showingShare) {
            ShareView(app: model.app,
                      source: model.project.link(.invitations),
                      contactsSource: model.project.link(.contactSuggestions),
                      accessSource: model.project.link(.access),
                      projectTitle: model.project.displayTitle)
        }
        .sheet(item: $commentTarget, onDismiss: {
            // The thread may have gained or lost comments, so repaint the
            // badge. Only the counts — reloading the script would throw away
            // whatever the writer has typed since.
            Task { await model.loadCommentCounts() }
        }) { block in
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
            // Presented from the link the project advertised, so the sheet
            // cannot open for a project the server keeps no history for.
            if let versions = model.project.link(.versions) {
                VersionHistoryView(app: model.app, source: versions, subject: "script") {
                    // A restore rewrites the script, so reload rather than
                    // trusting what is on screen.
                    await model.loadBlocks()
                    await model.refreshUndoRedo()
                    repaginate()
                }
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

    /// Standing notice that some of what is on screen only exists on this
    /// device. It replaces the alert that a dropped connection used to throw
    /// up on every keystroke: the writing is safe and a retry is already in
    /// flight, so the honest thing to do is say so quietly and keep out of the
    /// way rather than demand a tap before the next word can be typed.
    @ViewBuilder
    private var unsavedBanner: some View {
        if model.hasUnsavedChanges {
            let count = model.unsavedBlockIds.count
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption)
                Text("Not saved yet")
                    .fontWeight(.medium)
                Text("· \(count) " + (count == 1 ? "element" : "elements")
                     + " kept on this device")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(count) " + (count == 1 ? "element is" : "elements are")
                + " not saved to the server yet. Your work is kept on this device "
                + "and will be saved when the connection returns.")
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.snappy(duration: 0.2), value: count)
        }
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
                    ForEach(visibleBlocks) { block in
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { editingBars }
        .safeAreaInset(edge: .bottom) { searchBar }
        .safeAreaInset(edge: .bottom) { bulkBar }
        .environment(\.scriptTextScale, settings.textScale)
        .environment(\.scriptRowChrome, rowChrome)
    }

    /// The elements the writer has asked to see. Notes are the only thing that
    /// can be hidden — they are annotations on the script rather than part of
    /// it, which is exactly why the web offers to take them off the page.
    private var visibleBlocks: [Block] {
        guard !options.showsNotes else { return model.blocks }
        return model.blocks.filter { $0.blockType != .note }
    }

    /// What the rows should draw, gathered from the project's view options and
    /// the room the window has.
    private var rowChrome: ScriptRowChrome {
        var chrome = ScriptRowChrome()
        chrome.showsPins = options.showsPins
        chrome.showsBookmarks = options.showsBookmarks
        chrome.showsElementLabels = options.showsElementLabels
        guard availableWidth > 0 else { return chrome }
        // Each row is padded by 24 either side, so that much of the window was
        // never the column's to use.
        let usable = availableWidth - 48

        // The badges sit in the margin beyond the column, so full width leaves
        // them room rather than running the text underneath them.
        if settings.isFullWidth {
            chrome.columnWidth = max(320, usable - 48)
            chrome.isFullWidth = true
        }
        // The labels hang off the left of the column, so the column gives up
        // the room when the window has none to spare — without this they print
        // straight over the scene headings, which start at the margin.
        if options.showsElementLabels {
            let margin = (usable - chrome.columnWidth) / 2
            if margin < ElementLabelTag.gutter {
                chrome.columnWidth = max(280, usable - 2 * ElementLabelTag.gutter)
            }
        }
        return chrome
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
        // Hidden notes are off the table too: selecting all should never reach
        // an element the writer cannot see.
        guard isSearching && search.hasQuery else { return visibleBlocks.map(\.id) }
        let hits = Set(search.matches.map(\.blockId))
        return visibleBlocks.map(\.id).filter { hits.contains($0) }
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
        pages = ScriptPagination.paginate(blocks: visibleBlocks, setup: settings.pageSetup)
        currentPage = min(max(1, currentPage), max(1, pages.count))
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        if selection.isSelecting {
            SelectableBlockRow(block: block, isSelected: selection.isSelected(block.id)) {
                selection.toggle(block.id)
            }
            .blockReorderDrag(block, in: model)
        } else if block.isEditable && !options.isEditingLocked {
            EditableBlockRow(model: model, block: block) { commented in
                commentTarget = commented
            }
        } else {
            BlockRowView(block: block, commentCount: model.commentCount(for: block))
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
        // A locked script has no text view to act on either — the last focused
        // id outlives the lock, so it has to be checked rather than trusted.
        if !selection.isSelecting, !options.isEditingLocked,
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

    /// What this script offers the menu bar.
    ///
    /// Gated the same way the toolbar is: an action is nil when the server
    /// never advertised the link behind it, or when there is no script yet to
    /// act on, and the menu item goes grey rather than failing on click.
    private var menuActions: ScriptActions {
        var actions = ScriptActions(title: model.project.displayTitle)

        actions.canUndo = model.undoRedo?.canUndo ?? false
        actions.canRedo = model.undoRedo?.canRedo ?? false
        actions.undo = { Task { await model.undo() } }
        actions.redo = { Task { await model.redo() } }

        if !options.isEditingLocked {
            actions.addElement = { Task { await model.appendBlock() } }
        }
        actions.titlePage = { showingTitlePage = true }
        actions.pageSetup = { showingPageSetup = true }
        actions.exporter = model.exportOptions.isEmpty ? nil : exporter

        if let focused = model.blocks.first(where: { $0.id == model.focusedBlockId }) {
            actions.focusedType = focused.blockType
            if focused.isEditable && !options.isEditingLocked {
                actions.setType = { type in
                    Task { await model.changeType(focused, to: type) }
                }
            }
        }

        if model.hasScriptContent {
            actions.find = {
                isSearching = true
            }
            actions.outline = { showingOutline = true }
            actions.stats = { showingStats = true }
            actions.readScript = { showingRead = true }
        }

        if model.project.hasLink(.versions) {
            actions.versions = { showingVersions = true }
        }

        return actions
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // The View menu stays put in focus mode — it is the way back out.
            viewMenu

            if !settings.isPageView && !options.isEditingLocked {
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
                ExportButton(exporter: exporter)
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

                if model.project.hasLink(.invitations) || model.project.hasLink(.access) {
                    Button {
                        showingShare = true
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

            // Only offered where it changes anything: the page view lays the
            // script out on paper, which has a width of its own.
            if !settings.isPageView {
                Section {
                    Toggle(isOn: fullWidthBinding) {
                        Label("Full Page Width", systemImage: "arrow.left.and.right")
                    }
                    .keyboardShortcut("\\", modifiers: .command)
                }
            }

            Section("Show") {
                Toggle(isOn: option(\.showsPins, set: { options.showsPins = $0 })) {
                    Label("Pins", systemImage: "pin")
                }
                Toggle(isOn: option(\.showsBookmarks, set: { options.showsBookmarks = $0 })) {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                Toggle(isOn: option(\.showsElementLabels,
                                    set: { options.showsElementLabels = $0 })) {
                    Label("Element Labels", systemImage: "tag")
                }
                Toggle(isOn: option(\.showsNotes, set: { options.showsNotes = $0 })) {
                    Label("Notes", systemImage: "note.text")
                }
            }

            // A lock is only worth offering where there is something to lock:
            // a reader who was never given editing rights has one already.
            if canEditScript {
                Section {
                    Toggle(isOn: lockBinding) {
                        Label("Lock Editing", systemImage: "lock")
                    }
                }
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

    /// Whether the server gave this writer somewhere to type. A reader is
    /// locked already, so offering them the lock would only be noise. Asks the
    /// links rather than the lock, which is a choice about this device.
    private var canEditScript: Bool {
        model.blocks.contains(where: \.isEditable) || model.canSeedScript
    }

    private var fullWidthBinding: Binding<Bool> {
        Binding(get: { settings.isFullWidth }, set: { settings.isFullWidth = $0 })
    }

    /// The lock's setter is a method rather than a property, because what it
    /// writes depends on which edition is open.
    private var lockBinding: Binding<Bool> {
        Binding(get: { options.isEditingLocked }, set: { options.setEditingLocked($0) })
    }

    /// One of the view options, as a Toggle can use it.
    private func option(_ keyPath: KeyPath<ScriptViewOptions, Bool>,
                        set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { options[keyPath: keyPath] }, set: set)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
