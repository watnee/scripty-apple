//
//  Background noise checks
//
//  The whole feature is a number generator and a UserDefaults key, and both
//  halves fail silently on a device: a bed at the wrong level is indistinguishable
//  from a writer having set the volume there, and a bed that clips sounds like a
//  cheap recording rather than like a bug. So the levels are measured here, the
//  same way the trims in `BackgroundNoise.swift` were measured in the first
//  place, and the four are held within a decibel of each other for good.
//
//  The generator is seeded, which is what makes any of this possible — the same
//  seed gives the same samples on every machine, so "how loud is Rain" has one
//  answer rather than a distribution.
//
//  Run via Tests/run.sh.
//

import AVFoundation
import Foundation

var failures = 0

func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
    if "\(actual)" == "\(expected)" {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(expected), got \(actual)")
    }
}

func expect(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  PASS  \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

/// A throwaway store per case, so one check cannot colour the next.
func scratch(_ name: String) -> UserDefaults {
    let suite = "scripty.tests.backgroundnoise.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

struct Measurement {
    let rms: Double
    let peak: Double
    let zeroCrossingsPerSecond: Double
    let sampleCount: Int
    var isFinite: Bool
}

/// Runs a bed for a stretch and reports what came out of it.
///
/// Two seconds is the default, and it is not a corner cut: RMS over ninety
/// thousand samples of noise settles to a fraction of a percent, and this file
/// is compiled without optimisation and shares a sixty-second watchdog with
/// suites that are pure arithmetic. Twelve seconds a bed — what the trims were
/// originally measured over — moved the same numbers by hundredths of a
/// decibel and took most of that budget.
func measure(_ sound: BackgroundNoiseSound, seconds: Double = 2,
             sampleRate: Double = 44_100, skipping lead: Double = 0) -> Measurement {
    var generator = BackgroundNoiseGenerator(sound: sound, sampleRate: sampleRate)
    for _ in 0..<Int(lead * sampleRate) { _ = generator.next() }

    let count = Int(seconds * sampleRate)
    var sumOfSquares = 0.0
    var peak = 0.0
    var crossings = 0
    var previous = 0.0
    var finite = true
    for index in 0..<count {
        let sample = Double(generator.next())
        if !sample.isFinite { finite = false }
        sumOfSquares += sample * sample
        peak = max(peak, abs(sample))
        if index > 0, (sample < 0) != (previous < 0) { crossings += 1 }
        previous = sample
    }
    return Measurement(rms: (sumOfSquares / Double(count)).squareRoot(),
                       peak: peak,
                       zeroCrossingsPerSecond: Double(crossings) / seconds,
                       sampleCount: count,
                       isFinite: finite)
}

/// One pass over a bed, reporting the RMS of each second of it — which is how
/// the swell is checked without running Waves twice from the start.
func secondBySecond(_ sound: BackgroundNoiseSound, seconds: Int,
                    sampleRate: Double = 44_100) -> [Double] {
    var generator = BackgroundNoiseGenerator(sound: sound, sampleRate: sampleRate)
    let perSecond = Int(sampleRate)
    return (0..<seconds).map { _ in
        var sumOfSquares = 0.0
        for _ in 0..<perSecond {
            let sample = Double(generator.next())
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Double(perSecond)).squareRoot()
    }
}

func decibels(_ ratio: Double) -> Double { 20 * log10(ratio) }

/// Measured once and read by both the level checks and the shape checks below
/// — the same stretch answers "how loud" and "how bright".
///
/// Waves gets a whole cycle and the rest get two seconds. That is not
/// generosity: its level *is* a swell, eleven seconds from trough to trough,
/// and two seconds of it measures whichever part of the swell those two
/// seconds landed on — 8 dB light, as it happens, since a bed starts at its
/// trough. A steady sound has no such window to get wrong.
let beds = BackgroundNoiseSound.allCases.reduce(into: [BackgroundNoiseSound: Measurement]()) {
    $0[$1] = measure($1, seconds: $1 == .waves ? 11 : 2)
}

func runLevels() {
    print("Every bed at the same level")
    for sound in BackgroundNoiseSound.allCases {
        guard let measured = beds[sound] else { continue }
        let drift = abs(decibels(measured.rms / BackgroundNoiseGenerator.nominalRMS))
        // A decibel is about the smallest step anyone hears on a steady sound,
        // so this is as tight as it can be without failing on arithmetic.
        expect("\(sound.label) sits within a decibel of −20 dBFS", drift < 1.0,
               String(format: "off by %.2f dB (rms %.4f)", drift, measured.rms))
        // Headroom, not a clamp: the clamp in `next()` is a backstop, and if a
        // bed is leaning on it the sound has a buzz in it that no amount of
        // turning down removes.
        expect("\(sound.label) never reaches the top of the range", measured.peak < 0.95,
               String(format: "peaked at %.3f", measured.peak))
        expect("\(sound.label) produces nothing but real numbers", measured.isFinite)
    }
}

func runShapes() {
    print("")
    print("Each bed is the shape it claims")
    guard let rain = beds[.rain], let hush = beds[.hush],
          let rumble = beds[.rumble], let waves = beds[.waves] else { return }

    // Zero crossings stand in for a spectrum analyser: the lower a sound sits,
    // the fewer times a second it crosses the axis. Brown noise measures about
    // a third of pink rather than a tenth — the crossing rate is pulled up by
    // the tail of the spectrum however steeply it falls — so the threshold is
    // half, which is well clear of where the two actually land and still
    // catches a filter change that made Rumble as bright as the hiss.
    expect("Rumble is the low one", rumble.zeroCrossingsPerSecond < hush.zeroCrossingsPerSecond / 2,
           String(format: "rumble %.0f/s vs hush %.0f/s",
                  rumble.zeroCrossingsPerSecond, hush.zeroCrossingsPerSecond))
    expect("Rain is brighter than the room hiss it is filtered from",
           rain.zeroCrossingsPerSecond > hush.zeroCrossingsPerSecond,
           String(format: "rain %.0f/s vs hush %.0f/s",
                  rain.zeroCrossingsPerSecond, hush.zeroCrossingsPerSecond))
    expect("Waves is built on the low one",
           waves.zeroCrossingsPerSecond < rain.zeroCrossingsPerSecond)

    // The swell is the whole of Waves. Seven seconds, a second at a time and
    // in one pass: the cycle takes eleven, so the quietest second and the
    // loudest are both inside that window wherever the phase starts.
    let wavesBySecond = secondBySecond(.waves, seconds: 7)
    let trough = wavesBySecond.min() ?? 0
    let crest = wavesBySecond.max() ?? 0
    expect("Waves swells and falls", crest > trough * 1.5,
           String(format: "trough %.4f, crest %.4f", trough, crest))

    // A steady bed must not do the same thing, or the "swell" above is only
    // the generator warming up.
    //
    // Two decibels, where every other check here holds to one: pink noise
    // carries real energy at fractions of a hertz, so a *second* of it wanders
    // by about a decibel against the next second by nature. That wander is
    // also why the swell above is asked for as a factor of one and a half —
    // three and a half decibels — rather than as anything a second-to-second
    // drift could reach on its own.
    let hushBySecond = secondBySecond(.hush, seconds: 7)
    let spread = abs(decibels((hushBySecond.max() ?? 1) / (hushBySecond.min() ?? 1)))
    expect("Hush holds its level", spread < 2.0,
           String(format: "%.2f dB between its quietest and loudest second", spread))
}

func runSampleRate() {
    print("")
    print("The same bed at the rate the hardware runs at")
    for sound in BackgroundNoiseSound.allCases {
        let at44 = measure(sound, seconds: 1, sampleRate: 44_100)
        let at48 = measure(sound, seconds: 1, sampleRate: 48_000)
        // Same seconds, not same samples: the filters and the two slow
        // movements are all written in hertz, so a device running at 48k must
        // hear the same bed and not a faster one.
        expect("\(sound.label) is the same at 48k as at 44.1k",
               abs(decibels(at48.rms / at44.rms)) < 1.0,
               String(format: "%.4f vs %.4f", at44.rms, at48.rms))
    }
}

func runDeterminism() {
    print("")
    print("Seeded, so any of the above can be measured twice")
    var first = BackgroundNoiseGenerator(sound: .rain, seed: 99)
    var second = BackgroundNoiseGenerator(sound: .rain, seed: 99)
    var third = BackgroundNoiseGenerator(sound: .rain, seed: 100)
    var same = true
    var differs = false
    for _ in 0..<2_000 {
        let a = first.next()
        if a != second.next() { same = false }
        if a != third.next() { differs = true }
    }
    expect("the same seed gives the same bed", same)
    expect("a different seed gives a different one", differs)

    // Zero is the one seed a SplitMix64 state cannot be — it would hand back
    // the same number for ever, which is silence with a DC offset.
    var zeroed = BackgroundNoiseGenerator(sound: .hush, seed: 0)
    var moved = false
    let opening = zeroed.next()
    for _ in 0..<100 where zeroed.next() != opening { moved = true }
    expect("a zero seed still makes noise", moved)
}

func runVolume() {
    print("")
    print("The volume dial")
    check("a first run is not silent", BackgroundNoiseVolume.default, 0.3)
    check("the dial is squared on the way out",
          BackgroundNoiseVolume.gain(forVolume: 0.5), 0.25)
    check("full is full", BackgroundNoiseVolume.gain(forVolume: 1.0), 1.0)
    check("above the top clamps", BackgroundNoiseVolume.clamped(4), 1.0)
    check("below the bottom clamps", BackgroundNoiseVolume.clamped(-1),
          BackgroundNoiseVolume.minimum)
    // A NaN reaches this from a defaults file written by hand, and every
    // comparison against it is false — so a clamp written the obvious way lets
    // it straight through to the mixer, where it is silence at best.
    check("a nonsense volume falls back to the default",
          BackgroundNoiseVolume.clamped(.nan), BackgroundNoiseVolume.default)
    check("the loudest step is named", BackgroundNoiseVolume.label(1.0), "Full")
    check("the quietest step is named", BackgroundNoiseVolume.label(0.15), "Faint")
    expect("every offered step has a name of its own",
           Set(BackgroundNoiseVolume.choices.map(BackgroundNoiseVolume.label)).count
           == BackgroundNoiseVolume.choices.count)
    expect("every offered step survives the clamp",
           BackgroundNoiseVolume.choices.allSatisfy {
               BackgroundNoiseVolume.clamped($0) == $0
           })
}

@MainActor
func runStorage() {
    print("")
    print("What is remembered between launches")
    let store = scratch("choice")
    let player = BackgroundNoisePlayer(defaults: store, playsAloud: false)
    check("rain on a first run", player.sound, BackgroundNoiseSound.rain)
    check("and at the default volume", player.volume, BackgroundNoiseVolume.default)
    check("silent on a first run", player.isPlaying, false)

    player.sound = .waves
    check("the chosen bed is stored", store.string(forKey: "scripty-background-noise") ?? "", "waves")
    check("and survives a relaunch",
          BackgroundNoisePlayer(defaults: store, playsAloud: false).sound, BackgroundNoiseSound.waves)

    player.volume = 0.75
    check("the volume is stored", store.double(forKey: "scripty-background-noise-volume"), 0.75)
    check("and survives a relaunch too",
          BackgroundNoisePlayer(defaults: store, playsAloud: false).volume, 0.75)

    // The point of the whole "not remembered" rule: an app that opens making
    // noise is an app that gets closed.
    check("but a relaunch is silent",
          BackgroundNoisePlayer(defaults: store, playsAloud: false).isPlaying, false)

    // A sound written by some future version — or by hand — must not leave the
    // app pointing at a bed it cannot generate.
    store.set("thunderstorm", forKey: "scripty-background-noise")
    check("an unknown bed falls back to rain",
          BackgroundNoisePlayer(defaults: store, playsAloud: false).sound, BackgroundNoiseSound.rain)

    // `double(forKey:)` answers 0 for a missing key, and 0 is silence — the
    // one wrong answer that looks exactly like a working app with the volume
    // down.
    let empty = scratch("empty")
    check("no stored volume means the default, not silence",
          BackgroundNoisePlayer(defaults: empty, playsAloud: false).volume, BackgroundNoiseVolume.default)

    let daft = scratch("daft")
    daft.set(9.0, forKey: "scripty-background-noise-volume")
    check("a stored volume out of range is clamped on the way in",
          BackgroundNoisePlayer(defaults: daft, playsAloud: false).volume, 1.0)

    // Setting one past the end goes the same way, since the menu is not the
    // only thing that can write it.
    let player2 = BackgroundNoisePlayer(defaults: scratch("assigned"), playsAloud: false)
    player2.volume = 12
    check("and on the way out", player2.volume, 1.0)

    // What the two menus actually bind to: a volume that is not one of the
    // five offered steps must still light one of the five rows.
    player2.volume = 0.41
    check("an odd volume reads back as the nearest step", player2.volumeStep, 0.5)
    player2.volumeStep = 0.15
    check("and picking a step sets it", player2.volume, 0.15)
}

@MainActor
func runPickerBinding() {
    print("")
    print("Off as a choice among the sounds")
    let player = BackgroundNoisePlayer(defaults: scratch("binding"), playsAloud: false)
    check("nothing playing reads as Off", player.playingSound == nil, true)

    // The engine is never started here — there is no audio device in a test
    // run — so what is checked is the bookkeeping the menu reads back.
    player.playingSound = .rumble
    check("picking a bed selects it", player.sound, BackgroundNoiseSound.rumble)
    check("and turns it on", player.isPlaying, true)
    check("which is what the picker reads back", player.playingSound == .rumble, true)

    player.playingSound = nil
    check("Off stops it", player.isPlaying, false)
    // The choice outlives being switched off: turning the bed on again should
    // not hand back rain.
    check("but keeps the choice", player.sound, BackgroundNoiseSound.rumble)

    player.toggle()
    check("the key turns it back on", player.isPlaying, true)
    check("on the bed that was picked", player.playingSound == .rumble, true)
    player.toggle()
    check("and off again", player.isPlaying, false)
}

/// The one piece of this that runs on the audio thread, handed a buffer of the
/// shape `AVAudioSourceNode` hands it.
///
/// Worth its own case because every way it can be wrong sounds identical to a
/// working bed with the volume down: a channel never written, a frame count
/// used as a byte count, an off-by-one that leaves the last frame at zero.
/// Two channels, because the mixer it feeds is not mono even though the source
/// is, and a `for buffer in buffers` that only ever visited the first one would
/// play down one ear.
func runRenderBlock() {
    print("")
    print("Filling a render buffer")
    let frames: AVAudioFrameCount = 512
    let channels = 2

    // Two separate arrays rather than one of two: nesting
    // `withUnsafeMutableBufferPointer` into the same array is two overlapping
    // exclusive accesses, which the compiler refuses outright.
    //
    // Filled with NaN, so "every frame written" is a real question — zeroes
    // would be indistinguishable from a render block that never ran.
    var leftStorage = [Float](repeating: .nan, count: Int(frames))
    var rightStorage = [Float](repeating: .nan, count: Int(frames))
    let bytes = UInt32(Int(frames) * MemoryLayout<Float>.size)
    let listSize = MemoryLayout<AudioBufferList>.size
        + (channels - 1) * MemoryLayout<AudioBuffer>.size
    let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(channels)

    leftStorage.withUnsafeMutableBufferPointer { left in
        rightStorage.withUnsafeMutableBufferPointer { right in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes,
                                     mData: left.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes,
                                     mData: right.baseAddress)

            let voice = NoiseVoice(sound: .hush, sampleRate: 44_100)
            voice.fill(list, frameCount: frames)

            let leftSamples = Array(left)
            let rightSamples = Array(right)
            expect("every frame of the left channel is written",
                   leftSamples.allSatisfy { $0.isFinite })
            expect("every frame of the right channel is written",
                   rightSamples.allSatisfy { $0.isFinite })
            expect("and the two ears get the same bed", leftSamples == rightSamples)
            expect("what is written is not silence",
                   leftSamples.contains { $0 != 0 })

            // The samples are the generator's own, in order — the render block
            // must not skip, repeat, or reorder them.
            var reference = BackgroundNoiseGenerator(sound: .hush, sampleRate: 44_100)
            let expected = (0..<Int(frames)).map { _ in reference.next() }
            expect("in the order the generator makes them", leftSamples == expected)
        }
    }
}

runLevels()
runShapes()
runRenderBlock()
runSampleRate()
runDeterminism()
runVolume()
MainActor.assumeIsolated {
    runStorage()
    runPickerBinding()
}

print("")
if failures == 0 {
    print("All background noise checks passed.")
} else {
    print("\(failures) background noise check(s) failed.")
    exit(1)
}
