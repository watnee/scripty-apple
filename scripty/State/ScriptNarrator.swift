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
//  There is one of these on the device — `shared` — and every surface that can
//  be read aloud borrows it: the screenplay, the lyric editor and the note
//  sheet. A narrator each looked tidier and was wrong in three ways at once. A
//  song read while the script was still reading would have been two voices in
//  one room; the Lock Screen has a single card and a single pair of headphone
//  buttons, which two narrators would have fought over; and the preferences
//  below are the writer's, not the document's. So starting a reading anywhere
//  ends whatever was being read before it, which is also what a person would
//  expect from a device with one voice. `subject` is how a screen asks whether
//  the reading currently running is its own.
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

    /// The device's voice. See the note at the top of this file for why there
    /// is only one.
    static let shared = ScriptNarrator()

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
    /// The document being read, for the Lock Screen to name. The screen that
    /// asked for the reading knows it and the words themselves do not, so it
    /// arrives with them.
    private(set) var scriptTitle = ""
    /// Which screenplay, song or note the current run belongs to. Nil when
    /// nothing is loaded — and the answer to "is that voice reading me?", which
    /// every surface has to ask now that they share one narrator.
    private(set) var subject: NarrationSubject?

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
    ///
    /// A song and a note have no speakers, and "Narration" over a lyric would
    /// be a label that says nothing at all. What they show instead is the line
    /// itself, which is the same thing the screenplay's highlight shows and the
    /// only thing worth reading on a locked screen.
    var nowReading: String {
        guard let cue = currentCue else { return "Paused" }
        if let speaker = cue.speaker, cue.kind.isSpoken { return speaker }
        return source.namesTheNarrator ? "Narration" : cue.text
    }

    /// Whether the options menu's "Read" section applies to what is loaded.
    var offersScriptOptions: Bool { source.offersScriptOptions }

    /// What the transport's two arrows step by, in this document's own word.
    var elementNoun: String { source.elementNoun }

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

    /// Multiplier on the system's default speaking rate. What it takes to get
    /// there is `NarrationSpeed`'s problem — the dial the synthesizer offers is
    /// nothing like a multiplier.
    var speed: Double {
        didSet {
            let clamped = NarrationSpeed.clamped(speed)
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
            requeue()
        }
    }

    static let minSpeed = NarrationSpeed.minimum
    static let maxSpeed = NarrationSpeed.maximum
    static let speedChoices = NarrationSpeed.choices

    /// The chosen voice, or nil for the best the device has — see
    /// `narratorVoice`.
    var voiceIdentifier: String? {
        didSet {
            guard voiceIdentifier != oldValue else { return }
            if let voiceIdentifier {
                defaults.set(voiceIdentifier, forKey: Key.voice)
            } else {
                defaults.removeObject(forKey: Key.voice)
            }
            resolveNarratorVoice()
            buildCast()
            requeue()
        }
    }

    /// What the device has, as this file sorts voices. Held rather than asked
    /// for: building a run asks who is speaking once per cue, and a feature
    /// screenplay is thousands of cues. The device tells us when the set
    /// changes — a voice downloaded in Settings arrives here without a relaunch.
    private(set) var installedVoices: [NarrationVoice] = []

    /// The voices worth offering, best-sounding first — `NarrationVoices` has
    /// the rules and the reasons. The device's own answer is an inventory
    /// rather than a menu: it holds the joke voices and it holds the same voice
    /// twice when a better download of it exists.
    var availableVoices: [NarrationVoice] {
        NarrationVoices.offered(from: installedVoices,
                                language: AVSpeechSynthesisVoice.currentLanguageCode(),
                                keeping: voiceIdentifier)
    }

    /// The voice the narrator reads in, and the one every character shares
    /// unless the cast is being cast.
    private(set) var narratorVoice: AVSpeechSynthesisVoice?

    /// What "Default" actually resolves to, which the menu names: the system's
    /// voice for this language, upgraded to the best edition of it the device
    /// has been given. A writer who downloaded a good voice downloaded it to be
    /// used, and the system default stays the small built-in one regardless.
    var defaultVoiceName: String? {
        guard let identifier = defaultVoiceIdentifier else { return nil }
        return installedVoices.first { $0.identifier == identifier }?.label
    }

    /// Whether the device has anything better than its built-in voices. When it
    /// does not, no amount of choosing improves the reading and the menu says
    /// where better ones come from.
    var hasDownloadedVoice: Bool { NarrationVoices.hasDownloadedVoice(availableVoices) }

    @ObservationIgnored private var defaultVoiceIdentifier: String?

    // MARK: - The writer's own voice

    /// Whether this device will hand over the writer's Personal Voice — the
    /// one they recorded of themselves, which outranks every download.
    ///
    /// `speechVoices()` leaves personal voices out of the inventory entirely
    /// until an app has been granted them, so without the request below the
    /// top grade this app sorts by was a case that could never happen: the
    /// menu could not offer the best voice on the device, and never said why.
    ///
    /// Asked for on demand rather than at launch. It raises a system prompt,
    /// and a prompt about voices makes sense while the writer is looking at
    /// the list of them — not while they are opening a screenplay.
    private(set) var personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    /// Whether it is worth offering: the request has not been made yet, and
    /// this device is one that can answer it. A device with no Personal Voice
    /// recorded reports `.unsupported`, and asking there is a prompt that
    /// leads nowhere.
    var canRequestPersonalVoice: Bool { personalVoiceStatus == .notDetermined }

    /// Asks for the writer's Personal Voice, and takes the inventory again if
    /// it is granted — the new voice is in the picker without a relaunch.
    func requestPersonalVoice() {
        guard canRequestPersonalVoice else { return }
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            // Resolved on the way in, not inside the hop — see the voices
            // notification below: reading a weak reference from inside
            // concurrently-executing code is a read of storage another thread
            // may be clearing.
            guard let self else { return }
            Task { @MainActor in
                self.personalVoiceStatus = status
                guard status == .authorized else { return }
                self.refreshVoices()
                // Nothing was chosen, so the reading is on whatever "Default"
                // resolves to — and it has just changed underneath a queue
                // with the old voice baked into every utterance.
                if self.voiceIdentifier == nil { self.requeue() }
            }
        }
    }

    /// Takes the device's inventory again, and works out what "Default" means
    /// on it. Called once at startup and whenever the device's voices change.
    private func refreshVoices() {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        installedVoices = AVSpeechSynthesisVoice.speechVoices().map(Self.described)
        defaultVoiceIdentifier = NarrationVoices.best(
            from: NarrationVoices.offered(from: installedVoices, language: language),
            systemDefault: AVSpeechSynthesisVoice(language: language).map(Self.described)
        )?.identifier
        resolveNarratorVoice()
        // A voice that has just arrived is one the cast can use.
        buildCast()
    }

    private func resolveNarratorVoice() {
        let wanted = voiceIdentifier ?? defaultVoiceIdentifier
        narratorVoice = wanted.flatMap(AVSpeechSynthesisVoice.init(identifier:))
    }

    /// An `AVSpeechSynthesisVoice` as the sorting in `NarrationVoices` sees it.
    private static func described(_ voice: AVSpeechSynthesisVoice) -> NarrationVoice {
        let grade: NarrationVoiceGrade
        if voice.voiceTraits.contains(.isPersonalVoice) {
            grade = .personal
        } else {
            switch voice.quality {
            case .premium: grade = .premium
            case .enhanced: grade = .enhanced
            default: grade = .compact
            }
        }
        return NarrationVoice(identifier: voice.identifier,
                              name: voice.name,
                              language: voice.language,
                              grade: grade,
                              isNovelty: voice.voiceTraits.contains(.isNoveltyVoice))
    }

    /// One character's part: the voice, and how far off its natural pitch —
    /// which is what tells two characters apart once there are more of them
    /// than the device has voices. See `NarrationVoices.part(at:poolSize:)`.
    struct CastPart {
        let voice: AVSpeechSynthesisVoice
        let pitch: Double
    }

    /// Who is reading which part, when distinct voices are on. Empty otherwise.
    private(set) var cast: [String: CastPart] = [:]

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
    /// Set when a setting that is baked into every queued utterance — the
    /// voice, the speed, what is read at all — changed while the reading was
    /// paused. See `resume()`.
    @ObservationIgnored private var queueIsStale = false
    /// What the current run was built from, kept so it can be rebuilt when an
    /// option changes without the screen handing the words back.
    @ObservationIgnored private var source: NarrationSource = .script([])
    /// Which cue each queued utterance says. Cleared before re-queuing, which
    /// is what makes callbacks from a cancelled queue harmless.
    @ObservationIgnored private var utteranceIndex: [ObjectIdentifier: Int] = [:]
    /// The device telling us it has been given a voice, or lost one.
    @ObservationIgnored private var voicesChanged: (any NSObjectProtocol)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedSpeed = defaults.object(forKey: Key.speed) as? Double
        // A speed saved before the scale was measured can be one the engine
        // never actually delivered — a stored "0.5×" was a hair under
        // three-quarter pace in practice — so it comes back clamped.
        speed = NarrationSpeed.clamped(storedSpeed ?? 1.0)
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

        refreshVoices()
        // A writer sent to Settings for a better voice comes back to an app
        // that already has it, rather than to the same list and a relaunch.
        voicesChanged = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Bound here rather than inside the `Task`. The notification arrives
            // on whatever queue the system picks, so reaching through the weak
            // reference from inside concurrently-executing code is a read of
            // mutable storage that another thread may be clearing — which is
            // what the compiler was warning about, and an error under Swift 6.
            // Resolving it once on the way in leaves the hop with a value.
            guard let self else { return }
            Task { @MainActor in self.refreshVoices() }
        }
    }

    deinit {
        if let voicesChanged { NotificationCenter.default.removeObserver(voicesChanged) }
    }

    // MARK: - Loading

    /// Points the narrator at a screenplay, a song or a note.
    ///
    /// Safe to call again when the words change underneath it — a run in
    /// progress keeps its place if it can. Handing it a *different* document
    /// ends the reading of the last one rather than keeping a place in words
    /// that are no longer loaded: one voice, one thing being read.
    func prepare(_ source: NarrationSource,
                 subject: NarrationSubject,
                 title: String = "") {
        if title != scriptTitle {
            scriptTitle = title
            publishNowPlaying()
        }
        if subject != self.subject {
            // Whatever was running belonged to something else.
            if isActive { stop() }
            self.subject = subject
            self.source = source
            reload(keepingPlace: false)
            return
        }
        guard source != self.source else { return }
        self.source = source
        reload(keepingPlace: true)
    }

    /// Rebuilds the run, and — when asked and possible — carries the reader's
    /// place across to the cue for the same element.
    private func reload(keepingPlace: Bool) {
        let blockId = keepingPlace ? currentBlockId : nil
        cues = source.cues(options: options)
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
            // Paused, and the words themselves have changed underneath the
            // queue that is sitting in the synthesizer.
            queueIsStale = true
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

    /// Starts from the first readable element at or after the one named — for
    /// a caller naming a *place* rather than an element, like the script
    /// screen starting from wherever the writer is: the element in view may
    /// itself be one the reading skips (a note, a synopsis, a page break).
    func play(atOrAfter blockId: Int) {
        guard hasSomethingToRead else { return }
        let elements = source.elementIds
        guard let start = elements.firstIndex(of: blockId) else {
            play()
            return
        }
        var firstCue: [Int: Int] = [:]
        for cue in cues where firstCue[cue.blockId] == nil {
            firstCue[cue.blockId] = cue.index
        }
        for element in elements[start...] {
            if let index = firstCue[element] {
                speak(from: index)
                return
            }
        }
        // Nothing readable from here down — the place named was the tail end,
        // so the reading starts over rather than declining to start.
        play()
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
        // A voice or a speed chosen while paused is a setting the writer
        // changed *in order to hear it*, and the queue sitting in the
        // synthesizer was built with the old one baked into every utterance —
        // so resuming that queue would carry on in the voice they just left.
        if queueIsStale, let currentIndex {
            speak(from: currentIndex)
            return
        }
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
        queueIsStale = false
        utteranceIndex.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        playback = .idle
        currentIndex = nil
        // Nothing is being read, so nothing owns the voice — and no screen
        // should recognise the run that has just ended as its own.
        subject = nil
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
        queueIsStale = false

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
            // The pause in front of a cue is the air between it and the cue
            // before it — and at the head of the queue there is no cue before
            // it, only a writer who has just pressed play. Three quarters of a
            // second of silence there reads as a button that did not work.
            let utterance = utterance(for: cue, opening: cue.index == index)
            utteranceIndex[ObjectIdentifier(utterance)] = cue.index
            synthesizer.speak(utterance)
        }
    }

    /// A setting baked into the queued utterances has changed. A reading in
    /// progress is rebuilt around where it is; a paused one is marked, because
    /// re-queueing it would mean starting it.
    private func requeue() {
        guard let currentIndex else { return }
        if playback == .speaking {
            speak(from: currentIndex)
        } else if playback == .paused {
            queueIsStale = true
        }
    }

    private func utterance(for cue: NarrationCue, opening: Bool = false) -> AVSpeechUtterance {
        let part = part(for: cue)
        let utterance = AVSpeechUtterance(string: cue.text)
        utterance.voice = part?.voice ?? narratorVoice
        utterance.rate = rate
        utterance.preUtteranceDelay = opening ? 0 : cue.pause
        // The narrator sits a shade below the cast, which is enough to tell
        // the page apart from the people even on one voice. A cast member
        // brings their own pitch: the same voice a second time round the list
        // is shifted so the two characters are not the same person.
        utterance.pitchMultiplier = Float(part?.pitch ?? (cue.kind.isSpoken ? 1.0 : 0.95))
        return utterance
    }

    /// The synthesizer's rate is an absolute 0…1 whose two halves are on
    /// different scales, so the writer's multiplier goes through the measured
    /// curve in `NarrationSpeed` rather than being multiplied into it. Doing
    /// the obvious thing put "2×" at the top of the dial, which is four times
    /// the default pace and not words any more.
    private var rate: Float {
        min(AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, NarrationSpeed.rate(forSpeed: speed)))
    }

    /// The part this cue is read as, when it belongs to a cast character.
    /// Nil is the narrator: their own voice, and the page's pitch.
    private func part(for cue: NarrationCue) -> CastPart? {
        guard cue.kind.isSpoken, let speaker = cue.speaker else { return nil }
        return cast[speaker]
    }

    /// Hands the installed voices out to the speaking parts, in the order they
    /// first speak. The narrator's own voice is held back so the page and the
    /// people never sound the same; when there are more characters than voices
    /// the list wraps, and each time round it the pitch shifts so that the
    /// wrap is a shortage rather than two characters nobody can tell apart.
    ///
    /// The pool is the offered list, so the best-sounding voices are cast
    /// first and the joke voices are cast never. That filter matters more here
    /// than in the picker: nobody chooses Trinoids, but a cast walking down the
    /// device's raw list is handed it without being asked.
    private func buildCast() {
        cast.removeAll()
        guard options.usesDistinctVoices else { return }
        let pool = NarrationVoices.cast(from: availableVoices,
                                        narrator: narratorVoice?.identifier)
            .compactMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        guard !pool.isEmpty else { return }
        for (offset, speaker) in ScriptNarration.speakers(in: cues).enumerated() {
            let part = NarrationVoices.part(at: offset, poolSize: pool.count)
            cast[speaker] = CastPart(voice: pool[part.index], pitch: part.pitch)
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
        queueIsStale = false
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
