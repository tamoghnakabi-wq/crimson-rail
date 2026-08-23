import Foundation
import SceneKit
import Metal
import AppKit
import simd

/// Renders a scene to a PNG with no window and no `currentDrawable`.
///
/// This matters for more than convenience: a view-backed capture blocks on the
/// display's drawable, so it hangs outright when the screen is asleep and
/// reports invented frame times when it isn't. `SCNRenderer` against an
/// offscreen texture has neither problem, so `--shot` and `--perf` work over SSH
/// and on a sleeping display.
enum OffscreenRenderer {

    struct Options {
        var width = 1280
        var height = 800
        /// Frames rendered before the capture, to let particle systems fill in
        /// and HDR exposure adaptation settle.
        var warmupFrames = 45
        var warmupStep: Double = 1.0 / 60.0
    }

    static func render(scene: SCNScene, pointOfView: SCNNode, options: Options = Options(),
                       startTime: Double = 0,
                       onWarmupFrame: ((Int, Double) -> Void)? = nil) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.autoenablesDefaultLighting = false

        let W = options.width, H = options.height
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        guard let color = device.makeTexture(descriptor: colorDesc) else { return nil }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let depth = device.makeTexture(descriptor: depthDesc) else { return nil }

        var time = startTime
        // Warm-up passes are rendered and discarded.
        for frame in 0..<options.warmupFrames {
            onWarmupFrame?(frame, options.warmupStep)
            time += options.warmupStep
            renderPass(renderer: renderer, queue: queue, color: color, depth: depth,
                       W: W, H: H, time: time)
        }

        time += options.warmupStep
        renderPass(renderer: renderer, queue: queue, color: color, depth: depth, W: W, H: H, time: time)

        return readback(color, W: W, H: H)
    }

    private static func renderPass(renderer: SCNRenderer, queue: MTLCommandQueue,
                                   color: MTLTexture, depth: MTLTexture,
                                   W: Int, H: Int, time: Double) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        guard let cb = queue.makeCommandBuffer() else { return }
        renderer.render(atTime: time, viewport: CGRect(x: 0, y: 0, width: W, height: H),
                        commandBuffer: cb, passDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()
    }

    private static func readback(_ tex: MTLTexture, W: Int, H: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var data = bytes
        // The target is BGRA; byteOrder32Little + premultipliedFirst reads it as ARGB-little.
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to path: String) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write("failed to write \(path): \(error)\n".data(using: .utf8)!)
            return false
        }
    }

    /// Mean luminance and the fraction of pixels above a floor. A pitch-black or
    /// blown-out capture is the single most common rendering failure, and this
    /// catches it without a human looking at the file.
    static func stats(_ image: CGImage) -> (meanLuma: Double, litFraction: Double) {
        let W = image.width, H = image.height
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        var sum = 0.0, lit = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let l = 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
            sum += l
            if l > 18 { lit += 1 }
        }
        let n = Double(W * H)
        return (sum / n, Double(lit) / n)
    }
}
