//
//  SongSearchBar.swift
//  scripty
//
//  Find-in-song: `ScriptSearchBar` in a lyric's words.
//
//  Two things it does not carry, both because a lyric line is not a screenplay
//  element. There is no "Cues" toggle — a line has no character cue to protect —
//  and the scope text counts lines rather than elements.
//
//  The replace half appears only where the server advertised `bulkReplace` on
//  this song. A server that predates those rels leaves the bar as find alone,
//  which is still a long way past the filter this editor used to have, and
//  nothing looks broken while the deploy catches up.
//

import SwiftUI

struct SongSearchBar: View {
    let model: SongBlockModel
    @Bindable var search: SongSearchModel
    /// Called with the line to scroll to as the writer steps through hits.
    let onJump: (Int) -> Void
    /// Called when the writer taps Done; the host hides the bar.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @State private var confirmReplaceAll = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if search.isReplacing {
                replaceRow
                Divider()
            }
            HStack(spacing: 10) {
                if model.canReplaceLyrics {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            search.isReplacing.toggle()
                        }
                    } label: {
                        Image(systemName: search.isReplacing
                              ? "chevron.down.circle.fill" : "chevron.right.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(search.isReplacing ? "Hide Replace" : "Show Replace")
                }

                field

                Text(search.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
                    .animation(nil, value: search.statusText)

                Button {
                    jump(search.previous())
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!search.hasMatches)
                .accessibilityLabel("Previous result")

                Button {
                    jump(search.next())
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!search.hasMatches)
                .accessibilityLabel("Next result")

                Button("Done") {
                    search.clear()
                    isFocused = false
                    onDismiss()
                }
                .font(.body.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // No background of its own: the host mounts it with `.safeAreaBar`,
        // which supplies the Liquid Glass and the separation from the lyric.
        .alert("Replace All", isPresented: $confirmReplaceAll) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                Task { await replaceAll() }
            }
        } message: {
            let count = replaceTargetCount
            Text("Replace every occurrence of “\(search.query)” in \(count) "
                 + (count == 1 ? "line" : "lines") + "? This can be undone.")
        }
        .onAppear { isFocused = true }
        .onChange(of: search.query) { _, _ in
            // A new query makes the last replace's tally meaningless, and the
            // stale count must not outlive the query that produced it even for
            // a moment — so this part is immediate rather than debounced.
            resultMessage = nil
        }
        .task(id: search.query) {
            // Wait for a pause in the typing: a cancelled task means another
            // character arrived and this scan was never needed. Shorter than the
            // commit debounce on purpose — a stale "3 of 12" is read at once,
            // whereas an unsaved keystroke is not.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            search.refresh(in: lines)
            if let match = search.current { onJump(match.lineId) }
        }
    }

    /// Always the words on screen, never the server's copy — a line typed a
    /// second ago is exactly the line a writer expects to find.
    private var lines: [SongSearchModel.Line] {
        model.blocks.map { SongSearchModel.Line(id: $0.id, text: model.currentText($0)) }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search lyrics", text: $search.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                .focused($isFocused)
                .onSubmit { jump(search.next()) }
            if search.hasQuery {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var replaceRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                    TextField("Replace with", text: $search.replacement)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Button("Replace") {
                    Task { await replaceCurrent() }
                }
                .disabled(replaceTarget == nil)

                Button("Replace All") {
                    confirmReplaceAll = true
                }
                .font(.body.weight(.medium))
                .disabled(replaceTargetCount == 0)
            }

            HStack(spacing: 12) {
                toggle("Match Case", isOn: $search.matchCase)
                toggle("Whole Word", isOn: $search.wholeWord)

                Spacer(minLength: 0)

                Text(resultMessage ?? replaceScopeText)
                    .font(.caption)
                    .foregroundStyle(resultMessage == nil ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            resultMessage = nil
            // Both of these narrow what a replace would touch, and neither goes
            // through the debounce that keeps the tally current — so each has to
            // say so itself, or the count goes stale the moment one is flipped.
            search.refresh(in: lines)
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isOn.wrappedValue ? AnyShapeStyle(.tint.opacity(0.18))
                                      : AnyShapeStyle(.quaternary.opacity(0.4)),
                    in: Capsule())
                .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    /// Read, not recomputed — see `SongSearchModel.replaceTargets`. The replace
    /// row asks for this three times in one pass of its body, and typing in the
    /// replacement field redraws that row on every character.
    private var replaceTargetCount: Int {
        search.hasQuery ? search.replaceTargets.count : 0
    }

    private var replaceScopeText: String {
        guard search.hasQuery else { return "" }
        let count = replaceTargetCount
        if count == 0 { return "Nothing to replace" }
        return "\(count) " + (count == 1 ? "line" : "lines")
    }

    /// The line a single Replace would rewrite, or nil when the cursor is not on
    /// one the server offered the per-line link for.
    private var replaceTarget: SongBlock? {
        guard search.hasQuery,
              let id = search.currentReplaceTarget(in: lines),
              let block = model.blocks.first(where: { $0.id == id }),
              block.link(.replace) != nil else { return nil }
        return block
    }

    private func replaceCurrent() async {
        guard let target = replaceTarget else { return }
        let replaced = await model.replaceOne(
            target,
            find: search.query,
            replace: search.replacement,
            matchCase: search.matchCase,
            wholeWord: search.wholeWord)
        guard replaced else { return }
        // The hit is gone; re-scan and let the cursor walk on to the next.
        search.refreshAfterReplace(in: lines)
        if let match = search.current { onJump(match.lineId) }
        resultMessage = search.hasMatches ? "Replaced" : "Replaced — no more matches"
    }

    private func replaceAll() async {
        guard replaceTargetCount > 0 else { return }
        let changed = await model.bulkReplace(
            find: search.query,
            replace: search.replacement,
            matchCase: search.matchCase,
            wholeWord: search.wholeWord)

        if let changed {
            resultMessage = changed == 0
                ? "No changes"
                : "Replaced in \(changed) " + (changed == 1 ? "line" : "lines")
        }
        // The hits have moved; recompute against what came back.
        search.refresh(in: lines)
    }

    private func jump(_ match: SongSearchModel.Match?) {
        guard let match else { return }
        onJump(match.lineId)
    }
}
