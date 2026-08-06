//
//  SongAudioPlayer.swift
//  scripty
//
//  Playing one of a song's recordings, and saying where in it we are.
//
//  One player for the whole list rather than one per row: pressing play on a
//  second take stops the first, which is what a rack of takes is for. It is the
//  same rule the reader follows — the narrator is owned by the screen, not by
//  the paragraph.
//
//  The audio session is claimed the way `ScriptNarrator` claims it, and for the
//  same reason: a demo played back with the screen off is the thing being
//  listened to, not a bed under something else. It is released the moment
//  nothing is playing, so Read Aloud and a demo never sit on the session at
//  once — whichever the writer started last has it.
//

import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class SongAudioPlayer {
    /// Which take is loaded, playing or paused. Nil means nothing is.
    private(set) var currentId: Int?
    private(set) var isPlaying = false
    /// Where the playhead is and how long the take runs, both in seconds — the
    /// scrubber's two numbers, kept here so the row can draw without asking
    /// AVFoundation on every frame.
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The take being fetched before it can play, so its row can show that
    /// something is happening on a slow connection.
    private(set) var loadingId: Int?
    var errorMessage: String?

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private let delegate = PlaybackEndObserver()

    init() {
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }

    func isPlaying(_ audio: SongAudio) -> Bool {
        currentId == audio.id && isPlaying
    }

    func isCurrent(_ audio: SongAudio) -> Bool {
        currentId == audio.id
    }

    /// Press play on a take: starts it, or pauses the one already running, or
    /// resumes it where it stopped.
    func toggle(_ audio: SongAudio, from model: SongAudioModel) async {
        if currentId == audio.id {
            isPlaying ? pause() : resume()
            return
        }
        loadingId = audio.id
        defer { if loadingId == audio.id { loadingId = nil } }
        do {
            let url = try await model.fileURL(for: audio)
            try start(url, id: audio.id)
            errorMessage = nil
        } catch {
            guard !error.isCancelledRequest else { return }
            // A recording that will not play is worth saying out loud: unlike a
            // failed load there is nothing else on screen explaining it.
            errorMessage = "That recording would not play. \(error.localizedDescription)"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
        releaseSession()
    }

    func resume() {
        guard let player else { return }
        activateSession()
        if player.play() {
            isPlaying = true
            startTicking()
        }
    }

    /// Drop the whole thing — the sheet closing, or the take being deleted
    /// out from under the playhead.
    func stop() {
        player?.stop()
        player = nil
        currentId = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicking()
        releaseSession()
    }

    /// Move the playhead, in seconds from the start.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        currentTime = player.currentTime
    }

    // MARK: - Plumbing

    private func start(_ url: URL, id: Int) throws {
        player?.stop()
        activateSession()
        let created = try AVAudioPlayer(contentsOf: url)
        created.delegate = delegate
        created.prepareToPlay()
        player = created
        currentId = id
        duration = created.duration
        currentTime = 0
        isPlaying = created.play()
        if isPlaying {
            startTicking()
        }
    }

    private func finish() {
        isPlaying = false
        currentTime = duration
        stopTicking()
        releaseSession()
    }

    /// The playhead, read four times a second — often enough that a scrubber
    /// moves smoothly, rare enough that a take playing with the screen off
    /// costs nothing.
    private func startTicking() {
        stopTicking()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await MainActor.run {
                    guard let player = self.player, player.isPlaying else { return }
                    self.currentTime = player.currentTime
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func activateSession() {
        #if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func releaseSession() {
        #if !targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// `AVAudioPlayerDelegate` is an Objective-C protocol and cannot be worn by
    /// a main-actor-isolated class, so the callback lands here and hops over.
    private final class PlaybackEndObserver: NSObject, AVAudioPlayerDelegate {
        var onFinish: (() -> Void)?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish?()
        }
    }
}

/// How long an audio file plays, measured on the device that is uploading it.
///
/// The server never decodes audio — it stores what it is given — so the
/// duration in a recording's description is whatever the uploading client
/// measured. This is that measurement, and it is allowed to fail: a format
/// AVFoundation cannot open simply uploads without one.
enum SongAudioDuration {

    static func measure(data: Data, fileName: String) async -> Int? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("song-audio-probe-\(UUID().uuidString)")
            .appendingPathExtension((fileName as NSString).pathExtension)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            guard seconds.isFinite, seconds > 0 else { return nil }
            return Int((seconds * 1000).rounded())
        } catch {
            return nil
        }
    }
}
