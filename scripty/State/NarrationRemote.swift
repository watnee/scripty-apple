//
//  NarrationRemote.swift
//  scripty
//
//  A reading, as the rest of the device sees it.
//
//  Once the script can be read with the screen off, the reader is no longer
//  the only thing driving it: the Lock Screen, Control Center, a squeeze of an
//  AirPod and the car stereo all expect to be able to stop the voice, and a
//  phone call expects to be able to take the audio away and give it back. This
//  is the one place that talks to all of them — it registers the transport
//  commands, publishes what is being read so something can be shown on a
//  locked screen, and reports interruptions back.
//
//  It is deliberately not main-actor bound. The narrator that owns it is, but
//  the notification blocks are `@Sendable` and the deinit is nonisolated, so
//  the type keeps its own state out of the way and carries events across as
//  `NarrationRelay` does: one `@MainActor` closure, and nothing else shared.
//

import AVFoundation
import Foundation

#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Something outside the reader asking for the reading to change.
enum NarrationRemoteEvent: Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
    case stop
    /// A call, an alarm, Siri: the system has taken the audio away.
    case interrupted
    /// ...and handed it back, saying it is fine to carry on.
    case interruptionEnded
    /// Headphones pulled out, or the car left behind. Carrying on would put
    /// the reading out loud in a room that did not ask for it.
    case outputLost
}

/// What a locked screen is told about the reading.
struct NarrationNowPlaying: Equatable {
    /// The script being read.
    var title: String
    /// Whose line it is on, which is the one thing that changes as it goes.
    var speaker: String
    var isPlaying: Bool
}

nonisolated final class NarrationRemote {

    /// Main-actor isolated, and so `Sendable` without saying so.
    private let onEvent: @MainActor (NarrationRemoteEvent) -> Void

    #if canImport(MediaPlayer)
    /// Kept so the handlers can be taken off again. The command center is a
    /// process-wide singleton, so a narrator that has been let go would
    /// otherwise stay subscribed and answer for a reading that has ended.
    private var commands: [(MPRemoteCommand, Any)] = []
    #endif
    private var observers: [NSObjectProtocol] = []

    /// Whether this one ever put a reading on the Lock Screen.
    ///
    /// The card is a single process-wide slot, so only whoever filled it may
    /// empty it: SwiftUI builds and discards `@State` values freely, and a
    /// narrator that was created and dropped without ever speaking would
    /// otherwise take down the card the surviving one is showing.
    private var isPublishing = false

    init(onEvent: @escaping @MainActor (NarrationRemoteEvent) -> Void) {
        self.onEvent = onEvent
        registerCommands()
        observeAudioSession()
    }

    deinit {
        #if canImport(MediaPlayer)
        for (command, token) in commands {
            command.removeTarget(token)
        }
        if isPublishing {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        #endif
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - What the Lock Screen shows

    /// Publishes the reading, or takes it down entirely when nothing is loaded.
    ///
    /// No duration and no elapsed time: a synthesizer's pace depends on the
    /// voice, the speed and the words, so any number here would be a guess
    /// drawn as a progress bar — and left out entirely the bar renders full,
    /// which reads as a reading about to end. Saying it is a live stream is
    /// the honest version: the transport stays, the scrubber becomes LIVE.
    func update(_ playing: NarrationNowPlaying?) {
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        guard let playing else {
            guard isPublishing else { return }
            isPublishing = false
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        isPublishing = true
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: playing.title,
            MPMediaItemPropertyArtist: playing.speaker,
            MPMediaItemPropertyAlbumTitle: "Read-Through",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing.isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = playing.isPlaying ? .playing : .paused
        #endif
    }

    // MARK: - The buttons everywhere else

    private func registerCommands() {
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, .play)
        register(center.pauseCommand, .pause)
        register(center.togglePlayPauseCommand, .toggle)
        register(center.stopCommand, .stop)
        // Track skips are the reader's element skips: on a Lock Screen these
        // are the two arrows either side of play, and stepping by element is
        // what those mean in a script.
        register(center.nextTrackCommand, .next)
        register(center.previousTrackCommand, .previous)

        // Nothing here is seekable, and a control that does nothing is worse
        // than one that is not offered.
        for unsupported in [center.changePlaybackPositionCommand,
                            center.skipForwardCommand,
                            center.skipBackwardCommand,
                            center.seekForwardCommand,
                            center.seekBackwardCommand] {
            unsupported.isEnabled = false
        }
        #endif
    }

    #if canImport(MediaPlayer)
    private func register(_ command: MPRemoteCommand, _ event: NarrationRemoteEvent) {
        command.isEnabled = true
        // Capture the closure rather than `self`: the handler outlives nothing
        // it should not, and the block never touches this object's state.
        let send = onEvent
        let token = command.addTarget { _ in
            Task { @MainActor in send(event) }
            return .success
        }
        commands.append((command, token))
    }
    #endif

    // MARK: - When the device wants the audio back

    private func observeAudioSession() {
        let send = onEvent
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                Task { @MainActor in send(.interrupted) }
            case .ended:
                // Only when the system says so. Coming back over the top of a
                // call the caller is still on is the thing nobody wants.
                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                let options = AVAudioSession.InterruptionOptions(rawValue: raw ?? 0)
                guard options.contains(.shouldResume) else { return }
                Task { @MainActor in send(.interruptionEnded) }
            @unknown default:
                break
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in send(.outputLost) }
        })
    }
}
