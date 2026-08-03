//
//  SyncConflictsView.swift
//  scripty
//
//  The screen where a writer settles what the app cannot: two versions of the
//  same words, one typed here while there was no connection and one that
//  arrived from somewhere else, and only one of them can be the next one.
//
//  Both versions are shown whole rather than as a diff. A diff is the right
//  tool when the change is a line in a hundred; here the two sides are usually
//  a sentence each, and what the writer is really doing is *reading* — the
//  question is which paragraph they want, not which characters moved.
//
//  There is no merge button. Merging prose means writing, and a client that
//  spliced two versions together would produce a third one nobody wrote and
//  everyone would have to proofread. What this offers instead is the raw
//  material for a merge by hand: both versions on screen, either one
//  copyable, and whichever is kept lands in an editor the writer can then
//  type into.
//

import SwiftUI

struct SyncConflictsView: View {
    let conflicts: [SyncConflict]

    /// Push this device's version. Async because it is a real write, and the
    /// answer — sent, or held for later — is the sentence the sheet says next.
    let keepMine: (SyncConflict) async -> ConflictResolution
    /// Let the other version stand. Nothing goes out, so nothing to await.
    let keepTheirs: (SyncConflict) -> Void

    /// What the writer's own words are called here — "element", "line",
    /// "note". Only used in sentences; the rows say it for themselves.
    var noun: String = "change"

    @Environment(\.dismiss) private var dismiss

    /// The one being written to right now, so its buttons can wait rather than
    /// letting a second press start a second write of the same words.
    @State private var resolving: String?
    /// What the last choice did, kept so the sheet can say so once everything
    /// is answered rather than closing itself and leaving the writer to infer
    /// it from a badge.
    @State private var lastOutcome: String?

    var body: some View {
        NavigationStack {
            Group {
                if conflicts.isEmpty {
                    settled
                } else {
                    list
                }
            }
            .navigationTitle("Review Changes")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if conflicts.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Button("Keep All of Mine") { resolveAll(mine: true) }
                            Button("Use All from the Cloud") { resolveAll(mine: false) }
                        } label: {
                            Label("Resolve All", systemImage: "ellipsis.circle")
                        }
                        .disabled(resolving != nil)
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(conflicts) { conflict in
                    row(conflict)
                }
            } header: {
                Text(conflicts.count == 1
                     ? "One \(noun) needs your choice"
                     : "\(conflicts.count) \(noun)s need your choice")
            } footer: {
                Text("Nothing here is sent or deleted until you choose. Whichever "
                     + "version you keep becomes the current one everywhere.")
            }
        }
    }

    /// What the sheet shows once the last question is answered. Deliberately
    /// not an automatic dismissal: the writer has just made a decision about
    /// their own words and a screen that vanishes on them leaves no way to be
    /// sure which way it went.
    private var settled: some View {
        ContentUnavailableView {
            Label("Nothing left to choose", systemImage: "checkmark.circle")
        } description: {
            Text(lastOutcome ?? "Every version has been settled.")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - One disagreement

    @ViewBuilder
    private func row(_ conflict: SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(conflict)
            version(title: "Your version",
                    subtitle: "typed on this device",
                    text: conflict.mineTitle.map { titled($0, conflict.mine) } ?? conflict.mine,
                    tint: .orange)
            if conflict.hasTheirs {
                version(title: "In the cloud",
                        subtitle: "saved somewhere else",
                        text: conflict.theirsTitle.map { titled($0, conflict.theirs) } ?? conflict.theirs,
                        tint: .secondary)
            }
            choices(conflict)
        }
        .padding(.vertical, 6)
    }

    private func header(_ conflict: SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(conflict.label)
                    .font(.headline)
                Spacer(minLength: 0)
                Text(when(conflict.detectedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(conflict.headline)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(conflict.reason == .refused ? .red : .orange)
            Text(conflict.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One version, in a box of its own. Selectable so the words can be
    /// rescued by hand even when neither button is the right answer, and
    /// scrollable past a point: a note's body is not a label, and a card that
    /// grew to the length of a page would bury the buttons under it.
    private func version(title: String, subtitle: String, text: String,
                         tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                Text("· " + subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    copy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy \(title.lowercased())")
            }
            Text(text.isEmpty ? "(empty)" : text)
                .font(.callout)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                // Capped by lines rather than by height: a scroll view inside
                // a list row takes the height it is offered and cuts the last
                // line in half, which reads as a rendering fault rather than
                // as "there is more". A line limit ends on a line, with the
                // ellipsis saying the rest is there — and the copy button
                // above takes the whole thing whatever is shown.
                .lineLimit(12)
                .padding(10)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)))
        }
    }

    @ViewBuilder
    private func choices(_ conflict: SyncConflict) -> some View {
        let busy = resolving == conflict.id
        HStack(spacing: 10) {
            if conflict.canKeepMine {
                Button {
                    resolve(conflict, mine: true)
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Keep Mine")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Copy My Version") { copy(conflict.mine) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            Button(conflict.hasTheirs ? "Use the Cloud's" : "Discard Mine") {
                resolve(conflict, mine: false)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        // One write at a time: a second press while the first is in flight
        // would send the same words twice, and over a bad connection that is
        // exactly when a writer presses again.
        .disabled(resolving != nil)
    }

    // MARK: - Doing it

    private func resolve(_ conflict: SyncConflict, mine: Bool) {
        guard resolving == nil else { return }
        guard mine else {
            keepTheirs(conflict)
            lastOutcome = conflict.hasTheirs
                ? "The cloud's version was kept."
                : "Your version was discarded."
            return
        }
        resolving = conflict.id
        Task {
            let outcome = await keepMine(conflict)
            resolving = nil
            lastOutcome = switch outcome {
            case .sent: "Your version is saved to the cloud."
            case .held: "Your version is kept here and will sync when you're back online."
            case .failed: "Your version couldn't be sent — it is still on this device."
            }
        }
    }

    private func resolveAll(mine: Bool) {
        guard resolving == nil else { return }
        guard mine else {
            for conflict in conflicts { keepTheirs(conflict) }
            lastOutcome = "The cloud's versions were kept."
            return
        }
        resolving = "all"
        Task {
            for conflict in conflicts where conflict.canKeepMine {
                _ = await keepMine(conflict)
            }
            resolving = nil
            lastOutcome = "Your versions were kept."
        }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// A title and a body are one version of a note, so they are shown as one
    /// piece of text rather than as two boxes the eye has to pair up.
    private func titled(_ title: String, _ body: String) -> String {
        title.isEmpty ? body : title + "\n\n" + body
    }

    /// "just now" for the first minute: `.relative` renders a fresh date as
    /// "in 0 seconds", which reads as a promise about the future.
    private func when(_ date: Date) -> String {
        Date.now.timeIntervalSince(date) < 60
            ? "just now"
            : date.formatted(.relative(presentation: .named))
    }
}

/// The strip that says two versions exist and where to settle them. One view
/// rather than three, so the screenplay, the lyric and the note all say it the
/// same way — and so it never learns to say it differently in one of them.
///
/// Deliberately not dismissible, unlike every other standing notice in the
/// app: those report patience, and closing one costs nothing because the work
/// syncs by itself. This one is a question, and a question nobody answers is
/// words nobody keeps.
struct ConflictBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                Text(count == 1 ? "One change needs your choice"
                                : "\(count) changes need your choice")
                    .fontWeight(.medium)
                Text("· written here and elsewhere")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Review")
                    .fontWeight(.medium)
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.purple)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.purple.opacity(0.12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel(count == 1
            ? "One change was made both here and elsewhere. Review it to choose which version to keep."
            : "\(count) changes were made both here and elsewhere. Review them to choose which versions to keep.")
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.snappy(duration: 0.2), value: count)
    }
}

#Preview {
    SyncConflictsView(
        conflicts: [
            SyncConflict(subject: .block(id: 1), reason: .changedElsewhere,
                         mine: "She turns the key. Nothing happens.",
                         theirs: "She turns the key. The engine coughs once.",
                         base: "She turns the key.",
                         label: "Action", detectedAt: .now.addingTimeInterval(-3600)),
            SyncConflict(subject: .document(id: 2), reason: .targetDeleted,
                         mine: "Verse two, written on the train.", mineTitle: "Bridge",
                         theirs: "", label: "Bridge",
                         detectedAt: .now.addingTimeInterval(-86_400)),
        ],
        keepMine: { _ in .held },
        keepTheirs: { _ in },
        noun: "change")
}
