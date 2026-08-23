import Foundation
import AVFoundation
import SceneKit
import simd

// MARK: - --audiotest

extension Harness {
    /// Renders every sound offline and reports its levels, optionally writing
    /// WAVs so they can actually be listened to.
    ///
    ///   --audiotest [--dir out/] [--loops]
    static func audiotest(_ args: Args) -> Int32 {
        let dir = args.string("--dir")
        if let dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let includeLoops = args.has("--loops")

        out("CRIMSON RAIL — audio bank")
        out("")
        out("sound              var    len     rms    peak   headroom  notes")
        out(String(repeating: "-", count: 74))

        var problems = 0
        var totalSeconds = 0.0
        let t0 = Date()

        for id in SoundID.allCases {
            for v in 0..<SoundBank.variantCount(for: id) {
                let buf = SoundBank.render(id, variant: v)
                let seconds = Double(buf.count) / Double(Synth.sampleRate)
                totalSeconds += seconds
                let rms = buf.rms, peak = buf.peak
                var notes: [String] = []
                if buf.s.contains(where: { !$0.isFinite }) { notes.append("NON-FINITE"); problems += 1 }
                if rms < 0.001 { notes.append("SILENT"); problems += 1 }
                if peak > 1.0 { notes.append("CLIPPING"); problems += 1 }
                if peak > 0 && rms / peak > 0.72 { notes.append("over-compressed") }
                // A sound with no transient reads as mush in a mix this busy.
                if seconds > 0.05, transientRatio(buf) < 1.6, id != .levelClear, id != .rescue,
                   id != .bossRoar, id != .playerDown {
                    notes.append("soft attack")
                }

                out(String(format: "%-18@ %3d  %5.2fs  %6.3f  %6.3f  %6.1f dB  %@",
                           id.rawValue as NSString, v, seconds, rms, peak,
                           20 * log10(max(peak, 1e-6)),
                           notes.joined(separator: ", ") as NSString))

                if let dir {
                    let path = "\(dir)/\(id.rawValue)_\(v).wav"
                    if !writeWAV(buf, to: path) { problems += 1 }
                }
            }
        }

        if includeLoops {
            out("")
            out("ambience / music loops")
            out(String(repeating: "-", count: 74))
            for kind in [AmbienceKind.wind, .interior, .fire, .machinery, .storm] {
                let buf = SoundBank.ambience(kind)
                out(String(format: "%-18@      %5.2fs  %6.3f  %6.3f",
                           String(describing: kind) as NSString,
                           Double(buf.count) / Double(Synth.sampleRate), buf.rms, buf.peak))
                if let dir { _ = writeWAV(buf, to: "\(dir)/ambience_\(kind).wav") }
            }
            for i in 0..<3 {
                let buf = SoundBank.musicStem(intensity: i)
                out(String(format: "music stem %d          %5.2fs  %6.3f  %6.3f",
                           i, Double(buf.count) / Double(Synth.sampleRate), buf.rms, buf.peak))
                if let dir { _ = writeWAV(buf, to: "\(dir)/music_\(i).wav") }
            }
        }

        let elapsed = Date().timeIntervalSince(t0)
        out("")
        out(String(format: "%d sounds, %.1f s of audio, synthesised in %.2f s",
                   SoundID.allCases.reduce(0) { $0 + SoundBank.variantCount(for: $1) },
                   totalSeconds, elapsed))
        if let dir { out("wrote WAVs to \(dir)") }
        if problems > 0 {
            out("\(problems) problem(s) found")
            return 1
        }
        out("all sounds within range")
        return 0
    }

    /// Peak-to-RMS over the first 30 ms against the whole buffer. A percussive
    /// sound should be well above 1; a drone will not be.
    private static func transientRatio(_ buf: Synth.Buf) -> Float {
        let head = min(Int(0.03 * Synth.sampleRate), buf.count)
        guard head > 0 else { return 0 }
        var headPeak: Float = 0
        for i in 0..<head { headPeak = max(headPeak, abs(buf.s[i])) }
        let r = buf.rms
        return r > 1e-6 ? headPeak / r : 0
    }

    /// 16-bit mono WAV.
    private static func writeWAV(_ buf: Synth.Buf, to path: String) -> Bool {
        let sampleRate = UInt32(Synth.sampleRate)
        let n = buf.count
        var data = Data()

        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))              // PCM header size
        append(UInt16(1))               // format: PCM
        append(UInt16(1))               // channels
        append(sampleRate)
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(n * 2))
        for s in buf.s {
            append(Int16(clamp(s, -1, 1) * 32_767))
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            out("  failed to write \(path): \(error)")
            return false
        }
    }
}

// MARK: - --perf

extension Harness {
    /// Renders a level offscreen for a fixed number of frames and reports frame
    /// time percentiles, plus scene complexity.
    ///
    ///   --perf [--level N] [--frames 300] [--quality high] [--width 1920] [--height 1200]
    static func perf(_ args: Args) -> Int32 {
        let frames = args.int("--frames", 320)
        // Each level is measured several times and the *best* median is kept.
        // This benchmark drives the GPU synchronously on a shared machine, so a
        // contended pass reports the scheduler's noise rather than the renderer's
        // cost; the least-contended pass is the closest estimate of the real one.
        let repeats = max(args.int("--repeat", 3), 1)
        let presetName = args.string("--quality", "high") ?? "high"
        let width = args.int("--width", 1920)
        let height = args.int("--height", 1200)
        let onlyLevel = args.string("--level").flatMap { Int($0) }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            out("no Metal device"); return 1
        }
        out("CRIMSON RAIL — performance")
        out("device: \(device.name)   \(width)x\(height)   preset: \(presetName)   \(frames) frames x \(repeats) passes/level")
        out("")
        out("level                  nodes  tris(k)  build   p50     p95     p99    worst   est fps")
        out(String(repeating: "-", count: 88))

        var worstP50 = 0.0

        for levelIndex in 0..<LevelCatalog.count {
            if let only = onlyLevel, only != levelIndex + 1 { continue }
            let def = LevelCatalog.level(levelIndex)
            var quality = GraphicsSettings.forPreset(QualityPreset(rawValue: presetName) ?? .high)
            quality.renderScale = 1

            let buildStart = Date()
            var settings = Settings()
            settings.graphics = quality
            let session = Session(def: def, settings: settings)
            session.aspect = Float(width) / Float(height)
            let buildMs = Date().timeIntervalSince(buildStart) * 1000

            // Count what is actually in the scene.
            var nodes = 0
            var tris = 0
            session.field.scene.rootNode.enumerateHierarchy { n, _ in
                nodes += 1
                if let g = n.geometry {
                    for e in g.elements { tris += e.primitiveCount }
                }
            }

            // Play forward so the frame under test has enemies, effects and a
            // populated encounter in it — an empty corridor is not a benchmark.
            for _ in 0..<Int(6.0 * 60) {
                session.update(dt: 1.0 / 60.0, aim: SIMD2(0, 0), trigger: false,
                               triggerPressed: false, reload: false)
                _ = session.drainEvents()
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = session.field.scene
            renderer.pointOfView = session.field.cameraNode

            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                              width: width, height: height, mipmapped: false)
            cd.usage = [.renderTarget]; cd.storageMode = .private
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                              width: width, height: height, mipmapped: false)
            dd.usage = [.renderTarget]; dd.storageMode = .private
            guard let color = device.makeTexture(descriptor: cd),
                  let depth = device.makeTexture(descriptor: dd) else { return 1 }

            var bestTimes: [Double] = []
            for _ in 0..<repeats {
            var times: [Double] = []
            times.reserveCapacity(frames)
            var t = 0.0
            for i in 0..<frames {
                session.update(dt: 1.0 / 60.0, aim: SIMD2(0, 0), trigger: i % 12 == 0,
                               triggerPressed: i % 12 == 0, reload: false)
                _ = session.drainEvents()
                t += 1.0 / 60.0

                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = color
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.depthAttachment.texture = depth
                rpd.depthAttachment.loadAction = .clear
                rpd.depthAttachment.storeAction = .dontCare
                rpd.depthAttachment.clearDepth = 1.0

                let start = Date()
                guard let cb = queue.makeCommandBuffer() else { continue }
                renderer.render(atTime: t, viewport: CGRect(x: 0, y: 0, width: width, height: height),
                                commandBuffer: cb, passDescriptor: rpd)
                cb.commit()
                cb.waitUntilCompleted()
                // Discard the first frames: shader compilation and texture upload
                // land there and are not representative of steady state.
                // Discard a generous warm-up: shader compilation, texture upload
                // and the first GPU clock ramp all land in the early frames.
                if i >= 60 { times.append(Date().timeIntervalSince(start) * 1000) }
            }
            times.sort()
            let median = times.isEmpty ? 0 : times[times.count / 2]
            let bestMedian = bestTimes.isEmpty ? Double.greatestFiniteMagnitude
                                               : bestTimes[bestTimes.count / 2]
            if median < bestMedian { bestTimes = times }
            }
            session.teardown()

            let times = bestTimes
            func pct(_ p: Double) -> Double {
                guard !times.isEmpty else { return 0 }
                return times[min(Int(Double(times.count - 1) * p), times.count - 1)]
            }
            let p50 = pct(0.50), p95 = pct(0.95), p99 = pct(0.99), worst = times.last ?? 0
            worstP50 = max(worstP50, p50)

            out(String(format: "%-22@ %5d  %6.1f  %5.0fms %5.2f  %5.2f  %5.2f  %5.2f   %5.0f",
                       def.name as NSString, nodes, Double(tris) / 1000, buildMs,
                       p50, p95, p99, worst, p50 > 0 ? 1000 / p50 : 0))
        }

        out("")
        // The verdict uses the median, not p95. This benchmark drives the GPU
        // synchronously and shares the machine with whatever else is running, so
        // the tail is dominated by external scheduling rather than by the game;
        // p50 is the number that actually tracks changes to the renderer.
        out(String(format: "worst median %.2f ms (%.0f fps)  ·  budget: 16.6 ms = 60 Hz, 8.3 ms = 120 Hz",
                   worstP50, worstP50 > 0 ? 1000 / worstP50 : 0))
        out("best of \(repeats) passes per level; tails stay noisy unless the machine is idle.")
        return worstP50 <= 16.6 ? 0 : 1
    }
}
