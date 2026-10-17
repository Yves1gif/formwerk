import Foundation
import Metal
import MetalKit
import simd

/// Draws a RenderScene with Metal: shaded bodies, crisp edges, sketch overlays, grid.
/// Also answers "what is under this point?" with an ID render pass.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState!
    private var meshAlphaPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var flatPipeline: MTLRenderPipelineState!
    private var meshPickPipeline: MTLRenderPipelineState!
    private var linePickPipeline: MTLRenderPipelineState!
    private var depthOn: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    static let sampleCount = 4
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float

    var scene = RenderScene() { didSet { needsDisplay = true } }
    var camera = Camera() { didSet { if camera != oldValue { needsDisplay = true; onCameraChange?(camera) } } }
    var onCameraChange: ((Camera) -> Void)?
    var clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
    var gridColor = SIMD4<Float>(0.3, 0.32, 0.36, 1)
    private(set) var viewSize: CGSize = CGSize(width: 1, height: 1)  // points
    private var pixelScale: CGFloat = 2
    private var needsDisplay = true

    private var animation: (from: Camera, to: Camera, start: CFTimeInterval, duration: Double)?

    private struct BodyBuffers {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
    }
    private var meshCache: [String: BodyBuffers] = [:]

    init?(device: MTLDevice?) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        do { try buildPipelines() } catch {
            print("Formwerk: Metal pipeline error \(error)")
            return nil
        }
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: ShaderSource.code, options: nil)

        func pipeline(_ vs: String, _ fs: String, blend: Bool, pick: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            if pick {
                d.colorAttachments[0].pixelFormat = .r32Uint
                d.depthAttachmentPixelFormat = Renderer.depthFormat
                d.rasterSampleCount = 1
            } else {
                d.colorAttachments[0].pixelFormat = Renderer.colorFormat
                d.depthAttachmentPixelFormat = Renderer.depthFormat
                d.rasterSampleCount = Renderer.sampleCount
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        meshPipeline = try pipeline("mesh_vertex", "mesh_fragment", blend: false)
        meshAlphaPipeline = try pipeline("mesh_vertex", "mesh_fragment", blend: true)
        linePipeline = try pipeline("line_vertex", "line_fragment", blend: true)
        pointPipeline = try pipeline("point_vertex", "point_fragment", blend: true)
        flatPipeline = try pipeline("flat_vertex", "flat_fragment", blend: true)
        meshPickPipeline = try pipeline("mesh_vertex", "mesh_pick", blend: false, pick: true)
        linePickPipeline = try pipeline("line_vertex", "line_pick", blend: false, pick: true)

        let on = MTLDepthStencilDescriptor()
        on.depthCompareFunction = .lessEqual
        on.isDepthWriteEnabled = true
        depthOn = device.makeDepthStencilState(descriptor: on)
        let ro = MTLDepthStencilDescriptor()
        ro.depthCompareFunction = .lessEqual
        ro.isDepthWriteEnabled = false
        depthReadOnly = device.makeDepthStencilState(descriptor: ro)
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: off)
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.sampleCount = Renderer.sampleCount
        view.clearColor = clearColor
        view.preferredFramesPerSecond = 120
        view.delegate = self
    }

    func setNeedsDisplay() { needsDisplay = true }

    /// For rendering without a window (self-test, thumbnails): the size picks and rays refer to.
    func setOffscreenSize(_ size: CGSize, scale: CGFloat = 2) {
        viewSize = size
        pixelScale = scale
    }

    /// Smoothly moves the camera.
    func animate(to target: Camera, duration: Double = 0.45) {
        animation = (camera, target, CACurrentMediaTime(), duration)
        needsDisplay = true
    }

    var isAnimating: Bool { animation != nil }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        pixelScale = view.bounds.width > 0 ? size.width / view.bounds.width : 2
        viewSize = view.bounds.size
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        if let a = animation {
            let t = min((CACurrentMediaTime() - a.start) / a.duration, 1)
            camera = Camera.interpolate(a.from, a.to, t)
            if t >= 1 { animation = nil }
        }
        if view.bounds.size != viewSize {
            viewSize = view.bounds.size
            pixelScale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 2
        }
        guard needsDisplay || animation != nil else { return }
        needsDisplay = false
        view.clearColor = clearColor
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeScene(enc, pick: false)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func uniforms() -> GPUUniforms {
        let vp = camera.viewProjection(size: viewSize).float
        let clip = scene.clipPlane
        return GPUUniforms(viewProj: vp,
                           cameraPos: SIMD4(camera.eye.float3, 1),
                           viewDir: SIMD4(camera.forward.float3, 0),
                           clipPlane: clip ?? .zero,
                           viewport: SIMD2(Float(viewSize.width * pixelScale), Float(viewSize.height * pixelScale)),
                           clipOn: clip == nil ? 0 : 1,
                           pixelScale: Float(pixelScale))
    }

    private func buffers(for body: RenderScene.Body) -> BodyBuffers? {
        if let b = meshCache[body.meshKey] { return b }
        let m = body.mesh
        guard !m.indices.isEmpty else { return nil }
        var verts = [GPUMeshVertex]()
        verts.reserveCapacity(m.positions.count)
        for i in m.positions.indices {
            let p = m.positions[i], n = m.normals[i]
            verts.append(GPUMeshVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z, face: UInt32(m.vertexFaces[i])))
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GPUMeshVertex>.stride),
              let ib = device.makeBuffer(bytes: m.indices, length: m.indices.count * 4) else { return nil }
        let b = BodyBuffers(vertices: vb, indices: ib, indexCount: m.indices.count)
        meshCache[body.meshKey] = b
        return b
    }

    /// Drops GPU buffers for meshes that are no longer in the scene.
    func purgeCache(keeping keys: Set<String>) {
        meshCache = meshCache.filter { keys.contains($0.key) }
    }

    private func edgeSegments(for body: RenderScene.Body, index: Int, pick: Bool) -> [GPULineSegment] {
        var segs: [GPULineSegment] = []
        for (edge, pts) in body.mesh.edgePolylines {
            let state = body.edgeStates[edge] ?? 0
            let color: SIMD4<Float> = state == 2 ? scene.selectColor : state == 1 ? scene.hoverColor : scene.edgeColor
            let width: Float = pick ? 12 : (state == 0 ? 1.3 : 3)
            let code = body.pickable ? PickCode.edge(body: index, edge: Int(edge)) : 0
            for k in 0..<(pts.count - 1) {
                segs.append(GPULineSegment(pts[k], pts[k + 1], color: color, width: width, pick: code))
            }
        }
        return segs
    }

    private func gridSegments() -> [GPULineSegment] {
        guard scene.showGrid else { return [] }
        // Spacing grows with distance: 1, 10, 100 mm …
        let raw = camera.distance / 15
        let spacing = pow(10, floor(log10(max(raw, 0.1))))
        let major = spacing * 10
        let extent = major * 8
        let plane = scene.gridPlane
        let c = plane.local(camera.target)
        let cx = (c.x / major).rounded() * major, cy = (c.y / major).rounded() * major
        var segs: [GPULineSegment] = []
        let n = Int(extent / spacing)
        for i in -n...n {
            let v = Double(i) * spacing
            let isMajor = abs((cx + v).truncatingRemainder(dividingBy: major)) < spacing * 0.01
            let isAxis = abs(cx + v) < spacing * 0.01
            let alpha: Float = isAxis ? 0 : (isMajor ? 0.28 : 0.11)
            if alpha > 0 {
                let col = SIMD4<Float>(gridColor.x, gridColor.y, gridColor.z, alpha)
                segs.append(GPULineSegment(plane.world(Vec2(cx + v, cy - extent)).float3,
                                           plane.world(Vec2(cx + v, cy + extent)).float3, color: col, width: 1))
            }
            let isMajorY = abs((cy + v).truncatingRemainder(dividingBy: major)) < spacing * 0.01
            let isAxisY = abs(cy + v) < spacing * 0.01
            let alphaY: Float = isAxisY ? 0 : (isMajorY ? 0.28 : 0.11)
            if alphaY > 0 {
                let col = SIMD4<Float>(gridColor.x, gridColor.y, gridColor.z, alphaY)
                segs.append(GPULineSegment(plane.world(Vec2(cx - extent, cy + v)).float3,
                                           plane.world(Vec2(cx + extent, cy + v)).float3, color: col, width: 1))
            }
        }
        // Axes: X red, Y green.
        let L = extent * 1.5
        segs.append(GPULineSegment(plane.world(Vec2(-L, 0)).float3, plane.world(Vec2(L, 0)).float3,
                                   color: SIMD4(0.9, 0.25, 0.25, 0.7), width: 1.5))
        segs.append(GPULineSegment(plane.world(Vec2(0, -L)).float3, plane.world(Vec2(0, L)).float3,
                                   color: SIMD4(0.25, 0.7, 0.3, 0.7), width: 1.5))
        return segs
    }

    private func drawLines(_ enc: MTLRenderCommandEncoder, _ segs: [GPULineSegment], widthScale: Float = 1) {
        guard !segs.isEmpty else { return }
        var scale = widthScale
        let length = segs.count * MemoryLayout<GPULineSegment>.stride
        if length < 4096 {
            enc.setVertexBytes(segs, length: length, index: 0)
        } else {
            guard let buf = device.makeBuffer(bytes: segs, length: length) else { return }
            enc.setVertexBuffer(buf, offset: 0, index: 0)
        }
        enc.setVertexBytes(&scale, length: 4, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segs.count)
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder, pick: Bool) {
        var u = uniforms()
        enc.setVertexBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)

        // Bodies
        enc.setDepthStencilState(depthOn)
        enc.setDepthBias(1, slopeScale: 1.5, clamp: 0.01)
        for (i, body) in scene.bodies.enumerated() {
            guard let b = buffers(for: body) else { continue }
            if pick && !body.pickable { continue }
            if pick { enc.setRenderPipelineState(meshPickPipeline) }
            else { enc.setRenderPipelineState(body.alpha < 1 ? meshAlphaPipeline : meshPipeline) }
            if body.alpha < 1 && !pick { enc.setDepthStencilState(depthReadOnly) } else { enc.setDepthStencilState(depthOn) }
            var bu = GPUBodyUniforms(color: body.color, hoverColor: scene.hoverColor, selectColor: scene.selectColor,
                                     pickBase: PickCode.face(body: i, face: 0), alpha: body.alpha)
            enc.setFragmentBytes(&bu, length: MemoryLayout<GPUBodyUniforms>.stride, index: 2)
            var states = body.faceStates
            let needed = max(body.faceCount + 1, 16)
            if states.count < needed { states += [UInt8](repeating: 0, count: needed - states.count) }
            if states.count <= 4096 {
                enc.setFragmentBytes(states, length: states.count, index: 3)
            } else if let buf = device.makeBuffer(bytes: states, length: states.count) {
                enc.setFragmentBuffer(buf, offset: 0, index: 3)
            }
            enc.setVertexBuffer(b.vertices, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                      indexBuffer: b.indices, indexBufferOffset: 0)
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)

        // Edges
        enc.setRenderPipelineState(pick ? linePickPipeline : linePipeline)
        enc.setDepthStencilState(pick ? depthOn : depthReadOnly)
        for (i, body) in scene.bodies.enumerated() where body.alpha >= 1 || !pick {
            if pick && !body.pickable { continue }
            drawLines(enc, edgeSegments(for: body, index: i, pick: pick))
        }
        if pick { return }

        // Grid and helper lines
        enc.setDepthStencilState(depthReadOnly)
        drawLines(enc, gridSegments())
        drawLines(enc, scene.lines)

        // Sketch region fills
        enc.setRenderPipelineState(flatPipeline)
        for fill in scene.fills where !fill.triangles.isEmpty {
            var color = fill.color
            let packed = fill.triangles.flatMap { [$0.x, $0.y, $0.z] }
            let len = packed.count * 4
            if len < 4096 { enc.setVertexBytes(packed, length: len, index: 0) }
            else if let buf = device.makeBuffer(bytes: packed, length: len) { enc.setVertexBuffer(buf, offset: 0, index: 0) }
            enc.setFragmentBytes(&color, length: 16, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fill.triangles.count)
        }

        // Active sketch on top
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(linePipeline)
        drawLines(enc, scene.overlayLines)
        if !scene.overlayPoints.isEmpty {
            enc.setRenderPipelineState(pointPipeline)
            let len = scene.overlayPoints.count * MemoryLayout<GPUPointSprite>.stride
            if len < 4096 { enc.setVertexBytes(scene.overlayPoints, length: len, index: 0) }
            else if let buf = device.makeBuffer(bytes: scene.overlayPoints, length: len) { enc.setVertexBuffer(buf, offset: 0, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: scene.overlayPoints.count)
        }
    }

    // MARK: - Offscreen images (thumbnails, self-test)

    /// Renders the current scene into an image of the given pixel size.
    func renderImage(width: Int, height: Int, pointScale: CGFloat = 2) -> CGImage? {
        let savedSize = viewSize, savedScale = pixelScale
        viewSize = CGSize(width: CGFloat(width) / pointScale, height: CGFloat(height) / pointScale)
        pixelScale = pointScale
        defer { viewSize = savedSize; pixelScale = savedScale }

        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, shared: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: d)
        }
        #if os(macOS)
        let readable = texture(Renderer.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], shared: false)
        #else
        let readable = texture(Renderer.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], shared: true)
        #endif
        guard let msaa = texture(Renderer.colorFormat, samples: Renderer.sampleCount, usage: .renderTarget),
              let depth = texture(Renderer.depthFormat, samples: Renderer.sampleCount, usage: .renderTarget),
              let resolve = readable,
              let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encodeScene(enc, pick: false)
        enc.endEncoding()
        let bytesPerRow = width * 4
        guard let out = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let data = Data(bytes: out.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Picking

    /// What lies under a screen point (points). Edges within a few points win over faces.
    func pick(at point: CGPoint) -> PickHit? {
        let w = Int(viewSize.width * pixelScale), h = Int(viewSize.height * pixelScale)
        guard w > 0, h > 0 else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.depthFormat, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: td), let depth = device.makeTexture(descriptor: dd),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        let radius = Int(7 * pixelScale)
        let px = Int(point.x * pixelScale), py = Int(point.y * pixelScale)
        let x0 = max(px - radius, 0), y0 = max(py - radius, 0)
        let x1 = min(px + radius, w - 1), y1 = min(py + radius, h - 1)
        guard x1 >= x0, y1 >= y0, let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
        encodeScene(enc, pick: true)
        enc.endEncoding()

        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        guard let readback = device.makeBuffer(length: rw * rh * 4, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: rw, height: rh, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: rw * 4, destinationBytesPerImage: rw * rh * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let values = readback.contents().bindMemory(to: UInt32.self, capacity: rw * rh)
        var bestEdge: (UInt32, Int)? = nil
        var centre: UInt32 = 0
        for y in 0..<rh {
            for x in 0..<rw {
                let v = values[y * rw + x]
                let dx = x0 + x - px, dy = y0 + y - py
                let d2 = dx * dx + dy * dy
                if dx == 0 && dy == 0 { centre = v }
                if v != 0 && v & PickCode.edgeFlag != 0 && d2 <= radius * radius {
                    if bestEdge == nil || d2 < bestEdge!.1 { bestEdge = (v, d2) }
                }
            }
        }
        if let e = bestEdge { return PickCode.decode(e.0) }
        if centre == 0 {
            // Taps right next to a body still count when nothing else is closer.
            var best: (UInt32, Int)? = nil
            for y in 0..<rh {
                for x in 0..<rw {
                    let v = values[y * rw + x]
                    guard v != 0 else { continue }
                    let dx = x0 + x - px, dy = y0 + y - py
                    let d2 = dx * dx + dy * dy
                    if d2 <= (radius / 2) * (radius / 2) && (best == nil || d2 < best!.1) { best = (v, d2) }
                }
            }
            return best.flatMap { PickCode.decode($0.0) }
        }
        return PickCode.decode(centre)
    }
}
