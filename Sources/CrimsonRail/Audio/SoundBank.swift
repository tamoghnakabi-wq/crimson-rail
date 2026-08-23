import Foundation
import simd

enum SoundID: String, CaseIterable {
    case gunshot, dryFire, reloadStart, reloadFinish
    case fleshHit, headshot, kill, armorPing, ricochet
    case zombieAlert, zombieAttack, zombieDeath, bossRoar
    case spit, acidPop
    case playerHurt, playerDown, levelClear, civilianDown, rescue
    case uiMove, uiSelect, uiBack, comboUp
    case footstep
}

/// Every sound recipe. Each returns a mono buffer at `Synth.sampleRate`.
///
/// Recipes take a seed so a sound can have several pre-rendered variants; playing
/// the identical waveform forty times in a row is the thing that makes
/// synthesised audio sound synthetic.
enum SoundBank {
    typealias Buf = Synth.Buf

    static func variantCount(for id: SoundID) -> Int {
        switch id {
        case .gunshot, .fleshHit, .zombieAlert, .zombieDeath, .ricochet, .zombieAttack, .footstep: return 4
        case .headshot, .kill, .armorPing, .playerHurt, .spit: return 3
        default: return 1
        }
    }

    /// Stable seed for a sound variant.
    ///
    /// Deliberately NOT `hashValue`: Swift seeds string hashing per process, so
    /// that is both unstable between launches (the "random" variants would differ
    /// every run) and frequently negative — and `UInt64(negativeInt)` traps,
    /// which crashed the sound bank on roughly half of all launches.
    private static func seed(for id: SoundID, variant: Int) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325          // FNV-1a offset basis
        for byte in id.rawValue.utf8 {
            h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return h &+ UInt64(UInt32(bitPattern: Int32(variant))) &* 7919
    }

    static func render(_ id: SoundID, variant: Int) -> Buf {
        var rng = Rand(seed: seed(for: id, variant: variant))
        switch id {

        // MARK: Weapon

        case .gunshot:
            // Three layers: a transient click, a body of filtered noise, and a
            // low thump. Real gunfire is mostly transient; without the click it
            // sounds like a cough.
            var out = Buf(seconds: 0.85)
            let n = out.count

            var click = Synth.noise(Int(0.012 * Synth.sampleRate), rng: &rng)
            click = Synth.svf(click, cutoff: rng.float(5200, 7000), q: 0.9, mode: .high)
            click = Synth.apply(click, Synth.envelope(click.count, attack: 0.0002, decay: 0.006, curve: 3.5))

            var body = Synth.noise(Int(0.30 * Synth.sampleRate), rng: &rng)
            body = Synth.svfSweep(body, from: rng.float(2400, 3100), to: 320, q: 1.6, mode: .low)
            body = Synth.apply(body, Synth.envelope(body.count, attack: 0.0005, decay: 0.075, curve: 2.6))

            var thump = Synth.tone(Int(0.22 * Synth.sampleRate), from: rng.float(120, 165), to: 42)
            thump = Synth.apply(thump, Synth.envelope(thump.count, attack: 0.001, decay: 0.055, curve: 2.4))

            out.mix(click, gain: 0.85)
            out.mix(body, gain: 1.0)
            out.mix(thump, gain: 0.75)
            // A tail placed in the environment; a dry gunshot sounds like a toy.
            out = Synth.reverb(out, mix: 0.30, decay: 0.7, preDelay: 0.012)
            _ = n
            out.normalize(0.95)
            out.deClick()
            return out

        case .dryFire:
            var out = Buf(seconds: 0.14)
            var c = Synth.noise(Int(0.02 * Synth.sampleRate), rng: &rng)
            c = Synth.svf(c, cutoff: 3200, q: 3.0, mode: .band)
            c = Synth.apply(c, Synth.envelope(c.count, attack: 0.0002, decay: 0.010, curve: 3.0))
            var t = Synth.tone(Int(0.05 * Synth.sampleRate), from: 900, to: 500)
            t = Synth.apply(t, Synth.envelope(t.count, attack: 0.0004, decay: 0.012, curve: 3.0))
            out.mix(c, gain: 0.8); out.mix(t, gain: 0.3)
            out.normalize(0.5); out.deClick()
            return out

        case .reloadStart:
            // Magazine release and drop.
            var out = Buf(seconds: 0.5)
            for (offset, freq, decay) in [(Float(0.0), Float(1800), Float(0.02)), (Float(0.11), Float(1200), Float(0.03))] {
                var c = Synth.noise(Int(0.06 * Synth.sampleRate), rng: &rng)
                c = Synth.svf(c, cutoff: freq, q: 2.4, mode: .band)
                c = Synth.apply(c, Synth.envelope(c.count, attack: 0.0003, decay: decay, curve: 3.0))
                out.mix(c, gain: 0.8, offset: Int(offset * Synth.sampleRate))
            }
            out.normalize(0.55); out.deClick()
            return out

        case .reloadFinish:
            // Fresh magazine seated, then the slide.
            var out = Buf(seconds: 0.55)
            for (offset, freq, decay, gain) in [(Float(0.0), Float(900), Float(0.035), Float(0.9)),
                                                (Float(0.14), Float(2600), Float(0.02), Float(0.7)),
                                                (Float(0.21), Float(1500), Float(0.045), Float(1.0))] {
                var c = Synth.noise(Int(0.08 * Synth.sampleRate), rng: &rng)
                c = Synth.svf(c, cutoff: freq, q: 2.0, mode: .band)
                c = Synth.apply(c, Synth.envelope(c.count, attack: 0.0003, decay: decay, curve: 3.0))
                out.mix(c, gain: gain, offset: Int(offset * Synth.sampleRate))
            }
            out.normalize(0.6); out.deClick()
            return out

        // MARK: Impacts

        case .fleshHit:
            var out = Buf(seconds: 0.35)
            var wet = Synth.noise(Int(0.12 * Synth.sampleRate), rng: &rng)
            wet = Synth.svfSweep(wet, from: rng.float(900, 1400), to: 180, q: 1.1, mode: .low)
            wet = Synth.apply(wet, Synth.envelope(wet.count, attack: 0.0008, decay: 0.045, curve: 2.6))
            var thud = Synth.tone(Int(0.14 * Synth.sampleRate), from: rng.float(140, 200), to: 60)
            thud = Synth.apply(thud, Synth.envelope(thud.count, attack: 0.001, decay: 0.035, curve: 2.4))
            out.mix(wet, gain: 1.0); out.mix(thud, gain: 0.6)
            out.normalize(0.62); out.deClick()
            return out

        case .headshot:
            var out = Buf(seconds: 0.6)
            var burst = Synth.noise(Int(0.20 * Synth.sampleRate), rng: &rng)
            burst = Synth.svfSweep(burst, from: rng.float(2600, 3400), to: 220, q: 1.4, mode: .low)
            burst = Synth.apply(burst, Synth.envelope(burst.count, attack: 0.0004, decay: 0.075, curve: 2.2))
            var crack = Synth.tone(Int(0.10 * Synth.sampleRate), from: 520, to: 90)
            crack = Synth.apply(crack, Synth.envelope(crack.count, attack: 0.0004, decay: 0.028, curve: 3.0))
            out.mix(burst, gain: 1.0); out.mix(crack, gain: 0.7)
            out = Synth.reverb(out, mix: 0.20, decay: 0.5)
            out.normalize(0.80); out.deClick()
            return out

        case .kill:
            var out = Buf(seconds: 0.7)
            var body = Synth.noise(Int(0.25 * Synth.sampleRate), rng: &rng)
            body = Synth.svfSweep(body, from: 1500, to: 140, q: 1.0, mode: .low)
            body = Synth.apply(body, Synth.envelope(body.count, attack: 0.001, decay: 0.09, curve: 2.0))
            var groan = voice(seconds: 0.5, f0: rng.float(72, 96), formants: [420, 880, 1500],
                              wobble: 5.5, rng: &rng)
            groan = Synth.apply(groan, Synth.envelope(groan.count, attack: 0.01, decay: 0.22, curve: 1.6))
            out.mix(body, gain: 0.8); out.mix(groan, gain: 0.55, offset: Int(0.04 * Synth.sampleRate))
            out.normalize(0.70); out.deClick()
            return out

        case .armorPing:
            var out = Buf(seconds: 0.5)
            // Metallic: a few inharmonic partials ringing together.
            for f in [Float(1850), 2790, 4100, 5600] {
                var t = Synth.tone(Int(0.4 * Synth.sampleRate), from: f * rng.float(0.97, 1.03))
                t = Synth.apply(t, Synth.envelope(t.count, attack: 0.0003, decay: rng.float(0.05, 0.13), curve: 2.4))
                out.mix(t, gain: rng.float(0.2, 0.4))
            }
            var scrape = Synth.noise(Int(0.04 * Synth.sampleRate), rng: &rng)
            scrape = Synth.svf(scrape, cutoff: 4200, q: 1.4, mode: .high)
            scrape = Synth.apply(scrape, Synth.envelope(scrape.count, attack: 0.0002, decay: 0.012, curve: 3.0))
            out.mix(scrape, gain: 0.7)
            out.normalize(0.55); out.deClick()
            return out

        case .ricochet:
            var out = Buf(seconds: 0.5)
            var whine = Synth.tone(Int(0.3 * Synth.sampleRate),
                                   from: rng.float(2400, 3600), to: rng.float(700, 1300))
            whine = Synth.apply(whine, Synth.envelope(whine.count, attack: 0.002, decay: 0.09, curve: 1.8))
            var dust = Synth.noise(Int(0.09 * Synth.sampleRate), rng: &rng)
            dust = Synth.svf(dust, cutoff: 2600, q: 0.9, mode: .band)
            dust = Synth.apply(dust, Synth.envelope(dust.count, attack: 0.0004, decay: 0.025, curve: 2.6))
            out.mix(whine, gain: 0.30); out.mix(dust, gain: 0.7)
            out = Synth.reverb(out, mix: 0.22, decay: 0.6)
            out.normalize(0.45); out.deClick()
            return out

        // MARK: Voices

        case .zombieAlert:
            var out = voice(seconds: 1.5, f0: rng.float(58, 92), formants: [380, 760, 1450],
                            wobble: rng.float(4.0, 7.5), rng: &rng)
            out = Synth.apply(out, Synth.envelope(out.count, attack: 0.10, decay: 0.55, curve: 1.3))
            out = Synth.reverb(out, mix: 0.32, decay: 1.1)
            out.normalize(0.62); out.deClick(fadeIn: 0.02, fadeOut: 0.15)
            return out

        case .zombieAttack:
            var out = voice(seconds: 0.75, f0: rng.float(70, 110), formants: [520, 1100, 2100],
                            wobble: rng.float(8, 14), rng: &rng)
            out = Synth.apply(out, Synth.envelope(out.count, attack: 0.012, decay: 0.20, curve: 2.0))
            out.normalize(0.72); out.deClick(fadeIn: 0.004, fadeOut: 0.06)
            return out

        case .zombieDeath:
            var out = voice(seconds: 1.3, f0: rng.float(52, 78), formants: [300, 640, 1150],
                            wobble: rng.float(3, 6), rng: &rng, pitchFall: 0.55)
            out = Synth.apply(out, Synth.envelope(out.count, attack: 0.02, decay: 0.42, curve: 1.4))
            out = Synth.reverb(out, mix: 0.28, decay: 0.9)
            out.normalize(0.60); out.deClick(fadeIn: 0.006, fadeOut: 0.2)
            return out

        case .bossRoar:
            var out = voice(seconds: 3.0, f0: rng.float(34, 46), formants: [180, 420, 900],
                            wobble: 3.0, rng: &rng)
            // Sub layer, so it is felt as much as heard.
            var sub = Synth.tone(out.count, from: 38, to: 30)
            sub = Synth.apply(sub, Synth.envelope(sub.count, attack: 0.15, decay: 1.4, curve: 1.2))
            out = Synth.apply(out, Synth.envelope(out.count, attack: 0.22, decay: 1.3, curve: 1.1))
            out.mix(sub, gain: 0.55)
            out = Synth.reverb(out, mix: 0.42, decay: 2.2)
            out.normalize(0.95); out.deClick(fadeIn: 0.05, fadeOut: 0.4)
            return out

        // MARK: Acid

        case .spit:
            var out = Buf(seconds: 0.45)
            var hiss = Synth.noise(Int(0.25 * Synth.sampleRate), rng: &rng)
            hiss = Synth.svfSweep(hiss, from: 900, to: 4200, q: 1.8, mode: .band)
            hiss = Synth.apply(hiss, Synth.envelope(hiss.count, attack: 0.03, decay: 0.10, curve: 1.8))
            out.mix(hiss, gain: 1.0)
            out.normalize(0.55); out.deClick()
            return out

        case .acidPop:
            var out = Buf(seconds: 0.5)
            var pop = Synth.noise(Int(0.18 * Synth.sampleRate), rng: &rng)
            pop = Synth.svfSweep(pop, from: 3400, to: 500, q: 1.2, mode: .low)
            pop = Synth.apply(pop, Synth.envelope(pop.count, attack: 0.0005, decay: 0.05, curve: 2.4))
            var sizzle = Synth.noise(Int(0.35 * Synth.sampleRate), rng: &rng)
            sizzle = Synth.svf(sizzle, cutoff: 6200, q: 0.8, mode: .high)
            sizzle = Synth.apply(sizzle, Synth.envelope(sizzle.count, attack: 0.01, decay: 0.16, curve: 1.6))
            out.mix(pop, gain: 1.0); out.mix(sizzle, gain: 0.35)
            out.normalize(0.62); out.deClick()
            return out

        // MARK: Player

        case .playerHurt:
            var out = Buf(seconds: 0.8)
            // Impact plus a dulled ringing: the classic "that hurt" cue.
            var impact = Synth.noise(Int(0.15 * Synth.sampleRate), rng: &rng)
            impact = Synth.svfSweep(impact, from: 1600, to: 120, q: 1.2, mode: .low)
            impact = Synth.apply(impact, Synth.envelope(impact.count, attack: 0.0006, decay: 0.05, curve: 2.4))
            var ring = Synth.tone(Int(0.7 * Synth.sampleRate), from: rng.float(2100, 2600), to: rng.float(1800, 2200))
            ring = Synth.apply(ring, Synth.envelope(ring.count, attack: 0.004, decay: 0.30, curve: 1.4))
            var sub = Synth.tone(Int(0.3 * Synth.sampleRate), from: 90, to: 45)
            sub = Synth.apply(sub, Synth.envelope(sub.count, attack: 0.002, decay: 0.09, curve: 2.0))
            out.mix(impact, gain: 1.0); out.mix(ring, gain: 0.16); out.mix(sub, gain: 0.7)
            out.normalize(0.85); out.deClick()
            return out

        case .playerDown:
            var out = Buf(seconds: 2.6)
            var fall = Synth.tone(Int(2.2 * Synth.sampleRate), from: 220, to: 34)
            fall = Synth.apply(fall, Synth.envelope(fall.count, attack: 0.02, decay: 1.1, curve: 1.2))
            var heart = Buf(seconds: 2.6)
            // Two slowing heartbeats.
            for (i, t) in [Float(0.15), 0.62, 1.2, 1.95].enumerated() {
                var b = Synth.tone(Int(0.22 * Synth.sampleRate), from: 62, to: 38)
                b = Synth.apply(b, Synth.envelope(b.count, attack: 0.004, decay: 0.06, curve: 2.4))
                heart.mix(b, gain: 0.9 - Float(i) * 0.15, offset: Int(t * Synth.sampleRate))
            }
            var noiseBed = Synth.noise(Int(2.4 * Synth.sampleRate), rng: &rng)
            noiseBed = Synth.svfSweep(noiseBed, from: 2200, to: 200, q: 0.8, mode: .low)
            noiseBed = Synth.apply(noiseBed, Synth.envelope(noiseBed.count, attack: 0.05, decay: 0.9, curve: 1.2))
            out.mix(fall, gain: 0.55); out.mix(heart, gain: 1.0); out.mix(noiseBed, gain: 0.35)
            out = Synth.reverb(out, mix: 0.35, decay: 1.6)
            out.normalize(0.9); out.deClick(fadeIn: 0.01, fadeOut: 0.3)
            return out

        case .levelClear:
            // Rising minor-third motif; resolved enough to feel like relief,
            // unresolved enough to stay in the genre.
            var out = Buf(seconds: 3.0)
            let notes: [(Float, Float)] = [(146.83, 0.0), (174.61, 0.28), (220.0, 0.56), (293.66, 0.92)]
            for (f, t) in notes {
                var v = Synth.saw(Int(1.8 * Synth.sampleRate), freq: f, harmonics: 8)
                v = Synth.svfSweep(v, from: 1800, to: 500, q: 1.0, mode: .low)
                v = Synth.apply(v, Synth.envelope(v.count, attack: 0.02, decay: 0.65, curve: 1.3))
                out.mix(v, gain: 0.4, offset: Int(t * Synth.sampleRate))
            }
            out = Synth.reverb(out, mix: 0.40, decay: 1.8)
            out.normalize(0.75); out.deClick(fadeIn: 0.01, fadeOut: 0.4)
            return out

        case .civilianDown:
            var out = Buf(seconds: 1.4)
            var cry = voice(seconds: 0.9, f0: 210, formants: [700, 1400, 2600], wobble: 6, rng: &rng,
                            pitchFall: 0.6)
            cry = Synth.apply(cry, Synth.envelope(cry.count, attack: 0.02, decay: 0.30, curve: 1.5))
            var sting = Synth.tone(Int(1.1 * Synth.sampleRate), from: 320, to: 150)
            sting = Synth.apply(sting, Synth.envelope(sting.count, attack: 0.005, decay: 0.42, curve: 1.3))
            out.mix(cry, gain: 0.7); out.mix(sting, gain: 0.45)
            out = Synth.reverb(out, mix: 0.3, decay: 1.2)
            out.normalize(0.8); out.deClick(fadeIn: 0.005, fadeOut: 0.25)
            return out

        case .rescue:
            var out = Buf(seconds: 1.6)
            for (f, t) in [(392.0, 0.0), (523.25, 0.16), (659.25, 0.32)] as [(Float, Float)] {
                var v = Synth.tone(Int(1.0 * Synth.sampleRate), from: f)
                v = Synth.apply(v, Synth.envelope(v.count, attack: 0.006, decay: 0.35, curve: 1.5))
                out.mix(v, gain: 0.32, offset: Int(t * Synth.sampleRate))
            }
            out = Synth.reverb(out, mix: 0.35, decay: 1.3)
            out.normalize(0.6); out.deClick(fadeIn: 0.005, fadeOut: 0.3)
            return out

        // MARK: UI

        case .uiMove:
            var out = Buf(seconds: 0.12)
            var t = Synth.tone(Int(0.08 * Synth.sampleRate), from: 620, to: 700)
            t = Synth.apply(t, Synth.envelope(t.count, attack: 0.001, decay: 0.02, curve: 2.6))
            var n = Synth.noise(Int(0.02 * Synth.sampleRate), rng: &rng)
            n = Synth.svf(n, cutoff: 4200, q: 2.0, mode: .band)
            n = Synth.apply(n, Synth.envelope(n.count, attack: 0.0003, decay: 0.007, curve: 3.0))
            out.mix(t, gain: 0.30); out.mix(n, gain: 0.35)
            out.normalize(0.30); out.deClick()
            return out

        case .uiSelect:
            var out = Buf(seconds: 0.35)
            for (f, t) in [(330.0, 0.0), (494.0, 0.05)] as [(Float, Float)] {
                var v = Synth.tone(Int(0.28 * Synth.sampleRate), from: f)
                v = Synth.apply(v, Synth.envelope(v.count, attack: 0.002, decay: 0.09, curve: 1.8))
                out.mix(v, gain: 0.34, offset: Int(t * Synth.sampleRate))
            }
            out.normalize(0.42); out.deClick()
            return out

        case .uiBack:
            var out = Buf(seconds: 0.3)
            var v = Synth.tone(Int(0.24 * Synth.sampleRate), from: 420, to: 240)
            v = Synth.apply(v, Synth.envelope(v.count, attack: 0.002, decay: 0.08, curve: 2.0))
            out.mix(v, gain: 0.4)
            out.normalize(0.35); out.deClick()
            return out

        case .footstep:
            // A boot on grit: a soft low thump under a short scuff of noise.
            // Quiet by design — it should sit under everything and only be
            // noticed when the player stops.
            var out = Buf(seconds: 0.24)
            var scuff = Synth.noise(Int(0.10 * Synth.sampleRate), rng: &rng)
            scuff = Synth.svfSweep(scuff, from: rng.float(2600, 4200), to: rng.float(700, 1100),
                                   q: 1.1, mode: .band)
            scuff = Synth.apply(scuff, Synth.envelope(scuff.count, attack: 0.002, decay: 0.030, curve: 2.4))
            var thump = Synth.tone(Int(0.10 * Synth.sampleRate), from: rng.float(95, 135), to: 55)
            thump = Synth.apply(thump, Synth.envelope(thump.count, attack: 0.001, decay: 0.028, curve: 2.6))
            out.mix(scuff, gain: 0.55); out.mix(thump, gain: 0.7)
            out.normalize(rng.float(0.16, 0.24)); out.deClick()
            return out

        case .comboUp:
            var out = Buf(seconds: 0.25)
            var v = Synth.tone(Int(0.2 * Synth.sampleRate), from: 880, to: 1320)
            v = Synth.apply(v, Synth.envelope(v.count, attack: 0.001, decay: 0.05, curve: 2.2))
            out.mix(v, gain: 0.3)
            out.normalize(0.28); out.deClick()
            return out
        }
    }

    /// Vocal-ish source: a rasping pulse train pushed through formant band-passes.
    /// Human-adjacent but clearly wrong, which is exactly what a zombie needs.
    private static func voice(seconds: Float, f0: Float, formants: [Float], wobble: Float,
                              rng: inout Rand, pitchFall: Float = 0.85) -> Buf {
        let n = Int(seconds * Synth.sampleRate)
        var src = Buf([Float](repeating: 0, count: n))
        var phase: Float = 0
        // Jitter and shimmer: perfectly periodic glottal pulses sound synthetic.
        var jitter: Float = 0
        for i in 0..<n {
            let t = Float(i) / Synth.sampleRate
            jitter += rng.float(-1, 1) * 0.9
            jitter *= 0.96
            let vib = sin(2 * .pi * wobble * t) * 0.06
            let f = f0 * (1 + vib + jitter * 0.02) * (1 - (1 - pitchFall) * (Float(i) / Float(n)))
            phase += 2 * .pi * f / Synth.sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
            // Asymmetric pulse plus breath.
            let pulse = pow(max(sin(phase), 0), 2.5) * 2 - 0.4
            src.s[i] = pulse + rng.float(-0.28, 0.28)
        }
        var out = Buf([Float](repeating: 0, count: n))
        for (k, f) in formants.enumerated() {
            let band = Synth.svf(src, cutoff: f, q: 6.5, mode: .band)
            out.mix(band, gain: 1.0 / Float(k + 1))
        }
        // A little grit.
        for i in out.s.indices { out.s[i] = tanh(out.s[i] * 1.8) }
        return out
    }

    // MARK: - Ambience and music loops

    /// Seamless looping ambience bed for a level.
    static func ambience(_ kind: AmbienceKind, seconds: Float = 12) -> Buf {
        // Stable per-kind seed, for the same reason as `seed(for:variant:)`.
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in String(describing: kind).utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        var rng = Rand(seed: h)
        let n = Int(seconds * Synth.sampleRate)
        var out = Buf([Float](repeating: 0, count: n))

        switch kind {
        case .wind:
            var w = Synth.noise(n, rng: &rng)
            w = Synth.svf(w, cutoff: 420, q: 0.7, mode: .low)
            // Slow gusting.
            for i in 0..<n {
                let t = Float(i) / Synth.sampleRate
                let gust = 0.35 + 0.65 * (0.5 + 0.5 * sin(2 * .pi * 0.055 * t + sin(2 * .pi * 0.021 * t) * 2))
                w.s[i] *= gust
            }
            out.mix(w, gain: 0.55)
            // Distant, irregular creaks.
            for _ in 0..<7 {
                var c = Synth.tone(Int(0.9 * Synth.sampleRate), from: rng.float(180, 420), to: rng.float(140, 300))
                c = Synth.apply(c, Synth.envelope(c.count, attack: 0.15, decay: 0.35, curve: 1.4))
                out.mix(c, gain: rng.float(0.02, 0.06), offset: rng.int(0, n - 1))
            }

        case .interior:
            var w = Synth.noise(n, rng: &rng)
            w = Synth.svf(w, cutoff: 180, q: 0.6, mode: .low)
            out.mix(w, gain: 0.35)
            for _ in 0..<12 {
                var c = Synth.noise(Int(0.25 * Synth.sampleRate), rng: &rng)
                c = Synth.svf(c, cutoff: rng.float(600, 2400), q: 3.0, mode: .band)
                c = Synth.apply(c, Synth.envelope(c.count, attack: 0.01, decay: 0.07, curve: 2.0))
                out.mix(c, gain: rng.float(0.03, 0.09), offset: rng.int(0, n - 1))
            }

        case .fire:
            var f = Synth.noise(n, rng: &rng)
            f = Synth.svf(f, cutoff: 900, q: 0.6, mode: .low)
            for i in 0..<n {
                let t = Float(i) / Synth.sampleRate
                f.s[i] *= 0.5 + 0.5 * (0.5 + 0.5 * sin(2 * .pi * 3.1 * t + sin(2 * .pi * 0.7 * t) * 3))
            }
            out.mix(f, gain: 0.5)
            for _ in 0..<40 {
                var crack = Synth.noise(Int(0.03 * Synth.sampleRate), rng: &rng)
                crack = Synth.svf(crack, cutoff: rng.float(1800, 5200), q: 2.0, mode: .band)
                crack = Synth.apply(crack, Synth.envelope(crack.count, attack: 0.0004, decay: 0.008, curve: 3.0))
                out.mix(crack, gain: rng.float(0.05, 0.20), offset: rng.int(0, n - 1))
            }

        case .machinery:
            // Low rumble plus a mains-frequency hum: cold, institutional.
            var hum = Synth.tone(n, from: 50)
            hum = Synth.apply(hum, [Float](repeating: 1, count: n))
            var rumble = Synth.noise(n, rng: &rng)
            rumble = Synth.svf(rumble, cutoff: 130, q: 0.8, mode: .low)
            out.mix(hum, gain: 0.10); out.mix(rumble, gain: 0.45)
            for _ in 0..<9 {
                var clank = Synth.noise(Int(0.12 * Synth.sampleRate), rng: &rng)
                clank = Synth.svf(clank, cutoff: rng.float(400, 1400), q: 4.0, mode: .band)
                clank = Synth.apply(clank, Synth.envelope(clank.count, attack: 0.001, decay: 0.04, curve: 2.4))
                out.mix(clank, gain: rng.float(0.05, 0.13), offset: rng.int(0, n - 1))
            }

        case .storm:
            var w = Synth.noise(n, rng: &rng)
            w = Synth.svf(w, cutoff: 700, q: 0.6, mode: .low)
            for i in 0..<n {
                let t = Float(i) / Synth.sampleRate
                w.s[i] *= 0.4 + 0.6 * (0.5 + 0.5 * sin(2 * .pi * 0.08 * t + sin(2 * .pi * 0.03 * t) * 2.5))
            }
            out.mix(w, gain: 0.5)
            // Rain: dense high-frequency stipple.
            var rain = Synth.noise(n, rng: &rng)
            rain = Synth.svf(rain, cutoff: 5200, q: 0.7, mode: .high)
            out.mix(rain, gain: 0.14)
            for _ in 0..<3 {
                var thunder = Synth.noise(Int(2.2 * Synth.sampleRate), rng: &rng)
                thunder = Synth.svfSweep(thunder, from: 220, to: 45, q: 0.9, mode: .low)
                thunder = Synth.apply(thunder, Synth.envelope(thunder.count, attack: 0.06, decay: 0.8, curve: 1.2))
                out.mix(thunder, gain: rng.float(0.25, 0.5), offset: rng.int(0, max(n - Int(2.2 * Synth.sampleRate), 1)))
            }
        }

        // Cross-fade the tail into the head so the loop point is inaudible.
        let fade = Int(0.6 * Synth.sampleRate)
        if out.count > fade * 2 {
            for i in 0..<fade {
                let t = Float(i) / Float(fade)
                let tail = out.s[out.count - fade + i]
                out.s[i] = out.s[i] * t + tail * (1 - t)
            }
            out.s.removeLast(fade)
        }
        out.normalize(0.55)
        return out
    }

    /// One music stem. `intensity` 0 is the exploration bed, 1 is full combat.
    static func musicStem(intensity: Int, seconds: Float = 16) -> Buf {
        var rng = Rand(seed: UInt64(9000 + intensity * 13))
        let n = Int(seconds * Synth.sampleRate)
        var out = Buf([Float](repeating: 0, count: n))
        // D minor: the whole score sits here so stems can be crossfaded freely.
        let root: Float = 73.42          // D2

        // Drone, always present.
        for (mult, gain) in [(Float(1), Float(0.30)), (2, 0.14), (3, 0.07)] {
            var d = Synth.saw(n, freq: root * mult, harmonics: 6)
            d = Synth.svf(d, cutoff: 260 + Float(intensity) * 220, q: 1.0, mode: .low)
            for i in 0..<n {
                let t = Float(i) / Synth.sampleRate
                d.s[i] *= 0.75 + 0.25 * sin(2 * .pi * 0.07 * t + Float(mult))
            }
            out.mix(d, gain: gain)
        }

        if intensity >= 1 {
            // Pulse: a slow, dragging heartbeat that gives the level a tempo.
            let bpm: Float = 62 + Float(intensity) * 14
            let beat = 60 / bpm
            var t: Float = 0
            while t < seconds {
                var p = Synth.tone(Int(0.30 * Synth.sampleRate), from: root * 2, to: root)
                p = Synth.apply(p, Synth.envelope(p.count, attack: 0.004, decay: 0.10, curve: 2.2))
                out.mix(p, gain: 0.30, offset: Int(t * Synth.sampleRate))
                t += beat
            }
        }

        if intensity >= 2 {
            // Dissonant stabs on the tritone — the "things are going badly" layer.
            var t: Float = 0
            while t < seconds {
                let f = root * 4 * (rng.chance(0.5) ? 1.0 : 1.4142)
                var stab = Synth.saw(Int(0.5 * Synth.sampleRate), freq: f, harmonics: 10)
                stab = Synth.svfSweep(stab, from: 2600, to: 500, q: 2.2, mode: .low)
                stab = Synth.apply(stab, Synth.envelope(stab.count, attack: 0.005, decay: 0.16, curve: 1.8))
                out.mix(stab, gain: 0.18, offset: Int(t * Synth.sampleRate))
                t += rng.float(1.4, 3.2)
            }
        }

        let fade = Int(1.0 * Synth.sampleRate)
        if out.count > fade * 2 {
            for i in 0..<fade {
                let t = Float(i) / Float(fade)
                let tail = out.s[out.count - fade + i]
                out.s[i] = out.s[i] * t + tail * (1 - t)
            }
            out.s.removeLast(fade)
        }
        out.normalize(0.42)
        return out
    }
}
