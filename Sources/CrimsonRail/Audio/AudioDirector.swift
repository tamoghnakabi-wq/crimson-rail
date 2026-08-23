import Foundation
import AVFoundation
import simd

/// Owns the audio engine, the pre-rendered sound bank, the ambience bed and the
/// adaptive music layers.
///
/// Positioning is done by hand (distance attenuation plus stereo pan) rather
/// than with `AVAudioEnvironmentNode`. Pan is taken against the player's own
/// right vector, so it tracks correctly now that the camera can turn, and the
/// manual path stays deterministic enough to test headlessly.
final class AudioDirector {
    private let engine = AVAudioEngine()
    private let sfxMixer = AVAudioMixerNode()
    private let musicMixer = AVAudioMixerNode()
    private let ambienceMixer = AVAudioMixerNode()

    /// Round-robin voices. Sixteen is comfortably more than the busiest wave needs.
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0

    private var bank: [SoundID: [AVAudioPCMBuffer]] = [:]
    private var ambiencePlayer = AVAudioPlayerNode()
    private var musicPlayers: [AVAudioPlayerNode] = []
    private var musicBuffers: [AVAudioPCMBuffer] = []
    private var musicTargets: [Float] = [0, 0, 0]
    private var musicLevels: [Float] = [0, 0, 0]

    private var settings: AudioSettings
    private(set) var isRunning = false
    /// Requests made before the engine finished starting.
    ///
    /// The bank is synthesised off the first frame, so anything that begins a
    /// level immediately — `--play N`, or a fast first Deploy — asks for its
    /// ambience and music while `isRunning` is still false. Dropping those
    /// requests left the first mission silent for its whole duration, so they
    /// are held and replayed once the engine is up.
    private var pendingAmbience: AmbienceKind?
    private var pendingMusic = false
    private var rng = Rand(seed: 0xA0D10)

    /// Listener pose, refreshed each frame by the session.
    private var listenerPosition = SIMD3<Float>.zero
    private var listenerRight = SIMD3<Float>(1, 0, 0)
    private var listenerForward = SIMD3<Float>(0, 0, -1)

    init(settings: AudioSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Renders the bank and starts the engine. Safe to call more than once.
    func start() {
        guard !isRunning else { return }
        renderBank()

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Synth.sampleRate), channels: 2)!
        engine.attach(sfxMixer)
        engine.attach(musicMixer)
        engine.attach(ambienceMixer)
        engine.connect(sfxMixer, to: engine.mainMixerNode, format: format)
        engine.connect(musicMixer, to: engine.mainMixerNode, format: format)
        engine.connect(ambienceMixer, to: engine.mainMixerNode, format: format)

        for _ in 0..<16 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: sfxMixer, format: format)
            voices.append(p)
        }
        engine.attach(ambiencePlayer)
        engine.connect(ambiencePlayer, to: ambienceMixer, format: format)
        for _ in 0..<3 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: musicMixer, format: format)
            musicPlayers.append(p)
        }

        applyVolumes()
        do {
            try engine.start()
            isRunning = true
            for p in voices { p.play() }
            ambiencePlayer.play()
            for p in musicPlayers { p.play() }
            // Replay anything requested while the engine was still coming up.
            if let kind = pendingAmbience { pendingAmbience = nil; setAmbience(kind) }
            if pendingMusic { pendingMusic = false; startMusic() }
        } catch {
            // Audio is not worth taking the game down for; carry on silent.
            FileHandle.standardError.write("audio engine failed to start: \(error)\n".data(using: .utf8)!)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    func update(settings: AudioSettings) {
        self.settings = settings
        applyVolumes()
    }

    private func applyVolumes() {
        sfxMixer.outputVolume = settings.master * settings.sfx
        musicMixer.outputVolume = settings.master * settings.music
        ambienceMixer.outputVolume = settings.master * settings.ambience
    }

    // MARK: Bank

    private func renderBank() {
        guard bank.isEmpty else { return }
        // Rendering ~30 sounds with reverb tails takes a moment; do it in parallel.
        let ids = SoundID.allCases
        var results = [SoundID: [Synth.Buf]]()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            let id = ids[i]
            var variants: [Synth.Buf] = []
            for v in 0..<SoundBank.variantCount(for: id) {
                variants.append(SoundBank.render(id, variant: v))
            }
            lock.lock(); results[id] = variants; lock.unlock()
        }
        for (id, bufs) in results {
            bank[id] = bufs.compactMap { pcm(from: $0) }
        }
    }

    /// Mono buffer -> stereo PCM. Kept stereo throughout so panning is a simple
    /// per-channel gain at playback time.
    private func pcm(from buf: Synth.Buf, pan: Float = 0, gain: Float = 1) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(Synth.sampleRate), channels: 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buf.count))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(buf.count)
        guard let ch = pcm.floatChannelData else { return nil }
        // Equal-power pan.
        let angle = (pan * 0.5 + 0.5) * .pi / 2
        let gl = cos(angle) * gain, gr = sin(angle) * gain
        for i in 0..<buf.count {
            ch[0][i] = buf.s[i] * gl
            ch[1][i] = buf.s[i] * gr
        }
        return pcm
    }

    // MARK: Playback

    func setListener(position: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>) {
        listenerPosition = position
        listenerForward = forward
        listenerRight = right
    }

    /// Plays a sound, optionally positioned in the world.
    func play(_ id: SoundID, at position: SIMD3<Float>? = nil) {
        guard isRunning, let variants = bank[id], !variants.isEmpty else { return }
        let buffer = variants[rng.int(0, variants.count - 1)]

        var gain: Float = 1
        var pan: Float = 0
        if let p = position {
            let delta = p - listenerPosition
            let dist = simd_length(delta)
            // Inverse-ish falloff with a floor, so distant groans stay audible
            // enough to warn the player without dominating.
            gain = clamp(1.0 / (1.0 + dist * dist * 0.006), 0.06, 1.0)
            if dist > 0.2 {
                pan = clamp(simd_dot(simd_normalize(delta), listenerRight), -1, 1) * 0.8
            }
        }

        let player = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        // Re-pan by writing a fresh buffer only when the sound is positional;
        // centre sounds reuse the pre-rendered buffer directly.
        let toPlay: AVAudioPCMBuffer
        if position != nil, abs(pan) > 0.02 || gain < 0.99 {
            guard let repanned = repan(buffer, pan: pan, gain: gain) else { return }
            toPlay = repanned
        } else {
            toPlay = buffer
        }
        player.volume = 1
        player.scheduleBuffer(toPlay, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func repan(_ buffer: AVAudioPCMBuffer, pan: Float, gain: Float) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        out.frameLength = buffer.frameLength
        guard let dst = out.floatChannelData else { return nil }
        let angle = (pan * 0.5 + 0.5) * .pi / 2
        let gl = cos(angle) * gain * 1.4, gr = sin(angle) * gain * 1.4
        // The source was rendered centre-panned, so recover mono then re-pan.
        for i in 0..<Int(buffer.frameLength) {
            let mono = (src[0][i] + src[1][i]) * 0.5
            dst[0][i] = mono * gl
            dst[1][i] = mono * gr
        }
        return out
    }

    // MARK: Ambience and music

    func setAmbience(_ kind: AmbienceKind) {
        guard isRunning else { pendingAmbience = kind; return }
        let buf = SoundBank.ambience(kind)
        guard let pcm = pcm(from: buf) else { return }
        ambiencePlayer.stop()
        ambiencePlayer.scheduleBuffer(pcm, at: nil, options: .loops, completionHandler: nil)
        ambiencePlayer.play()
    }

    func startMusic() {
        guard isRunning else { pendingMusic = true; return }
        musicBuffers = (0..<3).compactMap { i in pcm(from: SoundBank.musicStem(intensity: i)) }
        for (i, p) in musicPlayers.enumerated() where i < musicBuffers.count {
            p.stop()
            p.volume = 0
            p.scheduleBuffer(musicBuffers[i], at: nil, options: .loops, completionHandler: nil)
            p.play()
        }
        musicLevels = [0, 0, 0]
        musicTargets = [1, 0, 0]
    }

    func stopMusic() {
        pendingMusic = false
        for p in musicPlayers { p.stop() }
    }

    /// `threat` 0..1 drives which stems are audible. Crossfades are slow on the
    /// way down so the score does not flicker between waves.
    func setThreatLevel(_ threat: Float) {
        musicTargets[0] = 1
        musicTargets[1] = smoothstep(0.12, 0.45, threat)
        musicTargets[2] = smoothstep(0.55, 0.9, threat)
    }

    func updateMusic(dt: Float) {
        guard isRunning else { return }
        for i in musicLevels.indices where i < musicPlayers.count {
            let rising = musicTargets[i] > musicLevels[i]
            musicLevels[i] = damp(musicLevels[i], musicTargets[i], rising ? 1.6 : 0.45, dt)
            musicPlayers[i].volume = musicLevels[i]
        }
    }
}
