//
//  NarrationSpeed.swift
//  scripty
//
//  Turning "one and a half times" into the number the synthesizer wants.
//
//  `AVSpeechUtterance.rate` is not a multiplier and is not linear. It is a
//  0…1 dial whose middle is the default pace, and the two halves are on wildly
//  different scales: the bottom half barely slows anything down, and the top
//  half runs away. Multiplying the default by the writer's choice — which is
//  the obvious reading of the API, and what this app did — puts "2×" at the
//  very top of the dial, and the top of the dial measures 4.04× the default
//  pace: not language any more. That app's "1.5×" measured 2.49×.
//
//  So the scale here is measured rather than assumed. Rendering one sentence to
//  a buffer at each rate and counting the samples gives the pace exactly, and
//  the table below is that measurement — identical, to two decimal places,
//  across Samantha, a Siri voice and Daniel, so it is the engine's curve and
//  not one voice's. Between the measured points the answer is interpolated.
//
//  The floor is the other half of the honesty: the slow end of the dial bottoms
//  out at about three-quarters of the default pace, so a "0.5×" the engine
//  cannot deliver is not offered.
//

import Foundation

enum NarrationSpeed {

    /// The multipliers the menu offers. The slow end stops where the engine
    /// does — see the note above.
    static let choices: [Double] = [0.75, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0]

    static let minimum = 0.75
    static let maximum = 2.0

    static func clamped(_ speed: Double) -> Double {
        min(maximum, max(minimum, speed))
    }

    /// Measured: `rate` on the left, what it does to the pace on the right,
    /// where 1.0 is the pace at the default rate. Rendered to a buffer and
    /// counted in samples, so these are the engine's own numbers.
    ///
    /// The engine quantises — 0.633 and 0.65 come out identical — so the rate
    /// this hands back is a nearest-fit rather than a promise to three
    /// decimal places.
    private static let curve: [(rate: Float, pace: Double)] = [
        (0.200, 0.72),
        (0.300, 0.83),
        (0.400, 0.91),
        (0.500, 1.00),
        (0.525, 1.12),
        (0.550, 1.29),
        (0.585, 1.51),
        (0.600, 1.59),
        (0.633, 1.83),
        (0.680, 2.11),
    ]

    /// The synthesizer's rate for a pace the writer asked for.
    static func rate(forSpeed speed: Double) -> Float {
        let wanted = clamped(speed)
        guard let last = curve.last else { return 0.5 }
        if wanted <= curve[0].pace { return curve[0].rate }
        if wanted >= last.pace { return last.rate }

        for (low, high) in zip(curve, curve.dropFirst()) where wanted <= high.pace {
            let span = high.pace - low.pace
            guard span > 0 else { return low.rate }
            let along = (wanted - low.pace) / span
            return low.rate + Float(along) * (high.rate - low.rate)
        }
        return last.rate
    }

    /// How the choice is written in the menu.
    static func label(_ speed: Double) -> String {
        speed == 1 ? "Normal" : String(format: "%g×", speed)
    }
}
