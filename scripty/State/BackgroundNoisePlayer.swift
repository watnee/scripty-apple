//
//  BackgroundNoisePlayer.swift
//  scripty
//
//  Playing the bed, and remembering which one.
//
//  One player for the app, like the narrator and the demo player before it: a
//  writer who starts the rain in a screenplay and opens a song wants the same
//  rain, not a second one underneath it. Which sound and how loud are device
//  preferences, kept where the appearance and the text size are — the account
//  is read on a train with headphones and at a desk with the door shut, and
//  only one of those wants surf.
//
//  What is deliberately *not* remembered is whether it was playing. An app that
//  starts making noise the moment it opens is an app that gets closed on a
//  quiet carriage; the sound the writer picked is waiting in the menu, one tap
//  away, and that is the right side of the trade.
//
//  The session is claimed as a bed rather than as the thing being listened to.
//  Read Aloud and a song's demo both take the session as `.playback` and mean
//  it — they are what you are listening to, so they interrupt whatever else the
//  device was doing. This one asks for `.mixWithOthers`, which is the whole
//  point of it: it sits under Read Aloud, under a demo take, and under the
//  writer's own music from another app. It also never deactivates the session,
//  for the same reason — yanking it out from under a narration that is halfway
//  through a scene would be a strange thing for a hiss to do.
//

import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class BackgroundNoisePlayer {
    /// Shared: the bed belongs to the app, not to a screen.
    static let shared = BackgroundNoisePlayer()

    /// Which bed the writer picked. Remembered whether or not it is playing —
    /// turning the sound off and on again should not lose the choice.
    var sound: BackgroundNoiseSound {
        didSet {
            guard sound != oldValue else { return }
            defaults.set(sound.rawValue, forKey: Key.sound)
            if isPlaying { restart() }
        }
    }

    /// 0…1 as the menu offers it, squared on its way to the engine.
    var volume: Double {
        didSet {
            let clamped = BackgroundNoiseVolume.clamped(volume)
            if clamped != volume {
                volume = clamped
                return
            }
            guard volume != oldValue else { return }
            defaults.set(volume, forKey: Key.volume)
            // Straight to the target rather than through a fade: the writer is
            // holding the menu open and listening for the difference.
            if isPlaying { setMixerVolume(Float(BackgroundNoiseVolume.gain(forVolume: volume))) }
        }
    }

    private(set) var isPlaying = false

    /// Said out loud rather than swallowed. A bed that will not start looks
    /// exactly like a bed at zero volume, and a writer cannot tell those apart
    /// by listening — which is the only way they would find out.
    private(set) var errorMessage: String?

    /// The volume as the menus offer it: snapped to the nearest of the five
    /// steps on the way out, so a number written by some future version — or
    /// by hand into the defaults — still lights one of the five rows instead
    /// of leaving the picker showing nothing selected. Two menus read this, and
    /// a rounding rule written twice is a rounding rule that will differ.
    var volumeStep: Double {
        get {
            BackgroundNoiseVolume.choices.min {
                abs($0 - volume) < abs($1 - volume)
            } ?? BackgroundNoiseVolume.default
        }
        set { volume = newValue }
    }

    /// The picker's binding, where "off" is a choice rather than a switch
    /// beside one. Setting a sound starts it; setting nil stops it.
    var playingSound: BackgroundNoiseSound? {
        get { isPlaying ? sound : nil }
        set {
            guard let newValue else {
                stop()
                return
            }
            sound = newValue
            start()
        }
    }

    // MARK: - Starting and stopping

    func start() {
        guard !isPlaying else { return }
        isPlaying = true
        errorMessage = nil
        buildAndStart()
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        fadeOutAndTearDown()
    }

    func toggle() {
        isPlaying ? stop() : start()
    }

    // MARK: - Storage

    private enum Key {
        static let sound = "scripty-background-noise"
        static let volume = "scripty-background-noise-volume"
    }

    private let defaults: UserDefaults

    /// Whether this player may touch the audio hardware.
    ///
    /// False in the checks under `Tests/`, and for two reasons rather than
    /// tidiness: a test machine may have no audio device at all, so the engine
    /// would refuse to start and every check about what the menu reads back
    /// would fail for the wrong reason — and a machine that *does* have one
    /// would sit there playing surf through a build. The bookkeeping is
    /// identical either way; only the engine is skipped.
    private let playsAloud: Bool

    init(defaults: UserDefaults = .standard, playsAloud: Bool = true) {
        self.defaults = defaults
        self.playsAloud = playsAloud
        // Rain on a first run: of the four it is the one that sounds like
        // somewhere rather than like a signal.
        let stored = defaults.string(forKey: Key.sound)
        sound = stored.flatMap(BackgroundNoiseSound.init(rawValue:)) ?? .rain
        // `double(forKey:)` answers 0 for a key that was never written, which
        // is silence — so the presence of the key is what decides, not its
        // value.
        if defaults.object(forKey: Key.volume) != nil {
            volume = BackgroundNoiseVolume.clamped(defaults.double(forKey: Key.volume))
        } else {
            volume = BackgroundNoiseVolume.default
        }
        observeInterruptions()
    }

    // MARK: - The engine

    private var engine: AVAudioEngine?
    private var fade: Task<Void, Never>?
    /// Set while an interruption — a call, another app taking the session —
    /// has the bed stopped, so it knows to come back when the call ends.
    private var interrupted = false

    private func buildAndStart() {
        tearDown()
        guard playsAloud else { return }
        claimSession()

        let engine = AVAudioEngine()
        // The hardware's own rate, asked of the output rather than assumed:
        // 44.1k on some devices, 48k on others, and a generator running at the
        // wrong one is a bed at the wrong pitch — which for a wave that takes
        // eleven seconds to break is an audible difference.
        let output = engine.outputNode
        let hardwareRate = output.inputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            fail("This device would not give the sound a format to play in.")
            return
        }

        let voice = NoiseVoice(sound: sound, sampleRate: sampleRate)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            voice.fill(audioBufferList, frameCount: frameCount)
            return noErr
        }

        engine.attach(source)
        // Through the main mixer, which is also the volume control: mono in,
        // whatever the device wants out, and one `outputVolume` to fade.
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        do {
            try engine.start()
        } catch {
            fail("The sound would not start. \(error.localizedDescription)")
            return
        }

        self.engine = engine
        // Up from silence rather than straight in at the chosen level: noise
        // that arrives at full volume in one sample is a click, and a click is
        // the one thing a bed must never do.
        fadeMixer(to: Float(BackgroundNoiseVolume.gain(forVolume: volume)), over: 0.8)
    }

    /// The same sound at a different shape — the writer changed their mind
    /// mid-hiss. Out and back rather than swapped underneath: the generator is
    /// the audio thread's to touch once it is running, and reaching into it
    /// from here is the kind of race that is heard once a fortnight and never
    /// reproduced.
    private func restart() {
        fade?.cancel()
        fade = Task { [weak self] in
            await self?.rampMixer(to: 0, over: 0.25)
            guard let self, !Task.isCancelled, isPlaying else { return }
            buildAndStart()
        }
    }

    private func fadeOutAndTearDown() {
        fade?.cancel()
        fade = Task { [weak self] in
            await self?.rampMixer(to: 0, over: 0.5)
            guard let self, !Task.isCancelled, !isPlaying else { return }
            tearDown()
        }
    }

    private func tearDown() {
        fade?.cancel()
        fade = nil
        engine?.stop()
        engine = nil
    }

    private func fail(_ message: String) {
        tearDown()
        isPlaying = false
        errorMessage = message
    }

    // MARK: - Volume

    private func setMixerVolume(_ value: Float) {
        fade?.cancel()
        fade = nil
        engine?.mainMixerNode.outputVolume = value
    }

    private func fadeMixer(to target: Float, over seconds: Double) {
        fade?.cancel()
        fade = Task { [weak self] in
            await self?.rampMixer(to: target, over: seconds)
        }
    }

    /// Forty steps a second, which is smooth enough that nobody hears the
    /// staircase and cheap enough to be beneath noticing.
    private func rampMixer(to target: Float, over seconds: Double) async {
        guard let engine else { return }
        let steps = max(1, Int(seconds * 40))
        let start = engine.mainMixerNode.outputVolume
        for step in 1...steps {
            if Task.isCancelled { return }
            let along = Float(step) / Float(steps)
            engine.mainMixerNode.outputVolume = start + (target - start) * along
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
        }
        if !Task.isCancelled {
            engine.mainMixerNode.outputVolume = target
        }
    }

    // MARK: - The session, and what interrupts it

    private func claimSession() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        // `.playback` so it keeps going with the screen off — a bed that stops
        // when the phone locks is a bed that stops every time you look away —
        // and `.mixWithOthers` so it is a bed and not a broadcast.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    /// A call arrives, or another app takes the session outright: the engine is
    /// stopped for us either way, and without this it never comes back — the
    /// menu would go on saying Rain over silence.
    private func observeInterruptions() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance(),
                           queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated {
                self?.handleInterruption(info)
            }
        }
        // A route change — headphones out, a car disconnecting — can stop the
        // engine's graph without an interruption ever being posted.
        center.addObserver(forName: .AVAudioEngineConfigurationChange,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard isPlaying else { return }
            interrupted = true
            tearDown()
        case .ended:
            guard interrupted, isPlaying else { return }
            interrupted = false
            // The system says whether picking back up is welcome; a writer who
            // answered a call and is still on it does not want rain in the
            // background of it.
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume) {
                buildAndStart()
            } else {
                isPlaying = false
            }
        @unknown default:
            break
        }
    }

    private func handleConfigurationChange() {
        guard isPlaying, !interrupted else { return }
        // Rebuilt rather than restarted: the new route may run at another rate
        // entirely, and the generator is built around the one it was given.
        buildAndStart()
    }
    #endif
}

/// The generator, in a box the audio thread can own.
///
/// `AVAudioSourceNode` calls its block on a real-time thread, so what it
/// touches cannot be main-actor state and cannot take a lock. This holds the
/// generator and nothing else, is filled in before the node is attached, and
/// is read only by that thread afterwards — which is what the unchecked
/// conformance is asserting. Changing the sound builds a new one rather than
/// writing to this one; see `restart()`.
///
/// Not private, and `fill` is a method rather than the three lines it replaced
/// inside the render block, for one reason: this is the only code in the app
/// that runs on the audio thread, and a bug in it — a channel left untouched,
/// a frame count read the wrong way round — is *silence*, which is what a
/// working bed with the volume down also sounds like. Being reachable is what
/// lets `Tests/BackgroundNoise` hand it a buffer and check what comes back.
final class NoiseVoice: @unchecked Sendable {
    private var generator: BackgroundNoiseGenerator

    init(sound: BackgroundNoiseSound, sampleRate: Double) {
        generator = BackgroundNoiseGenerator(sound: sound, sampleRate: sampleRate)
    }

    func next() -> Float {
        generator.next()
    }

    /// Fill every channel of a render request with the same bed.
    ///
    /// One sample serves all channels: the source is mono by construction, and
    /// a bed that differed between the ears would be a bed you could hear
    /// yourself turning your head in.
    func fill(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
              frameCount: AVAudioFrameCount) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let sample = next()
            for buffer in buffers {
                let samples = UnsafeMutableBufferPointer<Float>(buffer)
                // A buffer shorter than the frame count is the render thread
                // telling us it has less room than it asked for; writing past
                // it is a crash in someone else's memory.
                if frame < samples.count { samples[frame] = sample }
            }
        }
    }
}
