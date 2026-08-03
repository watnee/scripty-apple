//
//  CommentsView.swift
//  scripty
//
//  The comment thread on one screenplay element, with the element itself at the
//  top so the note has something to be about.
//
//  Commenting needs only read access — it is how a director or producer
//  contributes to a script they may not edit — so the composer appears wherever
//  the server offered it, including for readers who see no editing controls at
//  all.
//

import SwiftUI

struct CommentsView: View {
    let block: Block
    @State private var model: CommentsModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var pendingDelete: BlockComment?
    @FocusState private var composerFocused: Bool

    init(app: AppModel, block: Block, source: HALLink) {
        self.block = block
        _model = State(initialValue: CommentsModel(app: app, source: source))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                excerpt
                Divider()
                thread
                if model.canComment {
                    Divider()
                    composer
                }
            }
            .navigationTitle("Comments")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .alert("Delete Comment", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    let comment = pendingDelete
                    pendingDelete = nil
                    Task {
                        guard let comment else { return }
                        await model.delete(comment)
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        // A thread is usually two or three lines long; half a screen is enough
        // for it, and leaves the script it is about still in view. The sheet
        // takes itself to full height when the composer takes the keyboard.
        .presentationDetents([.medium, .large])
    }

    /// The element being discussed, so the thread is not floating free. Set in
    /// the script's own typeface: it is a line lifted off the page, not a title.
    private var excerpt: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tertiary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(block.blockType.label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Text(excerptText)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Opaque, not a tint: the thread scrolls underneath it, and a see
        // through header would show two conversations at once.
        .background(.regularMaterial)
    }

    private var excerptText: String {
        let content = (block.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content.isEmpty ? "Empty element" : content
    }

    @ViewBuilder
    private var thread: some View {
        if model.isEmpty {
            Spacer(minLength: 0)
            if model.isLoading {
                ProgressView()
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        } else {
            // Anchored on the newest comment: a thread is read from the bottom,
            // the way a conversation is.
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.comments.enumerated()), id: \.element.id) { index, comment in
                        row(comment, isFollowOn: isFollowOn(index))
                    }
                }
                .listStyle(.plain)
                .onChange(of: model.comments.last?.id) { _, newest in
                    guard let newest else { return }
                    withAnimation { proxy.scrollTo(newest, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Comments", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(model.canComment
                 ? "Start the discussion on this element."
                 : "Nobody has commented on this element.")
        } actions: {
            if model.canComment {
                Button("Write a Comment") { composerFocused = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Whether this comment carries straight on from the one above it. A run by
    /// the same person is one turn in the conversation, so it is named once.
    private func isFollowOn(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        return model.comments[index - 1].displayAuthor == model.comments[index].displayAuthor
    }

    private func row(_ comment: BlockComment, isFollowOn: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The run's turn is marked once, at its top; the rest of it lines
            // up underneath.
            if isFollowOn {
                Color.clear.frame(width: CommentAvatar.size, height: 1)
            } else {
                CommentAvatar(name: comment.displayAuthor)
            }
            VStack(alignment: .leading, spacing: 3) {
                if !isFollowOn {
                    HStack(alignment: .firstTextBaseline) {
                        Text(comment.displayAuthor)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if let created = comment.createdAt {
                            Text(created, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(comment.displayBody)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
        // The server decides who may remove a comment; it says so by offering
        // the link. Reachable both ways — a swipe is quicker, a long press is
        // the one a trackpad finds.
        .swipeActions(edge: .trailing) {
            if comment.canDelete {
                Button(role: .destructive) {
                    pendingDelete = comment
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if comment.canDelete {
                Button(role: .destructive) {
                    pendingDelete = comment
                } label: {
                    Label("Delete Comment", systemImage: "trash")
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Add a comment", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
                .focused($composerFocused)

            Button {
                let body = draft
                draft = ""
                composerFocused = false
                Task {
                    // Cleared optimistically so the composer feels immediate,
                    // and put back when the comment doesn't land: a note lost
                    // to a dropped connection used to disappear with it, and
                    // the words only existed in that field. `add` has already
                    // said why, or deliberately said nothing if the request
                    // was merely abandoned. Left alone if they have started
                    // typing something else in the meantime.
                    guard await model.add(body) == false else { return }
                    if draft.isEmpty { draft = body }
                }
            } label: {
                // Tinted only once there is something to send, so the button
                // says whether the comment will go.
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(model.isWorking ? 0 : 1)
            .overlay {
                if model.isWorking { ProgressView() }
            }
            .accessibilityLabel("Post Comment")
        }
        .animation(.snappy, value: canSend)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isWorking
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Whoever wrote a comment, as their initials on a coloured disc.
///
/// The API gives a thread names and nothing else — no avatars, no "this one is
/// yours" — so the identity a reader gets has to be built from the name. The
/// colour is derived arithmetically rather than from `hashValue`, which Swift
/// seeds afresh each launch: the same collaborator would otherwise change
/// colour every time the app started.
private struct CommentAvatar: View {
    let name: String

    static let size: CGFloat = 30

    private static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green,
    ]

    private var tint: Color {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 4096 }
        return Self.palette[seed % Self.palette.count]
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(tint.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}
