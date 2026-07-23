//
//  ScriptSearchBar.swift
//  scripty
//
//  Find-in-script, presented as a bar above the keyboard rather than the web
//  app's filtering dropdown: type, watch the "n of m" counter, and step
//  through the hits with the chevrons. Each step scrolls the script page.
//

import SwiftUI

struct ScriptSearchBar: View {
    let model: ScriptModel
    let navigator: ScriptNavigator
    @Bindable var search: ScriptSearchModel
    /// Called when the writer taps Done; the host hides the bar.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @State private var confirmReplaceAll = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if search.isReplacing {
                replaceRow
                Divider()
            }
            HStack(spacing: 10) {
                // Only offer replace when the server advertised it.
                if model.canReplace {
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

                Button {
                    jump(search.next())
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!search.hasMatches)

                Button("Done") {
                    search.clear()
                    search.isReplacing = false
                    isFocused = false
                    onDismiss()
                }
                .font(.body.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .alert("Replace All", isPresented: $confirmReplaceAll) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                Task { await replaceAll() }
            }
        } message: {
            let count = search.replaceTargetIds(in: model.blocks).count
            Text("Replace every occurrence of “\(search.query)” in \(count) "
                 + (count == 1 ? "element" : "elements") + "? This can be undone.")
        }
        .onAppear { isFocused = true }
        .onChange(of: search.query) { _, _ in
            // A new query makes the last replace's tally meaningless. This part
            // is immediate — the stale count must not outlive the query that
            // produced it, even for a moment.
            resultMessage = nil
        }
        .task(id: search.query) {
            // Scanning every block builds a snippet per hit, so on a feature
            // script it is far too much work to redo between two keystrokes.
            // Wait for a pause in the typing first; a cancelled task means
            // another character arrived and this scan was never needed.
            //
            // Shorter than the commit debounce on purpose: a stale "3 of 12"
            // is read immediately, whereas an unsaved keystroke is not.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            search.refresh(in: model.blocks)
            // Land on the first hit as soon as the query resolves to one.
            if let match = search.current { navigator.jump(to: match.blockId) }
        }
        .onChange(of: model.blocks) { _, blocks in
            // A sync refresh or an edit can move the hits underneath us.
            search.refresh(in: blocks)
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search script, characters, tags", text: $search.query)
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
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Replacement text plus the switches that change what counts as a match.
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

                // Replace the current hit, then step to the next — the
                // one-at-a-time counterpart of Replace All. Only where the
                // server offered the per-block link and the cursor is on a
                // hit whose text a replace would actually change.
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
                toggle("Cues", isOn: $search.includeCharacterCues)

                Spacer(minLength: 0)

                // The find counter counts names and tags too, so replace shows
                // its own tally of what would actually change.
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

    private var replaceTargetCount: Int {
        search.hasQuery ? search.replaceTargetIds(in: model.blocks).count : 0
    }

    private var replaceScopeText: String {
        guard search.hasQuery else { return "" }
        let count = replaceTargetCount
        if count == 0 { return "Nothing to replace" }
        return "\(count) " + (count == 1 ? "element" : "elements")
    }

    /// The block a single Replace would rewrite, or nil when the cursor is not
    /// on a replaceable hit or the server never offered the per-block link.
    private var replaceTarget: Block? {
        guard search.hasQuery,
              let target = search.currentReplaceTarget(in: model.blocks),
              target.link(.replace) != nil else { return nil }
        return target
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
        // The hit is gone; re-scan and let the cursor walk forward to the next.
        search.refreshAfterReplace(in: model.blocks)
        if let match = search.current { navigator.jump(to: match.blockId) }
        resultMessage = search.hasMatches ? "Replaced" : "Replaced — no more matches"
    }

    private func replaceAll() async {
        let ids = search.replaceTargetIds(in: model.blocks)
        guard !ids.isEmpty else { return }
        let changed = await model.bulkReplace(
            ids,
            find: search.query.trimmingCharacters(in: .whitespacesAndNewlines),
            replace: search.replacement,
            matchCase: search.matchCase,
            wholeWord: search.wholeWord,
            includeCharacterCues: search.includeCharacterCues)

        if let changed {
            resultMessage = changed == 0
                ? "No changes"
                : "Replaced in \(changed) " + (changed == 1 ? "element" : "elements")
        }
        // The hits have moved; recompute against what came back.
        search.refresh(in: model.blocks)
    }

    private func jump(_ match: ScriptSearchModel.Match?) {
        guard let match else { return }
        navigator.jump(to: match.blockId)
    }
}
