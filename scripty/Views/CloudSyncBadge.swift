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

    /// Open while the writer is reading the detail panel.
    @State private var showingDetail = false
    /// True from the tap until the handed-in sync returns — the button wears a
    /// spinner and refuses a second press for as long as it is.
    @State private var isSyncing = false

    var body: some View {
        if let sync {
            Button {
                showingDetail = true
            } label: {
                glyph
            }
            // No bordered chrome: this reports first and acts second, and a
            // button shape beside the title would read as one more control.
            .buttonStyle(.plain)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Shows sync details and lets you sync now.")
            .help(spokenLabel)
            .popover(isPresented: $showingDetail) {
                detailPanel(sync: sync)
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
    private func detailPanel(sync: @escaping () async -> Void) -> some View {
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
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            // Offline there is nothing to try: the button would fail on press
            // every time, which teaches the writer the badge lies.
            .disabled(state == .offline || isSyncing)
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

    /// The panel's first line: a few words, where the sentence under it is a
    /// whole one. Deliberately the same vocabulary as the banners.
    private var title: String {
        switch state {
        case .synced: "Up to date"
        case .holding: "Saving…"
        case .offline: "Offline"
        case .failed: "Couldn't save"
        }
    }

    /// What the button promises. "Try Again" only where something was refused —
    /// everywhere else this is a push and a pull, not a retry.
    private var actionTitle: String {
        switch state {
        case .failed: "Try Again"
        case .synced: "Check for Changes"
        case .holding, .offline: "Sync Now"
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
        }
    }

    private var tint: Color {
        switch state {
        case .synced: .secondary
        case .holding, .offline: .orange
        // Red, alone among the states: amber means patience will fix it,
        // and here it will not.
        case .failed: .red
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
    }
    .padding()
}
