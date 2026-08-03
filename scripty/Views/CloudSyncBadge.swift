//
//  CloudSyncBadge.swift
//  scripty
//
//  One glyph in the corner answering the question every writer asks without
//  meaning to: is what I just typed anywhere other than this device?
//
//  The banners already say so — but only when something is wrong, and a screen
//  that is silent when all is well can be silent for either reason. The badge
//  is the standing half of that answer: always there, quiet when the work is on
//  the server, coloured the moment it isn't.
//
//  It is also the one place to press. A glyph that reports a problem and then
//  offers nothing leaves the writer to guess whether waiting helps; tapping it
//  opens the whole answer — when the work last reached the server, what is
//  still held, and a button that stops the waiting and tries now.
//

import SwiftUI

/// Where the work on screen currently lives.
enum CloudSyncState: Equatable {
    /// Everything typed here has reached the server.
    case synced
    /// There is a route to the network, but some of the writing is still on
    /// its way — a save retrying, or elements written offline still queued.
    case holding
    /// No route to the network at all; nothing can leave this device yet.
    case offline
    /// The server refused some of the writing — a failure no retry is going
    /// to fix on its own. Distinct from `holding` because the honest verbs
    /// differ: holding is "saving", this is "couldn't save".
    case failed
    /// Two versions of the same words exist and only a person can say which
    /// one wins. Beats every other state while it is on: the others are
    /// waiting on a connection, and this one is waiting on the writer — a
    /// badge that reported "saving" over it would be asking them to wait for
    /// something that is waiting for them.
    case conflicted
}

/// The cloud in the corner: a standing answer to "is my work saved?", and —
/// when a `sync` action is handed in — the way to do something about it.
///
/// Deliberately dull in the good state. A badge that shouts while everything
/// is fine is a badge writers learn to stop reading, which is precisely when
/// it needs to be read — so the healthy state is a grey checkmark and only the
/// two states worth acting on wear the banners' amber.
struct CloudSyncBadge: View {
    let state: CloudSyncState

    /// How many elements are held on this device. Named in the spoken label
    /// when there are any; the glyph itself never tries to carry a number.
    var heldCount: Int = 0

    /// Overrides the spoken sentence where the default one would be a lie —
    /// the projects list is not "saving" anything while it waits on a refresh,
    /// it is showing yesterday's copy. The glyph and its colour stay the same;
    /// only the words a caller can say better than this view are handed in.
    var label: String? = nil

    /// When the screen was last known to be in step with the server. Shown in
    /// the detail panel, where "saving…" on its own leaves open whether that
    /// has been true for two seconds or since yesterday. Nil means nothing on
    /// this screen has landed yet this session.
    var lastSyncedAt: Date? = nil

    /// Push everything held and pull whatever changed, right now. Handing this
    /// in is what makes the badge pressable; without it the glyph stays the
    /// read-only sign it has always been.
    var sync: (() async -> Void)? = nil

    /// How many versions are waiting on the writer to choose between them, and
    /// what opens the screen where they do. When there are any, that button —
    /// not the sync one — is the panel's prominent action: syncing cannot
    /// finish while an answer is outstanding, and offering it first would send
    /// the writer round a loop that always ends back here.
    var conflictCount: Int = 0
    var review: (() -> Void)? = nil

    /// Open while the writer is reading the detail panel.
    @State private var showingDetail = false
    /// True from the tap until the handed-in sync returns — the button wears a
    /// spinner and refuses a second press for as long as it is.
    @State private var isSyncing = false

    /// Pressable when there is anything behind the press. A badge handed only
    /// a `review` — the note editor's, which has no sync of its own to offer —
    /// still opens: two versions of the writer's words waiting on an answer is
    /// the one thing this glyph must never report and then decline to explain.
    private var isPressable: Bool { sync != nil || review != nil }

    var body: some View {
        if isPressable {
            Button {
                showingDetail = true
            } label: {
                glyph
            }
            // No bordered chrome: this reports first and acts second, and a
            // button shape beside the title would read as one more control.
            .buttonStyle(.plain)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint(sync == nil
                ? "Shows sync details and lets you choose which version to keep."
                : "Shows sync details and lets you sync now.")
            .help(spokenLabel)
            .popover(isPresented: $showingDetail) {
                detailPanel
                    // Without this a compact width answers a popover with a
                    // sheet, which is a whole screen for four lines of text.
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            glyph
                .accessibilityElement()
                .accessibilityLabel(spokenLabel)
                .help(spokenLabel)
        }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            // A shade smaller than the controls beside it: this is something to
            // read before it is something to press, and the size difference
            // says so before the shape does.
            .font(.subheadline)
            // One width for all three glyphs — a slashed cloud is wider than a
            // ticked one, and without this the title next door would shuffle
            // sideways every time the connection changed its mind.
            .frame(width: 20)
            .foregroundStyle(tint)
            // Says "still working on it" without a spinner taking a seat of
            // its own in the bar.
            .symbolEffect(.pulse, options: .repeating, isActive: state == .holding)
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.2), value: state)
    }

    // MARK: - The panel behind the tap

    /// What the glyph cannot say: how long this has been true, and what
    /// pressing something would do about it.
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: state == .holding || isSyncing)
                Text(title)
                    .font(.headline)
            }
            Text(spokenLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Wrapping, not truncation: these are whole sentences and the
                // one that matters is usually the longest.
                .fixedSize(horizontal: false, vertical: true)
            if let lastSyncedAt {
                Label(lastSyncedPhrase(lastSyncedAt), systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            if conflictCount > 0, let review {
                Button {
                    showingDetail = false
                    // The review screen is a sheet, and a sheet asked for
                    // while this popover is still on screen is a presentation
                    // SwiftUI drops on the floor: the popover goes and nothing
                    // arrives, which reads as a dead button. Let the dismissal
                    // finish first, then ask.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        review()
                    }
                } label: {
                    Text(conflictCount == 1
                         ? "Review 1 Change" : "Review \(conflictCount) Changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            if let sync {
                Button {
                    Task {
                        isSyncing = true
                        await sync()
                        isSyncing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSyncing ? "Syncing…" : actionTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                // Second fiddle while something is waiting on an answer: two
                // prominent buttons in a panel this size read as one decision
                // split in half.
                .modifier(Prominence(prominent: !(conflictCount > 0 && review != nil)))
                .controlSize(.regular)
                // Offline there is nothing to try: the button would fail on
                // press every time, which teaches the writer the badge lies.
                .disabled(state == .offline || isSyncing)
            }
            if state == .offline {
                Text("Your work syncs by itself the moment the connection is back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// Filled or outlined, by whether this is the button the panel is really
    /// offering. A ternary cannot say this — the two button styles are
    /// different types — so the branch lives here.
    private struct Prominence: ViewModifier {
        let prominent: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    /// The panel's first line: a few words, where the sentence under it is a
    /// whole one. Deliberately the same vocabulary as the banners.
    private var title: String {
        switch state {
        case .synced: "Up to date"
        case .holding: "Saving…"
        case .offline: "Offline"
        case .failed: "Couldn't save"
        case .conflicted: "Needs your choice"
        }
    }

    /// What the button promises. "Try Again" only where something was refused —
    /// everywhere else this is a push and a pull, not a retry.
    private var actionTitle: String {
        switch state {
        case .failed: "Try Again"
        case .synced: "Check for Changes"
        case .holding, .offline, .conflicted: "Sync Now"
        }
    }

    /// "Last synced 5 minutes ago", with the first minute spelled out rather
    /// than counted: `.relative` renders a fresh date as "in 0 seconds", which
    /// reads as a promise about the future.
    private func lastSyncedPhrase(_ date: Date) -> String {
        Date.now.timeIntervalSince(date) < 60
            ? "Last synced just now"
            : "Last synced " + date.formatted(.relative(presentation: .named))
    }

    private var symbol: String {
        switch state {
        case .synced: "checkmark.icloud"
        // The same arrows the "Not saved yet" banner wears, on a cloud.
        case .holding: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .offline: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        // A fork rather than a cloud: this is not a state of the connection
        // at all, and dressing it as one would put it in the same family as
        // the three things that pass by themselves.
        case .conflicted: "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: .secondary
        case .holding, .offline: .orange
        // Red, alone among the states: amber means patience will fix it,
        // and here it will not.
        case .failed: .red
        // Nor here — but nothing has gone wrong either, and red over a
        // perfectly ordinary "two of you were writing" would read as a fault.
        case .conflicted: .purple
        }
    }

    /// What VoiceOver reads, what the pointer's tooltip shows on the Mac, and
    /// the panel's own sentence. Full sentences: the badge is the only thing on
    /// screen saying this when the writing is merely late rather than stranded.
    private var spokenLabel: String {
        if let label { return label }
        let held = heldCount == 1
            ? "1 element is kept on this device"
            : "\(heldCount) elements are kept on this device"
        switch state {
        case .synced:
            return "Saved to the cloud."
        case .holding:
            return heldCount > 0
                ? "Saving to the cloud. \(held) in the meantime."
                : "Saving to the cloud."
        case .offline:
            return heldCount > 0
                ? "Offline. \(held) and will sync when you're back online."
                : "Offline. Edits are kept on this device and sync when you're back online."
        case .failed:
            return heldCount > 0
                ? "Some changes couldn't be saved. \(held)."
                : "Some changes couldn't be saved. They are kept on this device."
        case .conflicted:
            return conflictCount == 1
                ? "One change was made in two places. Choose which version to keep."
                : "\(conflictCount) changes were made in two places. Choose which "
                  + "versions to keep."
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CloudSyncBadge(state: .synced)
        CloudSyncBadge(state: .holding, heldCount: 3)
        CloudSyncBadge(state: .offline, heldCount: 3)
        CloudSyncBadge(state: .failed, heldCount: 1)
        CloudSyncBadge(state: .holding, heldCount: 2,
                       lastSyncedAt: .now.addingTimeInterval(-600),
                       sync: { try? await Task.sleep(for: .seconds(1)) })
        CloudSyncBadge(state: .conflicted,
                       lastSyncedAt: .now.addingTimeInterval(-90),
                       sync: { }, conflictCount: 2, review: { })
    }
    .padding()
}
