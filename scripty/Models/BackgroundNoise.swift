//
//  BackgroundNoise.swift
//  scripty
//
//  Something to write to: a bed of noise the device makes for itself.
//
//  Made rather than played back. Every sound here is generated a sample at a
//  time from a random number and a couple of filters, which is why the app
//  ships no audio at all — no loop to download, no recording to license, and
//  nothing that gives itself away by looping every thirty seconds, since it
//  never repeats.
//
//  The four are honest about what they are. "Rain" is a hiss with the bottom
//  taken off it and a slow flutter over the top: rain against a window rather
//  than a recording of a storm. "Waves" is a rumble that swells and falls, with
//  a little hiss riding the crest. The other two are noise by their proper
//  names — pink, which is the hiss of a room, and brown, which is the rumble
//  under one.
//
//  Deliberately Foundation-only, and deliberately deterministic: seeded with
//  the same number the generator produces the same samples every run, so how
//  loud each sound is can be *measured* in a test rather than trusted. That
//  matters more than it sounds. Brown noise at the same peak as white is barely
//  audible, so without the measured trims below, switching from Rain to Waves
//  would drop the bed to nothing and switching back would take the writer's
//  head off. The engine that plays this lives in `BackgroundNoisePlayer`.
//

import Foundation

/// The four beds on offer.
enum BackgroundNoiseSound: String, CaseIterable, Identifiable, Sendable {
    case rain
    case waves
    /// Pink noise — the flat-to-the-ear hiss.
    case hush
    /// Brown noise — the low end of the same idea.
    case rumble

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rain: return "Rain"
        case .waves: return "Waves"
        case .hush: return "Hush"
        case .rumble: return "Rumble"
        }
    }

    var systemImage: String {
        switch self {
        case .rain: return "cloud.rain"
        case .waves: return "water.waves"
        case .hush: return "wind"
        case .rumble: return "waveform.path"
        }
    }
}

/// How loud the bed sits, as the menu offers it.
///
/// Five steps rather than a slider: a slider in a menu is a thing to miss with
/// a thumb, and the difference between 42% and 46% of a hiss is not a choice
/// anyone is making. The dial is squared on its way to the engine — see
/// `gain(forVolume:)`.
enum BackgroundNoiseVolume {
    static let choices: [Double] = [0.15, 0.3, 0.5, 0.75, 1.0]

    /// Where a first run starts: present enough to hear over a quiet room,
    /// quiet enough that nobody reaches for the side button.
    static let `default` = 0.3

    static let minimum = 0.05
    static let maximum = 1.0

    static func clamped(_ volume: Double) -> Double {
        guard volume.isFinite else { return `default` }
        return min(maximum, max(minimum, volume))
    }

    static func label(_ volume: Double) -> String {
        switch volume {
        case ..<0.22: return "Faint"
        case ..<0.4: return "Quiet"
        case ..<0.62: return "Medium"
        case ..<0.87: return "Loud"
        default: return "Full"
        }
    }

    /// The dial squared. Loudness is not linear in amplitude — halving the
    /// number halves the *voltage*, which the ear hears as a good deal more
    /// than half — so a straight 0…1 dial spends four of its five steps in the
    /// top of the range and nothing usable at the bottom. Squaring puts "Faint"
    /// where the word means something.
    static func gain(forVolume volume: Double) -> Double {
        let dial = clamped(volume)
        return dial * dial
    }
}

/// The bed itself, a sample at a time.
///
/// A value type holding its own filter state, so a test can run one for a
/// second of audio and measure what came out. The player keeps exactly one,
/// and only the audio thread touches it once playing has started.
struct BackgroundNoiseGenerator {
    let sound: BackgroundNoiseSound

    private let sampleRate: Double
    private var random: NoiseRandom

    /// Pink noise by Paul Kellet's three-pole approximation — the cheap one
    /// that is flat enough to −20 dB and costs three multiplies a sample.
    private var pinkA = 0.0
    private var pinkB = 0.0
    private var pinkC = 0.0
    /// Brown noise: white, integrated, with the leak that stops the integrator
    /// wandering off the bottom of the range and staying there.
    private var brown = 0.0
    /// One-pole high pass, for the rain's missing bottom end.
    private var highPassX = 0.0
    private var highPassY = 0.0
    /// The two slow movements: the wave's swell and the rain's flutter, each
    /// stepped by phase so neither needs a running clock.
    private var swellPhase = 0.0
    private var flutterPhase = 0.0

    init(sound: BackgroundNoiseSound, sampleRate: Double = 44_100, seed: UInt64 = 0x5C817B9) {
        self.sound = sound
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        self.random = NoiseRandom(seed: seed)
    }

    /// The next sample, before the writer's volume is applied. Nominally
    /// −20 dBFS whichever sound this is; see `BackgroundNoiseSound.levelTrim`.
    mutating func next() -> Float {
        let white = random.next()

        let shaped: Double
        switch sound {
        case .hush:
            shaped = pink(white)
        case .rumble:
            shaped = brownNoise(white)
        case .rain:
            // Pink with the low end lifted out of it, then a slow breathing
            // over the whole thing. Rain on glass is mostly the top three
            // octaves; leaving the rumble in makes it a motorway.
            let bright = highPass(pink(white), cutoff: 700)
            flutterPhase = advance(flutterPhase, hertz: 0.23)
            let flutter = 1 + 0.18 * sin(flutterPhase)
            shaped = bright * flutter
        case .waves:
            // A swell that takes eleven seconds to come and go, with a wash of
            // hiss that only arrives at the crest — surf is a rumble until it
            // breaks, and the hiss is the break.
            swellPhase = advance(swellPhase, hertz: 1.0 / 11.0)
            let swell = 0.35 + 0.65 * (0.5 - 0.5 * cos(swellPhase))
            let body = brownNoise(white) * swell
            let foam = pink(white) * 0.22 * swell * swell
            shaped = body + foam
        }

        // Trimmed to a common level, then held inside the range. The clamp is
        // a backstop rather than a shaper: at −20 dBFS nominal these peak
        // between a third and three-quarters of full scale, so it should never
        // come near — and `Tests/BackgroundNoise` fails if one starts to.
        let trimmed = shaped * sound.levelTrim
        return Float(min(1, max(-1, trimmed)))
    }

    /// A block of samples, for the render thread and for the measuring the
    /// tests do.
    mutating func render(into buffer: inout [Float]) {
        for index in buffer.indices {
            buffer[index] = next()
        }
    }

    // MARK: - Shapes

    private mutating func pink(_ white: Double) -> Double {
        pinkA = 0.99765 * pinkA + white * 0.0990460
        pinkB = 0.96300 * pinkB + white * 0.2965164
        pinkC = 0.57000 * pinkC + white * 1.0526913
        return pinkA + pinkB + pinkC + white * 0.1848
    }

    private mutating func brownNoise(_ white: Double) -> Double {
        brown = (brown + white * 0.02) / 1.02
        return brown
    }

    private mutating func highPass(_ x: Double, cutoff: Double) -> Double {
        let rc = 1 / (2 * .pi * cutoff)
        let dt = 1 / sampleRate
        let a = rc / (rc + dt)
        highPassY = a * (highPassY + x - highPassX)
        highPassX = x
        return highPassY
    }

    private func advance(_ phase: Double, hertz: Double) -> Double {
        let stepped = phase + 2 * .pi * hertz / sampleRate
        return stepped > 2 * .pi ? stepped - 2 * .pi : stepped
    }

    /// What the trims aim at: 0.1 RMS, which is −20 dBFS.
    static let nominalRMS = 0.1
}

extension BackgroundNoiseSound {
    /// What this bed's raw shape has to be multiplied by to land at
    /// `BackgroundNoiseGenerator.nominalRMS`.
    ///
    /// Measured, not guessed: each generator run for twelve seconds and its
    /// RMS read, then scaled so all four land on −20 dBFS. The numbers are
    /// thirty times apart because the shapes are — brown noise carries a
    /// fraction of the level of pink at the same amplitude — which is exactly
    /// why they cannot be left at 1. Untrimmed, Rain and Hush both ran into
    /// the top of the range and clipped, which is a hiss with a buzz in it.
    /// `Tests/BackgroundNoise` re-measures them and fails if any sound drifts
    /// more than a decibel from the rest, so a change to a filter cannot
    /// quietly make one bed twice as loud.
    ///
    /// A switch rather than a table keyed by the enum, so a fifth sound is a
    /// compiler error here until it has been measured — where a table would
    /// have been a crash on the audio thread, or a bed at some arbitrary
    /// level, depending on how the lookup was written.
    ///
    /// Level, not loudness: this equalises what the meter reads, and the ear
    /// still hears Rumble as the quieter of the four because its energy sits
    /// where hearing is least sensitive. That is the right way round for a bed
    /// — the low ones are there to be felt rather than heard — and the volume
    /// steps are for the rest.
    var levelTrim: Double {
        switch self {
        case .rain: return 0.0956
        case .waves: return 0.4100
        case .hush: return 0.0580
        case .rumble: return 1.7549
        }
    }
}

/// SplitMix64, which is four lines and passes the tests that matter for noise.
///
/// Its own rather than `SystemRandomNumberGenerator` for two reasons: the
/// system one cannot be seeded, so nothing about the sound could be measured
/// twice; and it is a syscall's descendant, where this is a multiply and two
/// shifts — which matters when it is called forty-four thousand times a second
/// on the audio thread.
struct NoiseRandom {
    private var state: UInt64

    init(seed: UInt64) {
        // Zero is a fixed point for the mixer, so it is never the state.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// White noise: uniform over −1…1.
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        // The top 53 bits are the well-mixed ones, and 53 is what a Double
        // holds exactly.
        let unit = Double(z >> 11) * (1.0 / 9007199254740992.0)
        return unit * 2 - 1
    }
}
