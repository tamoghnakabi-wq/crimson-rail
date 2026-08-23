import Foundation
import Accelerate

/// A small DSP toolkit and the recipes for every sound in the game.
///
/// Nothing is loaded from disk: gunshots, groans, ambience and music are all
/// synthesised at launch into PCM buffers. That keeps the app self-contained and
/// sidesteps sample licensing entirely, at the cost of a few hundred
/// milliseconds of start-up.
enum Synth {
    static let sampleRate: Float = 44_100

    // MARK: - Primitives

    /// Mono sample buffer with the helpers the recipes need.
    struct Buf {
        var s: [Float]
        init(seconds: Float) { s = [Float](repeating: 0, count: max(1, Int(seconds * sampleRate))) }
        init(_ samples: [Float]) { s = samples }
        var count: Int { s.count }

        mutating func mix(_ other: Buf, gain: Float = 1, offset: Int = 0) {
            for i in 0..<other.count {
                let j = i + offset
                guard j >= 0, j < s.count else { continue }
                s[j] += other.s[i] * gain
            }
        }

        mutating func gain(_ g: Float) { for i in s.indices { s[i] *= g } }

        /// Peak-normalises to `peak`, then applies a soft clip so nothing spikes.
        mutating func normalize(_ peak: Float = 0.9) {
            var maxAbs: Float = 0
            vDSP_maxmgv(s, 1, &maxAbs, vDSP_Length(s.count))
            guard maxAbs > 1e-6 else { return }
            let g = peak / maxAbs
            for i in s.indices { s[i] = tanh(s[i] * g * 1.15) * 0.92 }
        }

        /// Short fades so a buffer never starts or ends on a click.
        mutating func deClick(fadeIn: Float = 0.002, fadeOut: Float = 0.01) {
            let nIn = min(Int(fadeIn * sampleRate), count / 2)
            let nOut = min(Int(fadeOut * sampleRate), count / 2)
            for i in 0..<nIn { s[i] *= Float(i) / Float(max(nIn, 1)) }
            for i in 0..<nOut { s[count - 1 - i] *= Float(i) / Float(max(nOut, 1)) }
        }

        var rms: Float {
            guard !s.isEmpty else { return 0 }
            var acc: Float = 0
            vDSP_measqv(s, 1, &acc, vDSP_Length(s.count))
            return sqrt(acc)
        }
        var peak: Float {
            var m: Float = 0
            vDSP_maxmgv(s, 1, &m, vDSP_Length(s.count))
            return m
        }
    }

    /// Exponential decay envelope; `curve` > 1 makes the tail snappier.
    static func envelope(_ n: Int, attack: Float, decay: Float, curve: Float = 2.2) -> [Float] {
        var e = [Float](repeating: 0, count: n)
        let a = max(Int(attack * sampleRate), 1)
        for i in 0..<n {
            if i < a {
                e[i] = Float(i) / Float(a)
            } else {
                let t = Float(i - a) / sampleRate
                e[i] = exp(-t / max(decay, 1e-4) * curve)
            }
        }
        return e
    }

    static func noise(_ n: Int, rng: inout Rand) -> Buf {
        var b = Buf([Float](repeating: 0, count: n))
        for i in 0..<n { b.s[i] = rng.float(-1, 1) }
        return b
    }

    /// Sine with an optional exponential frequency sweep.
    static func tone(_ n: Int, from f0: Float, to f1: Float? = nil, phase: Float = 0) -> Buf {
        var b = Buf([Float](repeating: 0, count: n))
        var ph = phase
        let f1 = f1 ?? f0
        for i in 0..<n {
            let t = Float(i) / Float(max(n - 1, 1))
            let f = f0 * pow(max(f1 / max(f0, 1e-3), 1e-3), t)
            ph += 2 * .pi * f / sampleRate
            b.s[i] = sin(ph)
        }
        return b
    }

    /// Band-limited-ish saw, for musical content.
    static func saw(_ n: Int, freq: Float, harmonics: Int = 12) -> Buf {
        var b = Buf([Float](repeating: 0, count: n))
        for h in 1...harmonics {
            let f = freq * Float(h)
            guard f < sampleRate / 2.2 else { break }
            let amp = 1 / Float(h)
            var ph: Float = 0
            let inc = 2 * .pi * f / sampleRate
            for i in 0..<n {
                b.s[i] += sin(ph) * amp
                ph += inc
            }
        }
        return b
    }

    // MARK: Filters

    /// State-variable filter — one pass gives low, band and high outputs, which
    /// is exactly what these recipes keep needing.
    static func svf(_ input: Buf, cutoff: Float, q: Float, mode: FilterMode) -> Buf {
        var out = Buf([Float](repeating: 0, count: input.count))
        let f = 2 * sin(.pi * min(cutoff, sampleRate * 0.45) / sampleRate)
        let damp = 1 / max(q, 0.5)
        var low: Float = 0, band: Float = 0
        for i in 0..<input.count {
            let high = input.s[i] - low - damp * band
            band += f * high
            low += f * band
            switch mode {
            case .low: out.s[i] = low
            case .band: out.s[i] = band
            case .high: out.s[i] = high
            }
        }
        return out
    }

    enum FilterMode { case low, band, high }

    /// Sweeping filter, for whooshes and formant movement.
    static func svfSweep(_ input: Buf, from c0: Float, to c1: Float, q: Float, mode: FilterMode) -> Buf {
        var out = Buf([Float](repeating: 0, count: input.count))
        var low: Float = 0, band: Float = 0
        let damp = 1 / max(q, 0.5)
        for i in 0..<input.count {
            let t = Float(i) / Float(max(input.count - 1, 1))
            let cutoff = c0 * pow(max(c1 / max(c0, 1e-3), 1e-3), t)
            let f = 2 * sin(.pi * min(cutoff, sampleRate * 0.45) / sampleRate)
            let high = input.s[i] - low - damp * band
            band += f * high
            low += f * band
            switch mode {
            case .low: out.s[i] = low
            case .band: out.s[i] = band
            case .high: out.s[i] = high
            }
        }
        return out
    }

    /// Cheap Schroeder reverb: enough to place a sound in a space without pulling
    /// in a convolution engine.
    static func reverb(_ input: Buf, mix: Float, decay: Float, preDelay: Float = 0.01) -> Buf {
        var wet = Buf([Float](repeating: 0, count: input.count))
        let combDelays: [Float] = [0.0297, 0.0371, 0.0411, 0.0437]
        for d in combDelays {
            let n = Int(d * sampleRate)
            guard n > 0, n < input.count else { continue }
            var buffer = [Float](repeating: 0, count: n)
            var idx = 0
            let feedback = pow(0.001, d / max(decay, 0.05))
            for i in 0..<input.count {
                let delayed = buffer[idx]
                let v = input.s[i] + delayed * feedback
                buffer[idx] = v
                idx = (idx + 1) % n
                wet.s[i] += delayed * 0.25
            }
        }
        // Two all-passes to smear the comb resonances.
        for d in [Float(0.005), Float(0.0017)] {
            let n = Int(d * sampleRate)
            guard n > 0, n < wet.count else { continue }
            var buffer = [Float](repeating: 0, count: n)
            var idx = 0
            let g: Float = 0.7
            for i in 0..<wet.count {
                let delayed = buffer[idx]
                let v = wet.s[i] + delayed * g
                buffer[idx] = v
                wet.s[i] = delayed - g * v
                idx = (idx + 1) % n
            }
        }
        var out = input
        let pd = Int(preDelay * sampleRate)
        for i in out.s.indices {
            let j = i - pd
            let w = (j >= 0 && j < wet.count) ? wet.s[j] : 0
            out.s[i] = out.s[i] * (1 - mix) + w * mix
        }
        return out
    }

    /// Multiplies a buffer by an envelope, extending or truncating as needed.
    static func apply(_ b: Buf, _ env: [Float]) -> Buf {
        var out = b
        for i in out.s.indices {
            out.s[i] *= i < env.count ? env[i] : 0
        }
        return out
    }
}
