//
//  ScriptNarrator.swift
//  scripty
//
//  Reading the script out loud.
//
//  `ScriptNarration` decides *what* is said and in what order; this drives the
//  speech synthesizer that says it, and holds the handful of preferences that
//  go with it — voice, speed, whether names are announced, whether the cast
//  gets voices of their own. Those are device preferences, like type size: a
//  writer picks a reading voice once, not once per script.
//
//  The whole remaining run is queued at once rather than an utterance at a
//  time, so the synthesizer runs the lines together the way a reader would
//  instead of leaving a seam at every element. The cost is that skipping means
//  cancelling and re-queuing from the new position; `utteranceIndex` is what
//  makes that safe, because a stale callback from the cancelled queue looks up
//  an utterance that is no longer in the map and is ignored.
//

import AVFoundation
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class ScriptNarrator {

    /// Whether anything is loaded, and if so whether it is running.
    enum Playback: Equatable {
        case idle
        case speaking
        case paused
    }

    // MARK: - What is being read

    private(set) var cues: [NarrationCue] = []
    private(set) var playback: Playback = .idle {
        didSet { publishNowPlaying() }
    }
    /// Where in the run we are, kept even while paused so resuming and the
    /// highlight agree.
    private(set) var currentIndex: Int? {
        didSet { publishNowPlaying() }
    }
    /// The script being read, for the Lock Screen to name. The reader knows it
    /// and the blocks do not, so it arrives with them.
    private(set) var scriptTitle = ""

    var isActive: Bool { playback != .idle }
    var isSpeaking: Bool { playback == .speaking }

    var currentCue: NarrationCue? {
        guard let currentIndex, cues.indices.contains(currentIndex) else { return nil }
        return cues[currentIndex]
    }

    /// The element being read, for the reader to highlight and scroll to.
    var currentBlockId: Int? { currentCue?.blockId }

    /// True once there is something worth pressing play on — the reader
    /// disables its controls otherwise rather than starting a silent run.
    var hasSomethingToRead: Bool { !cues.isEmpty }

    /// Whose line is being read: the one thing a transport — or a locked
    /// screen — can say that the highlight cannot.
    var nowReading: String {
        guard let cue = currentCue else { return "Paused" }
        if let speaker = cue.speaker, cue.kind.isSpoken { return speaker }
        return "Narration"
    }

    // MARK: - Preferences

    var options: NarrationOptions {
        didSet {
            guard options != oldValue else { return }
            persistOptions()
            // The run itself changes shape when what to include changes, so it
            // is rebuilt around wherever the reader currently is.
            reload(keepingPlace: true)
        }
    }

    /// Multiplier on the system's default speaking rate.
    var speed: Double {
        didSet {
            let clamped = min(Self.maxSpeed, max(Self.minSpeed, speed))
            if clamped != speed {
                // See PresentationSettings: an `@Observable` property whose
                // `didSet` writes back to itself unconditionally never settles.
                speed = clamped
                return
            }
            guard speed != oldValue else { return }
            defaults.set(speed, forKey: Key.speed)
            // The rate is baked into each utterance, so a speed change only
            // reaches the queue by rebuilding it.
            restartFromCurrentIfSpeaking()
        }
    }

    static let minSpeed = 0.5
    static let maxSpeed = 2.0
    static let speedChoices: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// The chosen voice, or nil for the system's default for this language.
    var voiceIdentifier: String? {
        didSet {
            guard voiceIdentifier != oldValue else { return }
            if let voiceIdentifier {
                defaults.set(voiceIdentifier, forKey: Key.voice)
            } else {
                defaults.removeObject(forKey: Key.voice)
            }
            buildCast()
            restartFromCurrentIfSpeaking()
        }
    }

    /// The installed voices worth offering: the ones that speak the language
    /// the device is set to. Falling back to every installed voice matters on
    /// a device whose language has none — an empty picker looks broken.
    var availableVoices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let family = language.split(separator: "-").first.map(String.init) ?? language
        let matching = all.filter { $0.language.hasPrefix(family) }
        return (matching.isEmpty ? all : matching).sorted { $0.name < $1.name }
    }

    /// The voice the narrator reads in, and the one every character shares
    /// unless the cast is being cast.
    var narratorVoice: AVSpeechSynthesisVoice? {
        if let voiceIdentifier,
           let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Who is reading which part, when distinct voices are on. Empty otherwise.
    private(set) var cast: [String: AVSpeechSynthesisVoice] = [:]

    /// How many characters could actually be told apart — the settings menu
    /// says so, because "one voice each" quietly becoming "one voice between
    /// three of them" is otherwise a mystery.
    var castSize: Int { cast.count }

    // MARK: - Plumbing

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var relay: NarrationRelay?
    /// The Lock Screen, the headphones and the interruptions.
    @ObservationIgnored private var remote: NarrationRemote?
    /// Set when the system took the audio away mid-line, so that being handed
    /// it back resumes a reading that was actually running — rather than
    /// starting one the writer had already paused themselves.
    @ObservationIgnored private var pausedByInterruption = false
    /// The blocks the current run was built from, kept so the run can be
    /// rebuilt when an option changes without the reader handing them back.
    @ObservationIgnored private var blocks: [Block] = []
    /// Which cue each queued utterance says. Cleared before re-queuing, which
    /// is what makes callbacks from a cancelled queue harmless.
    @ObservationIgnored private var utteranceIndex: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedSpeed = defaults.object(forKey: Key.speed) as? Double
        speed = min(Self.maxSpeed, max(Self.minSpeed, storedSpeed ?? 1.0))
        voiceIdentifier = defaults.string(forKey: Key.voice)

        var options = NarrationOptions()
        options.announcesSpeakers = defaults.object(forKey: Key.announceSpeakers) as? Bool ?? true
        options.includesDescription = defaults.object(forKey: Key.description) as? Bool ?? true
        options.includesDirections = defaults.object(forKey: Key.directions) as? Bool ?? true
        options.usesDistinctVoices = defaults.object(forKey: Key.distinctVoices) as? Bool ?? false
        self.options = options

        connect()
    }

    /// Wiring, done after initialization rather than in it: the callback
    /// captures `self`, which is still a `var` while the initializer runs.
    private func connect() {
        let relay = NarrationRelay { [weak self] event, utterance in
            self?.handle(event, from: utterance)
        }
        self.relay = relay
        synthesizer.delegate = relay

        remote = NarrationRemote { [weak self] command in
            self?.perform(command)
        }
    }

    // MARK: - Loading

    /// Points the narrator at a script. Safe to call again when the script
    /// changes underneath it — a run in progress keeps its place if it can.
    func prepare(_ blocks: [Block], title: String = "") {
        if title != scriptTitle {
            scriptTitle = title
            publishNowPlaying()
        }
        guard blocks != self.blocks else { return }
        self.blocks = blocks
        reload(keepingPlace: true)
    }

    /// Rebuilds the run, and — when asked and possible — carries the reader's
    /// place across to the cue for the same element.
    private func reload(keepingPlace: Bool) {
        let blockId = keepingPlace ? currentBlockId : nil
        cues = ScriptNarration.cues(for: blocks, options: options)
        buildCast()

        guard isActive else {
            currentIndex = nil
            return
        }
        guard let index = index(ofFirstCueIn: blockId) ?? (cues.isEmpty ? nil : 0) else {
            stop()
            return
        }
        if playback == .speaking {
            speak(from: index)
        } else {
            currentIndex = index
        }
    }

    private func index(ofFirstCueIn blockId: Int?) -> Int? {
        guard let blockId else { return nil }
        return cues.firstIndex { $0.blockId == blockId }
    }

    // MARK: - Transport

    /// Starts reading — from a given element when the reader asks for one,
    /// from where it left off otherwise, and from the top when it has not run.
    func play(from blockId: Int? = nil) {
        guard hasSomethingToRead else { return }
        if let index = index(ofFirstCueIn: blockId) {
            speak(from: index)
            return
        }
        if playback == .paused, currentIndex != nil {
            resume()
            return
        }
        speak(from: currentIndex ?? 0)
    }

    func togglePlayPause() {
        switch playback {
        case .speaking: pause()
        case .paused: resume()
        case .idle: play()
        }
    }

    func pause() {
        guard playback == .speaking else { return }
        pausedByInterruption = false
        // At a word rather than immediately: stopping mid-word and picking the
        // word up again from its middle is the thing that sounds broken.
        synthesizer.pauseSpeaking(at: .word)
        playback = .paused
        keepScreenAwake(false)
    }

    func resume() {
        guard playback == .paused else { return }
        pausedByInterruption = false
        // An interruption leaves the session deactivated behind it, so the
        // session is claimed again rather than assumed. Claiming one already
        // held costs nothing.
        activateAudioSession()
        synthesizer.continueSpeaking()
        playback = .speaking
        keepScreenAwake(true)
    }

    func stop() {
        pausedByInterruption = false
        utteranceIndex.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        playback = .idle
        currentIndex = nil
        keepScreenAwake(false)
        deactivateAudioSession()
    }

    /// Forward and back move by element rather than by cue: a writer skipping
    /// back expects the line again, not the character name they just heard.
    func skipForward() {
        guard let current = currentCue else { return }
        guard let next = cues[(current.index + 1)...].first(where: { $0.blockId != current.blockId })
        else {
            stop()
            return
        }
        go(to: next.index)
    }

    func skipBackward() {
        guard let current = currentCue else { return }
        let earlier = cues[..<current.index].last { $0.blockId != current.blockId }
        guard let earlier else {
            go(to: 0)
            return
        }
        // Land on the *first* cue of that element, so skipping back twice does
        // not walk through a speech one cue at a time.
        let start = cues.firstIndex { $0.blockId == earlier.blockId } ?? earlier.index
        go(to: start)
    }

    /// Moves the reader, keeping whether it was speaking.
    private func go(to index: Int) {
        guard cues.indices.contains(index) else { return }
        if playback == .speaking {
            speak(from: index)
        } else {
            currentIndex = index
        }
    }

    // MARK: - Speaking

    private func speak(from index: Int) {
        guard cues.indices.contains(index) else { return }
        pausedByInterruption = false

        // Clearing the map before cancelling is what makes the cancelled
        // queue's callbacks no-ops: they arrive holding an utterance nothing
        // knows about any more.
        utteranceIndex.removeAll()
        synthesizer.stopSpeaking(at: .immediate)

        activateAudioSession()
        // Playing first, then the place: both publish to the Lock Screen, and
        // in this order a skip never takes the card down and puts it back —
        // the reading stays active across the pair.
        playback = .speaking
        currentIndex = index
        keepScreenAwake(true)

        for cue in cues[index...] {
            let utterance = utterance(for: cue)
            utteranceIndex[ObjectIdentifier(utterance)] = cue.index
            synthesizer.speak(utterance)
        }
    }

    private func restartFromCurrentIfSpeaking() {
        guard playback == .speaking, let currentIndex else { return }
        speak(from: currentIndex)
    }

    private func utterance(for cue: NarrationCue) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: cue.text)
        utterance.voice = voice(for: cue)
        utterance.rate = rate
        utterance.preUtteranceDelay = cue.kind.pause
        // The narrator sits a shade below the cast, which is enough to tell
        // the page apart from the people even on one voice.
        utterance.pitchMultiplier = cue.kind.isSpoken ? 1.0 : 0.95
        return utterance
    }

    /// The synthesizer's rate is an absolute 0…1, not a multiplier, so the
    /// preference is applied to the system default and clamped to the range
    /// the synthesizer accepts.
    private var rate: Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        return min(AVSpeechUtteranceMaximumSpeechRate,
                   max(AVSpeechUtteranceMinimumSpeechRate, scaled))
    }

    private func voice(for cue: NarrationCue) -> AVSpeechSynthesisVoice? {
        if cue.kind.isSpoken, let speaker = cue.speaker, let voice = cast[speaker] {
            return voice
        }
        return narratorVoice
    }

    /// Hands the installed voices out to the speaking parts, in the order they
    /// first speak. The narrator's own voice is held back so the page and the
    /// people never sound the same; when there are more characters than voices
    /// the list wraps, which is still better than one voice for everyone.
    private func buildCast() {
        cast.removeAll()
        guard options.usesDistinctVoices else { return }
        let narrator = narratorVoice?.identifier
        let pool = availableVoices.filter { $0.identifier != narrator }
        guard !pool.isEmpty else { return }
        for (offset, speaker) in ScriptNarration.speakers(in: cues).enumerated() {
            cast[speaker] = pool[offset % pool.count]
        }
    }

    // MARK: - Callbacks

    private func handle(_ event: NarrationRelay.Event, from utterance: ObjectIdentifier) {
        guard let index = utteranceIndex[utterance] else { return }
        switch event {
        case .started:
            currentIndex = index
        case .finished:
            // Only the last one ends the run; every other utterance is followed
            // by the next queued one, which moves the highlight on its own.
            if index == cues.count - 1 { finish() }
        }
    }

    private func finish() {
        pausedByInterruption = false
        utteranceIndex.removeAll()
        playback = .idle
        currentIndex = nil
        keepScreenAwake(false)
        deactivateAudioSession()
    }

    // MARK: - Everything outside the reader

    /// A button pressed somewhere this app is not: the Lock Screen, an AirPod,
    /// a steering wheel — or the system taking the audio and giving it back.
    private func perform(_ command: NarrationRemoteEvent) {
        switch command {
        case .play: play()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .next: skipForward()
        case .previous: skipBackward()
        case .stop: stop()
        case .interrupted:
            let wasSpeaking = playback == .speaking
            pause()
            pausedByInterruption = wasSpeaking
        case .interruptionEnded:
            guard pausedByInterruption else { return }
            resume()
        case .outputLost:
            // Headphones out: stop talking to the room. Deliberately not a
            // resume when they go back in — that is the writer's call.
            pause()
        }
    }

    /// Tells the Lock Screen what is being read, or takes the reading down
    /// when there is nothing to control.
    private func publishNowPlaying() {
        guard isActive else {
            remote?.update(nil)
            return
        }
        remote?.update(NarrationNowPlaying(
            title: scriptTitle.isEmpty ? "Untitled Project" : scriptTitle,
            speaker: nowReading,
            isPlaying: isSpeaking
        ))
    }

    // MARK: - The device while it reads

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Spoken audio, and it takes the output rather than mixing into it: a
        // read-through runs for minutes with the screen off, holds the Lock
        // Screen's transport, and is the thing being listened to. Ducking the
        // music under it — which is what this did while the reader was only
        // ever on screen — would leave two players sharing one pair of
        // headphones and one set of buttons.
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A read-through is minutes of nobody touching the screen, which is
    /// exactly when the device would otherwise lock.
    private func keepScreenAwake(_ awake: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    private func persistOptions() {
        defaults.set(options.announcesSpeakers, forKey: Key.announceSpeakers)
        defaults.set(options.includesDescription, forKey: Key.description)
        defaults.set(options.includesDirections, forKey: Key.directions)
        defaults.set(options.usesDistinctVoices, forKey: Key.distinctVoices)
    }

    /// Client-side only — the web app has no reader to keep in step with, so
    /// these are spelled the way the other client-only preferences are.
    private enum Key {
        static let speed = "scripty.readAloud.speed"
        static let voice = "scripty.readAloud.voice"
        static let announceSpeakers = "scripty.readAloud.announceSpeakers"
        static let description = "scripty.readAloud.description"
        static let directions = "scripty.readAloud.directions"
        static let distinctVoices = "scripty.readAloud.distinctVoices"
    }
}

/// Carries the synthesizer's callbacks back to the main actor.
///
/// The delegate is not main-actor bound and `AVSpeechUtterance` is not
/// `Sendable`, so what crosses is the utterance's identity rather than the
/// utterance — enough to look up which cue it was, and safe to hand over. The
/// hop happens here rather than in the narrator so that the narrator's own
/// handler can be an ordinary main-actor method.
private final class NarrationRelay: NSObject, AVSpeechSynthesizerDelegate {
    enum Event: Sendable {
        case started
        case finished
    }

    /// Main-actor isolated, and so `Sendable` without saying so.
    private let onEvent: @MainActor (Event, ObjectIdentifier) -> Void

    init(onEvent: @escaping @MainActor (Event, ObjectIdentifier) -> Void) {
        self.onEvent = onEvent
    }

    nonisolated private func send(_ event: Event, _ utterance: AVSpeechUtterance) {
        let handler = onEvent
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in handler(event, id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        send(.started, utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        send(.finished, utterance)
    }
}
