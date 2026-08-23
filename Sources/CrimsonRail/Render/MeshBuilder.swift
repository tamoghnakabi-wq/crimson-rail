import Foundation
import SceneKit
import simd

/// Accumulates triangles and hands back an `SCNGeometry`.
///
/// Winding convention, which is easy to get wrong and invisible when you do:
/// a face is FRONT-facing when its vertices run counter-clockwise as seen from
/// outside, and the outward normal is then `cross(b - a, c - a)`. SceneKit culls
/// back faces by default, so a reversed quad simply does not draw.
struct MeshBuilder {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var indices: [Int32] = []

    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }
    var vertexCount: Int { positions.count }

    func positionAt(_ i: Int) -> SIMD3<Float> { positions[i] }
    func normalAt(_ i: Int) -> SIMD3<Float> { normals[i] }

    mutating func reserve(_ verts: Int) {
        positions.reserveCapacity(verts)
        normals.reserveCapacity(verts)
        uvs.reserveCapacity(verts)
        indices.reserveCapacity(verts * 3 / 2)
    }

    // MARK: Primitives

    mutating func addTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                              uvA: SIMD2<Float> = .zero, uvB: SIMD2<Float> = SIMD2(1, 0), uvC: SIMD2<Float> = SIMD2(0, 1),
                              normal: SIMD3<Float>? = nil) {
        let n = normal ?? simd_cross(b - a, c - a).normalizedSafe
        let base = Int32(positions.count)
        positions.append(contentsOf: [a, b, c])
        normals.append(contentsOf: [n, n, n])
        uvs.append(contentsOf: [uvA, uvB, uvC])
        indices.append(contentsOf: [base, base + 1, base + 2])
    }

    /// `a b c d` must trace the quad counter-clockwise viewed from the front.
    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                          uvScale: Float = 1, uvOffset: SIMD2<Float> = .zero, normal: SIMD3<Float>? = nil) {
        let n = normal ?? simd_cross(b - a, c - a).normalizedSafe
        // Derive UVs from real edge lengths so texel density stays constant no
        // matter how big the surface is — otherwise every wall tiles differently.
        let w = simd_distance(a, b) * uvScale
        let h = simd_distance(a, d) * uvScale
        let base = Int32(positions.count)
        positions.append(contentsOf: [a, b, c, d])
        normals.append(contentsOf: [n, n, n, n])
        uvs.append(contentsOf: [
            uvOffset + SIMD2(0, h), uvOffset + SIMD2(w, h), uvOffset + SIMD2(w, 0), uvOffset + SIMD2(0, 0)
        ])
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Axis-aligned box (optionally yaw-rotated) with per-face UVs.
    mutating func addBox(center: SIMD3<Float>, size: SIMD3<Float>, yaw: Float = 0, uvScale: Float = 1,
                         faces: BoxFaces = .all) {
        let h = size * 0.5
        let c = cos(yaw), s = sin(yaw)
        func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            let p = SIMD3(x * h.x, y * h.y, z * h.z)
            return center + SIMD3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
        }
        // Corners: (x, y, z) in {-1, +1}
        let p000 = v(-1, -1, -1), p100 = v(1, -1, -1), p110 = v(1, 1, -1), p010 = v(-1, 1, -1)
        let p001 = v(-1, -1, 1), p101 = v(1, -1, 1), p111 = v(1, 1, 1), p011 = v(-1, 1, 1)

        if faces.contains(.front)  { addQuad(p001, p101, p111, p011, uvScale: uvScale) }   // +Z
        if faces.contains(.back)   { addQuad(p100, p000, p010, p110, uvScale: uvScale) }   // -Z
        if faces.contains(.right)  { addQuad(p101, p100, p110, p111, uvScale: uvScale) }   // +X
        if faces.contains(.left)   { addQuad(p000, p001, p011, p010, uvScale: uvScale) }   // -X
        if faces.contains(.top)    { addQuad(p011, p111, p110, p010, uvScale: uvScale) }   // +Y
        if faces.contains(.bottom) { addQuad(p000, p100, p101, p001, uvScale: uvScale) }   // -Y
    }

    struct BoxFaces: OptionSet {
        let rawValue: Int
        static let front = BoxFaces(rawValue: 1 << 0)
        static let back = BoxFaces(rawValue: 1 << 1)
        static let left = BoxFaces(rawValue: 1 << 2)
        static let right = BoxFaces(rawValue: 1 << 3)
        static let top = BoxFaces(rawValue: 1 << 4)
        static let bottom = BoxFaces(rawValue: 1 << 5)
        static let all: BoxFaces = [.front, .back, .left, .right, .top, .bottom]
        static let sides: BoxFaces = [.front, .back, .left, .right]
        static let noBottom: BoxFaces = [.front, .back, .left, .right, .top]
    }

    /// Irregular n-gon prism — the workhorse for rocks, rubble, gravestones and
    /// any chunk that must not read as a cube.
    mutating func addPrism(center: SIMD3<Float>, radii: [Float], height: Float,
                           topScale: Float = 1, yaw: Float = 0, topTilt: SIMD2<Float> = .zero,
                           uvScale: Float = 1, capTop: Bool = true, capBottom: Bool = false) {
        let n = radii.count
        guard n >= 3 else { return }
        let y0 = center.y, y1 = center.y + height
        var lower: [SIMD3<Float>] = [], upper: [SIMD3<Float>] = []
        lower.reserveCapacity(n); upper.reserveCapacity(n)
        for i in 0..<n {
            let a = yaw + Float(i) / Float(n) * 2 * .pi
            let r = radii[i]
            let dx = cos(a) * r, dz = sin(a) * r
            lower.append(SIMD3(center.x + dx, y0, center.z + dz))
            upper.append(SIMD3(center.x + dx * topScale + topTilt.x,
                               y1,
                               center.z + dz * topScale + topTilt.y))
        }
        for i in 0..<n {
            let j = (i + 1) % n
            addQuad(lower[i], lower[j], upper[j], upper[i], uvScale: uvScale)
        }
        if capTop {
            let centroid = upper.reduce(SIMD3<Float>.zero, +) / Float(n)
            for i in 0..<n {
                let j = (i + 1) % n
                addTriangle(centroid, upper[i], upper[j], normal: SIMD3(0, 1, 0))
            }
        }
        if capBottom {
            let centroid = lower.reduce(SIMD3<Float>.zero, +) / Float(n)
            for i in 0..<n {
                let j = (i + 1) % n
                addTriangle(centroid, lower[j], lower[i], normal: SIMD3(0, -1, 0))
            }
        }
    }

    /// One cross-section of a lofted surface: an ellipse in the local XZ plane.
    struct LoftSection {
        var center: SIMD3<Float>
        /// Half-width across X and depth across Z. Bodies are almost never round —
        /// a chest is wide and shallow, a forearm is the other way about.
        var radiusX: Float
        var radiusZ: Float
        /// Rotation of the ellipse about Y, for shapes that twist along their run.
        var twist: Float = 0

        init(_ center: SIMD3<Float>, _ radiusX: Float, _ radiusZ: Float, twist: Float = 0) {
            self.center = center
            self.radiusX = radiusX
            self.radiusZ = radiusZ
            self.twist = twist
        }
        init(_ center: SIMD3<Float>, _ radius: Float) {
            self.init(center, radius, radius)
        }
    }

    /// Lofts a surface through a series of cross-sections.
    ///
    /// This is the workhorse for anatomy. Capsules and prisms can only make
    /// sausages and rocks; a loft can make a skull with a brow ridge, a forearm
    /// that tapers to a wrist, or a ribcage that narrows to a waist, because the
    /// silhouette is specified section by section.
    ///
    /// `shape` optionally modulates the radius per (section, segment), which is
    /// what turns a smooth ellipse into a browline, a cheekbone or a rib.
    mutating func addLoft(_ sections: [LoftSection], segments: Int = 12,
                          capStart: Bool = false, capEnd: Bool = false,
                          uvScale: Float = 1,
                          shape: ((Int, Int) -> Float)? = nil) {
        guard sections.count >= 2, segments >= 3 else { return }
        let base = Int32(positions.count)

        for (si, sec) in sections.enumerated() {
            for seg in 0..<segments {
                let a = Float(seg) / Float(segments) * 2 * .pi + sec.twist
                let mul = shape?(si, seg) ?? 1
                let x = cos(a) * sec.radiusX * mul
                let z = sin(a) * sec.radiusZ * mul
                positions.append(sec.center + SIMD3(x, 0, z))
                normals.append(SIMD3(0, 1, 0))          // replaced below
                uvs.append(SIMD2(Float(seg) / Float(segments) * uvScale,
                                 Float(si) / Float(sections.count - 1) * uvScale))
            }
        }

        for si in 0..<(sections.count - 1) {
            for seg in 0..<segments {
                let nextSeg = (seg + 1) % segments
                let a = base + Int32(si * segments + seg)
                let b = base + Int32(si * segments + nextSeg)
                let c = base + Int32((si + 1) * segments + nextSeg)
                let d = base + Int32((si + 1) * segments + seg)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        if capStart, let first = sections.first {
            let centre = Int32(positions.count)
            positions.append(first.center)
            normals.append(SIMD3(0, -1, 0))
            uvs.append(SIMD2(0.5, 0))
            for seg in 0..<segments {
                let nextSeg = (seg + 1) % segments
                indices.append(contentsOf: [centre, base + Int32(nextSeg), base + Int32(seg)])
            }
        }
        if capEnd, let last = sections.last {
            let ring = Int32((sections.count - 1) * segments)
            let centre = Int32(positions.count)
            positions.append(last.center)
            normals.append(SIMD3(0, 1, 0))
            uvs.append(SIMD2(0.5, 1))
            for seg in 0..<segments {
                let nextSeg = (seg + 1) % segments
                indices.append(contentsOf: [centre, base + ring + Int32(seg), base + ring + Int32(nextSeg)])
            }
        }

        recomputeNormals(from: Int(base))
    }

    /// Grid plane with a height callback — ground, water, cloth, rubble fields.
    mutating func addHeightGrid(origin: SIMD3<Float>, size: SIMD2<Float>, divisions: SIMD2<Int>,
                                uvScale: Float = 1, height: (Float, Float) -> Float) {
        let (nx, nz) = (max(divisions.x, 1), max(divisions.y, 1))
        let base = Int32(positions.count)
        for iz in 0...nz {
            for ix in 0...nx {
                let u = Float(ix) / Float(nx), v = Float(iz) / Float(nz)
                let x = origin.x + u * size.x, z = origin.z + v * size.y
                positions.append(SIMD3(x, origin.y + height(x, z), z))
                normals.append(SIMD3(0, 1, 0))
                uvs.append(SIMD2(u * size.x * uvScale, v * size.y * uvScale))
            }
        }
        let stride = Int32(nx + 1)
        for iz in 0..<Int32(nz) {
            for ix in 0..<Int32(nx) {
                let i0 = base + iz * stride + ix
                let i1 = i0 + 1, i2 = i0 + stride, i3 = i2 + 1
                indices.append(contentsOf: [i0, i2, i3, i0, i3, i1])
            }
        }
        recomputeNormals(from: Int(base))
    }

    /// Tapered cylinder along +Y. Used for columns, pipes, trunks, limbs.
    mutating func addTube(base: SIMD3<Float>, height: Float, bottomRadius: Float, topRadius: Float,
                          segments: Int = 12, uvScale: Float = 1, capTop: Bool = false, capBottom: Bool = false) {
        let radii = Array(repeating: bottomRadius, count: max(segments, 3))
        let scale = bottomRadius > 1e-5 ? topRadius / bottomRadius : 1
        addPrism(center: base, radii: radii, height: height, topScale: scale,
                 uvScale: uvScale, capTop: capTop, capBottom: capBottom)
    }

    /// Appends another builder's triangles under a transform. Scattering fifty
    /// gravestones this way costs one draw call instead of fifty nodes.
    mutating func append(_ other: MeshBuilder, position: SIMD3<Float> = .zero,
                         yaw: Float = 0, pitch: Float = 0, scale: Float = 1) {
        guard !other.isEmpty else { return }
        let qy = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qp = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let q = qy * qp
        let base = Int32(positions.count)
        for i in other.positions.indices {
            positions.append(position + q.act(other.positions[i] * scale))
            normals.append(q.act(other.normals[i]))
            uvs.append(other.uvs[i])
        }
        for idx in other.indices { indices.append(base + idx) }
    }

    // MARK: Normals

    /// Area-weighted smooth normals over vertices added since `start`.
    mutating func recomputeNormals(from start: Int = 0) {
        guard positions.count > start else { return }
        for i in start..<normals.count { normals[i] = .zero }
        var i = 0
        while i + 2 < indices.count {
            let (ia, ib, ic) = (Int(indices[i]), Int(indices[i + 1]), Int(indices[i + 2]))
            i += 3
            guard ia >= start, ib >= start, ic >= start else { continue }
            // Un-normalised cross product is already area-weighted.
            let n = simd_cross(positions[ib] - positions[ia], positions[ic] - positions[ia])
            normals[ia] += n; normals[ib] += n; normals[ic] += n
        }
        for i in start..<normals.count {
            normals[i] = normals[i].lengthSquared > 1e-12 ? simd_normalize(normals[i]) : SIMD3(0, 1, 0)
        }
    }

    /// Nudges every vertex by a noise function — turns clean prisms into eroded
    /// stone. Call before `geometry()`; normals are rebuilt to match.
    mutating func jitter(_ amount: Float, seed: UInt64) {
        guard amount > 0 else { return }
        var rng = Rand(seed: seed)
        // Hash by rounded position so shared corners move together and the mesh
        // does not split apart at the seams.
        var offsets: [SIMD3<Int32>: SIMD3<Float>] = [:]
        for i in positions.indices {
            let key = SIMD3<Int32>(Int32((positions[i].x * 50).rounded()),
                                   Int32((positions[i].y * 50).rounded()),
                                   Int32((positions[i].z * 50).rounded()))
            let off: SIMD3<Float>
            if let existing = offsets[key] { off = existing }
            else {
                off = SIMD3(rng.gaussian(0, amount), rng.gaussian(0, amount * 0.6), rng.gaussian(0, amount))
                offsets[key] = off
            }
            positions[i] += off
        }
        recomputeNormals()
    }

    // MARK: Output

    func geometry(material: SCNMaterial? = nil) -> SCNGeometry {
        let vertexSource = SCNGeometrySource(vertices: positions.map { $0.scn })
        let normalSource = SCNGeometrySource(normals: normals.map { $0.scn })
        let uvSource = SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vertexSource, normalSource, uvSource], elements: [element])
        if let material { g.materials = [material] }
        return g
    }

    func node(material: SCNMaterial? = nil, name: String? = nil) -> SCNNode {
        let n = SCNNode(geometry: geometry(material: material))
        n.name = name
        return n
    }
}

// MARK: - Common geometry helpers

enum Geo {
    /// A flat quad in the XY plane facing +Z, centred on the origin. Decals,
    /// billboards, sprites.
    static func quad(width: Float, height: Float) -> SCNGeometry {
        var m = MeshBuilder()
        let hw = width / 2, hh = height / 2
        m.addQuad(SIMD3(-hw, -hh, 0), SIMD3(hw, -hh, 0), SIMD3(hw, hh, 0), SIMD3(-hw, hh, 0))
        // Rewrite UVs to a clean 0..1 — the edge-length derivation is wrong for sprites.
        let g = m.geometry()
        let uvSource = SCNGeometrySource(textureCoordinates: [
            CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)
        ])
        return SCNGeometry(sources: [g.sources(for: .vertex)[0], g.sources(for: .normal)[0], uvSource],
                           elements: g.elements)
    }

    /// Rounded limb segment. SceneKit's capsule is authored around its own axis
    /// with the origin at the centre; actors want the pivot at the joint, so this
    /// returns a node whose origin is the top of the segment.
    static func limb(length: Float, radius: Float, material: SCNMaterial) -> SCNNode {
        let capsule = SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(max(length, radius * 2.05)))
        capsule.radialSegmentCount = 10
        capsule.heightSegmentCount = 1
        capsule.materials = [material]
        let n = SCNNode(geometry: capsule)
        n.simdPosition = SIMD3(0, -length / 2, 0)
        let pivot = SCNNode()
        pivot.addChildNode(n)
        return pivot
    }
}
