import Combine
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Draws a RenderScene with Metal: shaded bodies, crisp edges, contact shadows, sketch overlays, grid.
/// Also answers "what is under this point?" with an ID render pass.
///
/// Frames are drawn on demand. While something moves (a gesture, a camera transition, inertia, a zoom glide)
/// the view runs at up to 120 Hz; a quarter second after the last change it pauses itself, so a model that
/// just sits there costs no GPU time, battery or heat. Any change (camera, scene, colours, `setNeedsDisplay()`)
/// wakes it up again.
final class Renderer: NSObject, MTKViewDelegate, ObservableObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState!
    private var meshAlphaPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var gridPipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var flatPipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var meshPickPipeline: MTLRenderPipelineState!
    private var linePickPipeline: MTLRenderPipelineState!
    private var depthOn: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    static let sampleCount = 4
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float

    /// Edge widths in points. 1.1 pt lands on whole pixels at 1×, 2× and 3× (the shader rounds).
    static let edgeWidth: Float = 1.1
    static let highlightedEdgeWidth: Float = 2.75

    // Motion tuning
    /// How long the view keeps running at full rate after the last change before it pauses.
    static let idleDelay: CFTimeInterval = 0.25
    /// Inertia decays as exp(-t / τ).
    static let inertiaTimeConstant = 0.35
    /// Below this speed (points per second) inertia stops.
    static let inertiaStopSpeed = 12.0
    /// Slower releases are a deliberate stop, not a fling.
    static let minFlingSpeed = 120.0
    static let maxFlingSpeed = 6000.0
    static let zoomDuration = 0.18

    var scene = RenderScene() { didSet { sceneCache = SceneCache(); requestRedraw() } }
    var camera = Camera() {
        didSet {
            guard camera != oldValue else { return }
            onCameraChange?(camera)
            requestRedraw()
        }
    }
    var onCameraChange: ((Camera) -> Void)?
    var clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1) { didSet { requestRedraw() } }
    var gridColor = SIMD4<Float>(0.3, 0.32, 0.36, 1) { didSet { if gridColor != oldValue { requestRedraw() } } }

    /// The camera's turn and tilt, published at most once per displayed frame (for the view cube).
    @Published private(set) var orientation = CameraOrientation()

    private(set) var viewSize: CGSize = CGSize(width: 1, height: 1)  // points
    private var pixelScale: CGFloat = 2
    private var needsDisplay = true
    private weak var view: MTKView?
    private var lastActivity: CFTimeInterval = 0

    private struct CameraTransition {
        let from: Camera
        let to: Camera
        let start: CFTimeInterval
        let duration: Double
        /// What the transition set last; if the camera differs, a gesture took over.
        var last: Camera
    }
    private var transition: CameraTransition?

    private struct Inertia {
        enum Kind { case orbit, pan(CGSize) }
        let kind: Kind
        var velocity: SIMD2<Double>  // points per second
        var last: CFTimeInterval
    }
    private var inertia: Inertia?

    private struct ZoomGlide {
        var logFactor: Double
        /// Eased progress (0…1) already applied to the camera.
        var applied: Double
        var start: CFTimeInterval
        var point: CGPoint?
        var size: CGSize
    }
    private var zoomGlide: ZoomGlide?

    private struct BodyBuffers {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
    }
    private var meshCache: [String: BodyBuffers] = [:]

    /// Line segments ready to draw: inline bytes when small (setVertexBytes takes up to 4 KB), a buffer otherwise.
    private struct LineBatch {
        var inline: [GPULineSegment] = []
        var buffer: MTLBuffer?
        var count = 0
    }

    private struct ByteBatch {
        var inline: [UInt8] = []
        var buffer: MTLBuffer?
    }

    private struct FillBatch {
        var inline: [Float] = []
        var buffer: MTLBuffer?
        var vertexCount = 0
    }

    /// GPU-ready data derived from `scene`. Dropped whenever the scene changes, so orbiting and zooming
    /// reuse it instead of rebuilding thousands of edge segments every frame.
    private struct SceneCache {
        var edges: [Int: LineBatch] = [:]
        var pickEdges: [Int: LineBatch] = [:]
        var faceStates: [Int: ByteBatch] = [:]
        var lines: LineBatch?
        var overlayLines: LineBatch?
        var fills: [Int: FillBatch] = [:]
    }
    private var sceneCache = SceneCache()

    private struct GridKey: Equatable {
        var distance: Double
        var target: Vec3
        var plane: Plane
        var color: SIMD4<Float>
    }
    private struct GridDraw {
        let key: GridKey
        let batch: LineBatch
        let uniforms: GPUGridUniforms
    }
    /// The grid only depends on distance and target, so it survives a whole orbit.
    private var gridCache: GridDraw?

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
        gridPipeline = try pipeline("line_vertex", "grid_fragment", blend: true)
        pointPipeline = try pipeline("point_vertex", "point_fragment", blend: true)
        flatPipeline = try pipeline("flat_vertex", "flat_fragment", blend: true)
        shadowPipeline = try pipeline("shadow_vertex", "shadow_fragment", blend: true)
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
        // Apple GPUs keep the 4× MSAA depth buffer in tile memory only: no RAM, no bandwidth.
        if device.supportsFamily(.apple4) { view.depthStencilStorageMode = .memoryless }
        view.clearColor = clearColor
        view.preferredFramesPerSecond = 120
        // Start running; draw(in:) pauses the view once nothing has changed for `idleDelay`.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = self
        self.view = view
        needsDisplay = true
        lastActivity = CACurrentMediaTime()
        orientation = camera.orientation
    }

    /// Asks for one new frame (the view wakes up if it was idle).
    func setNeedsDisplay() { requestRedraw() }

    /// For rendering without a window (self-test, thumbnails): the size picks and rays refer to.
    func setOffscreenSize(_ size: CGSize, scale: CGFloat = 2) {
        viewSize = size
        pixelScale = scale
    }

    // MARK: - Camera motion

    /// True while a camera transition, inertia or a zoom glide is running.
    var isAnimating: Bool { transition != nil || inertia != nil || zoomGlide != nil }

    /// Smoothly moves the camera (ease-in-out). A gesture during the move takes over at once.
    /// With Reduce Motion on, the camera jumps.
    func animate(to target: Camera, duration: Double = 0.45) {
        inertia = nil
        zoomGlide = nil
        guard target != camera else { transition = nil; return }
        if duration <= 0 || Renderer.reduceMotion {
            transition = nil
            camera = target
            return
        }
        transition = CameraTransition(from: camera, to: target, start: CACurrentMediaTime(), duration: duration, last: camera)
        requestRedraw()
    }

    /// Keeps the orbit turning after the finger lifts and lets it slow down.
    /// `velocity`: points per second with the same signs as the `dx`/`dy` passed to `Camera.orbit`
    /// (for a pan gesture: its `velocity(in:)` at `.ended`).
    func flingOrbit(velocity: CGPoint) {
        startInertia(.orbit, velocity: velocity)
    }

    /// Keeps a two-finger pan gliding. Same sign convention as `Camera.pan(dx:dy:size:)`.
    func flingPan(velocity: CGPoint, size: CGSize) {
        startInertia(.pan(size), velocity: velocity)
    }

    /// Stops inertia and zoom glides (call at every touch-down). Camera transitions keep running
    /// unless the gesture actually moves the camera.
    func stopInertia() {
        inertia = nil
        zoomGlide = nil
        wake()  // a gesture is probably starting: be at full frame rate for its first frame
    }

    /// Zooms by `factor` (< 1 = closer) towards `point` with a short ease-out (~0.18 s).
    /// Calls during a glide add up (mouse wheel ticks, repeated key presses).
    func animateZoom(factor: Double, at point: CGPoint?, size: CGSize) {
        guard factor.isFinite, factor > 0, abs(factor - 1) > 1e-9 else { return }
        if Renderer.reduceMotion {
            camera.zoom(factor: factor, at: point, size: size)
            return
        }
        transition = nil
        var amount = log(factor)
        if let z = zoomGlide { amount += z.logFactor * (1 - z.applied) }
        zoomGlide = ZoomGlide(logFactor: amount, applied: 0, start: CACurrentMediaTime(), point: point, size: size)
        requestRedraw()
    }

    private func startInertia(_ kind: Inertia.Kind, velocity: CGPoint) {
        inertia = nil
        guard !Renderer.reduceMotion else { return }
        var v = SIMD2<Double>(Double(velocity.x), Double(velocity.y))
        guard v.x.isFinite, v.y.isFinite else { return }
        let speed = simd_length(v)
        guard speed >= Renderer.minFlingSpeed else { return }
        if speed > Renderer.maxFlingSpeed { v *= Renderer.maxFlingSpeed / speed }
        transition = nil
        inertia = Inertia(kind: kind, velocity: v, last: CACurrentMediaTime())
        requestRedraw()
    }

    static var reduceMotion: Bool {
        #if os(iOS)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// Advances transitions, zoom glides and inertia to `now`. Returns true while any of them still runs.
    @discardableResult
    private func advanceMotion(to now: CFTimeInterval) -> Bool {
        if let t = transition {
            if camera != t.last {
                transition = nil  // a gesture moved the camera meanwhile: the hand wins
            } else {
                let p = t.duration > 0 ? min(max((now - t.start) / t.duration, 0), 1) : 1
                let c = p >= 1 ? t.to : Camera.interpolate(t.from, t.to, p)
                if p >= 1 { transition = nil } else { transition?.last = c }
                camera = c
            }
        }

        if var z = zoomGlide {
            let t = min(max((now - z.start) / Renderer.zoomDuration, 0), 1)
            let eased = 1 - pow(1 - t, 3)  // ease-out cubic
            let step = (eased - z.applied) * z.logFactor
            z.applied = eased
            zoomGlide = t >= 1 ? nil : z
            if abs(step) > 1e-12 { camera.zoom(factor: exp(step), at: z.point, size: z.size) }
        }

        if var i = inertia {
            let dt = min(max(now - i.last, 0), 0.05)  // a hitch shouldn't turn into a jump
            i.last = now
            let tau = Renderer.inertiaTimeConstant
            let decay = exp(-dt / tau)
            // Exact distance travelled under exponential decay: frame-rate independent.
            let travel = i.velocity * (tau * (1 - decay))
            i.velocity *= decay
            switch i.kind {
            case .orbit:
                camera.orbit(dx: travel.x, dy: travel.y)
                // Pitch is clamped: stop pushing against the pole instead of spinning invisibly.
                if abs(camera.pitch) >= Camera.maxPitch - 1e-6 && travel.y * camera.pitch > 0 { i.velocity.y = 0 }
            case .pan(let size):
                camera.pan(dx: travel.x, dy: travel.y, size: size)
            }
            inertia = simd_length(i.velocity) < Renderer.inertiaStopSpeed ? nil : i
        }
        return isAnimating
    }

    // MARK: - Frame pacing

    private func requestRedraw() {
        needsDisplay = true
        wake()
    }

    /// Runs the view at full rate again (it pauses itself in `draw(in:)` when idle).
    private func wake() {
        lastActivity = CACurrentMediaTime()
        guard let view, view.isPaused else { return }
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    private func sleepIfIdle(_ view: MTKView, now: CFTimeInterval) {
        guard !view.isPaused, !isAnimating, !needsDisplay, now - lastActivity > Renderer.idleDelay else { return }
        // Paused + setNeedsDisplay: the system still asks for frames on resize or when the view reappears.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        pixelScale = view.bounds.width > 0 ? size.width / view.bounds.width : 2
        viewSize = view.bounds.size
        requestRedraw()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        // A paused view only gets here when the system needs a frame (first show, resize, back from background).
        let systemRequest = view.isPaused
        if view.bounds.size != viewSize {
            viewSize = view.bounds.size
            pixelScale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 2
            needsDisplay = true
        }
        let moving = advanceMotion(to: now)
        // Once per frame at most: that is the throttle for everything observing the orientation.
        let o = camera.orientation
        if o != orientation { orientation = o }

        if needsDisplay || systemRequest {
            needsDisplay = false
            if !render(in: view) { needsDisplay = true }  // no drawable this time: try again next frame
        }
        if moving { lastActivity = now } else { sleepIfIdle(view, now: now) }
    }

    /// Encodes and presents one frame. False if the view had no drawable.
    private func render(in view: MTKView) -> Bool {
        view.clearColor = clearColor
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return false }
        // Depth is never read back (and may live in tile memory only).
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encodeScene(enc, pick: false)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    private func uniforms() -> GPUUniforms {
        let vp = camera.viewProjection(size: viewSize).float
        let clip = scene.clipPlane
        return GPUUniforms(viewProj: vp,
                           cameraPos: SIMD4(camera.eye.float3, 1),
                           viewDir: SIMD4(camera.forward.float3, 0),
                           cameraRight: SIMD4(camera.right.float3, 0),
                           cameraUp: SIMD4(camera.up.float3, 0),
                           clipPlane: clip ?? .zero,
                           viewport: SIMD2(Float(viewSize.width * pixelScale), Float(viewSize.height * pixelScale)),
                           clipOn: clip == nil ? 0 : 1,
                           pixelScale: Float(pixelScale))
    }

    // MARK: - GPU data

    private func buffers(for body: RenderScene.Body) -> BodyBuffers? {
        if let b = meshCache[body.meshKey] { return b }
        let m = body.mesh
        guard !m.indices.isEmpty else { return nil }
        var verts = [GPUMeshVertex]()
        verts.reserveCapacity(m.positions.count)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in m.positions.indices {
            let p = m.positions[i], n = m.normals[i]
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
            verts.append(GPUMeshVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z, face: UInt32(m.vertexFaces[i])))
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GPUMeshVertex>.stride),
              let ib = device.makeBuffer(bytes: m.indices, length: m.indices.count * 4) else { return nil }
        let b = BodyBuffers(vertices: vb, indices: ib, indexCount: m.indices.count, boundsMin: lo, boundsMax: hi)
        meshCache[body.meshKey] = b
        return b
    }

    /// Drops GPU buffers for meshes that are no longer in the scene.
    func purgeCache(keeping keys: Set<String>) {
        meshCache = meshCache.filter { keys.contains($0.key) }
    }

    private func makeBatch(_ segs: [GPULineSegment]) -> LineBatch {
        guard !segs.isEmpty else { return LineBatch() }
        let length = segs.count * MemoryLayout<GPULineSegment>.stride
        if length < 4096 { return LineBatch(inline: segs, buffer: nil, count: segs.count) }
        guard let buf = device.makeBuffer(bytes: segs, length: length) else { return LineBatch() }
        return LineBatch(inline: [], buffer: buf, count: segs.count)
    }

    private func edgeSegments(for body: RenderScene.Body, index: Int, pick: Bool) -> [GPULineSegment] {
        var segs: [GPULineSegment] = []
        for (edge, pts) in body.mesh.edgePolylines {
            guard pts.count > 1 else { continue }
            let state = body.edgeStates[edge] ?? 0
            let color: SIMD4<Float> = state == 2 ? scene.selectColor : state == 1 ? scene.hoverColor : scene.edgeColor
            let width: Float = pick ? 12 : (state == 0 ? Renderer.edgeWidth : Renderer.highlightedEdgeWidth)
            let code = body.pickable ? PickCode.edge(body: index, edge: Int(edge)) : 0
            for k in 0..<(pts.count - 1) {
                segs.append(GPULineSegment(pts[k], pts[k + 1], color: color, width: width, pick: code))
            }
        }
        return segs
    }

    private func edgeBatch(for body: RenderScene.Body, index: Int, pick: Bool) -> LineBatch {
        if let cached = pick ? sceneCache.pickEdges[index] : sceneCache.edges[index] { return cached }
        let batch = makeBatch(edgeSegments(for: body, index: index, pick: pick))
        if pick { sceneCache.pickEdges[index] = batch } else { sceneCache.edges[index] = batch }
        return batch
    }

    private func faceStates(for body: RenderScene.Body, index: Int) -> ByteBatch {
        if let cached = sceneCache.faceStates[index] { return cached }
        var states = body.faceStates
        let needed = max(body.faceCount + 1, 16)
        if states.count < needed { states += [UInt8](repeating: 0, count: needed - states.count) }
        let batch = states.count <= 4096
            ? ByteBatch(inline: states, buffer: nil)
            : ByteBatch(inline: [], buffer: device.makeBuffer(bytes: states, length: states.count))
        sceneCache.faceStates[index] = batch
        return batch
    }

    private func fillBatch(_ index: Int, _ triangles: [SIMD3<Float>]) -> FillBatch {
        if let cached = sceneCache.fills[index] { return cached }
        var packed: [Float] = []
        packed.reserveCapacity(triangles.count * 3)
        for t in triangles { packed.append(t.x); packed.append(t.y); packed.append(t.z) }
        let length = packed.count * 4
        let batch = length < 4096
            ? FillBatch(inline: packed, buffer: nil, vertexCount: triangles.count)
            : FillBatch(inline: [], buffer: device.makeBuffer(bytes: packed, length: length), vertexCount: triangles.count)
        sceneCache.fills[index] = batch
        return batch
    }

    private func gridDraw() -> GridDraw? {
        guard scene.showGrid else { return nil }
        let key = GridKey(distance: camera.distance, target: camera.target, plane: scene.gridPlane, color: gridColor)
        if let g = gridCache, g.key == key { return g }
        let (segs, u) = gridSegments()
        let g = GridDraw(key: key, batch: makeBatch(segs), uniforms: u)
        gridCache = g
        return g
    }

    private func gridSegments() -> ([GPULineSegment], GPUGridUniforms) {
        let plane = scene.gridPlane
        // Spacing grows with distance: 1, 10, 100 mm … `blend` (0…1) says how close the next step is:
        // the finest lines fade out and the 10× lines fade down to minor strength before the step,
        // so zooming never makes the grid pop.
        let exponent = log10(max(camera.distance / 15, 0.01))
        let spacing = pow(10, floor(exponent))
        let blend = exponent - floor(exponent)
        let major = spacing * 10
        // The grid fades out at `radius` (shader); build just enough lines to reach it.
        let radius = camera.distance * 2.0
        let extent = (radius / major).rounded(.up) * major + major
        let c = plane.local(camera.target)
        let cx = (c.x / major).rounded() * major, cy = (c.y / major).rounded() * major
        let n = Int((extent / spacing).rounded())
        let i0x = Int((cx / spacing).rounded()), i0y = Int((cy / spacing).rounded())
        let minorAlpha = Float(0.11 * (1 - blend))
        let majorAlpha = Float(0.28 - 0.17 * blend)
        func alpha(_ k: Int) -> Float {
            if k == 0 { return 0 }  // the axes are drawn separately
            if k % 100 == 0 { return 0.28 }
            if k % 10 == 0 { return majorAlpha }
            return minorAlpha
        }
        func color(_ a: Float) -> SIMD4<Float> { SIMD4(gridColor.x, gridColor.y, gridColor.z, a) }

        var segs: [GPULineSegment] = []
        segs.reserveCapacity(4 * n + 4)
        for i in -n...n {
            let v = Double(i) * spacing
            let ax = alpha(i0x + i)
            if ax >= 0.015 {
                segs.append(GPULineSegment(plane.world(Vec2(cx + v, cy - extent)).float3,
                                           plane.world(Vec2(cx + v, cy + extent)).float3, color: color(ax), width: 1))
            }
            let ay = alpha(i0y + i)
            if ay >= 0.015 {
                segs.append(GPULineSegment(plane.world(Vec2(cx - extent, cy + v)).float3,
                                           plane.world(Vec2(cx + extent, cy + v)).float3, color: color(ay), width: 1))
            }
        }
        // Axes: X red, Y green, spanning the visible grid wherever it is.
        segs.append(GPULineSegment(plane.world(Vec2(cx - extent, 0)).float3, plane.world(Vec2(cx + extent, 0)).float3,
                                   color: SIMD4(0.9, 0.25, 0.25, 0.7), width: 1.5))
        segs.append(GPULineSegment(plane.world(Vec2(0, cy - extent)).float3, plane.world(Vec2(0, cy + extent)).float3,
                                   color: SIMD4(0.25, 0.7, 0.3, 0.7), width: 1.5))
        let center = plane.world(c)
        let u = GPUGridUniforms(center: SIMD4(center.float3, Float(radius)),
                                normal: SIMD4(plane.normal.normalized.float3, 0))
        return (segs, u)
    }

    private func drawLines(_ enc: MTLRenderCommandEncoder, _ batch: LineBatch, widthScale: Float = 1) {
        guard batch.count > 0 else { return }
        if let buf = batch.buffer {
            enc.setVertexBuffer(buf, offset: 0, index: 0)
        } else if !batch.inline.isEmpty {
            enc.setVertexBytes(batch.inline, length: batch.inline.count * MemoryLayout<GPULineSegment>.stride, index: 0)
        } else {
            return
        }
        var scale = widthScale
        enc.setVertexBytes(&scale, length: 4, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: batch.count)
    }

    // MARK: - Encoding

    private func drawBody(_ enc: MTLRenderCommandEncoder, _ body: RenderScene.Body, index i: Int, pick: Bool) {
        if pick && !body.pickable { return }
        guard let b = buffers(for: body) else { return }
        let states = faceStates(for: body, index: i)
        if let buf = states.buffer {
            enc.setFragmentBuffer(buf, offset: 0, index: 3)
        } else if !states.inline.isEmpty {
            enc.setFragmentBytes(states.inline, length: states.inline.count, index: 3)
        } else {
            return
        }
        if pick {
            enc.setRenderPipelineState(meshPickPipeline)
            enc.setDepthStencilState(depthOn)
        } else if body.alpha < 1 {
            enc.setRenderPipelineState(meshAlphaPipeline)
            enc.setDepthStencilState(depthReadOnly)
        } else {
            enc.setRenderPipelineState(meshPipeline)
            enc.setDepthStencilState(depthOn)
        }
        var bu = GPUBodyUniforms(color: body.color, hoverColor: scene.hoverColor, selectColor: scene.selectColor,
                                 pickBase: PickCode.face(body: i, face: 0), alpha: body.alpha)
        enc.setFragmentBytes(&bu, length: MemoryLayout<GPUBodyUniforms>.stride, index: 2)
        enc.setVertexBuffer(b.vertices, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                  indexBuffer: b.indices, indexBufferOffset: 0)
    }

    /// Soft contact shadows: a blurred footprint under each opaque body, on the ground plane
    /// (z = 0, or the lowest body bottom if something reaches below). One quad per body.
    private func drawShadows(_ enc: MTLRenderCommandEncoder) {
        guard scene.showShadows else { return }
        var footprints: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] = []
        for body in scene.bodies where body.alpha >= 1 {
            guard let b = buffers(for: body), b.boundsMin.x <= b.boundsMax.x else { continue }
            footprints.append((b.boundsMin, b.boundsMax))
        }
        guard let lowest = footprints.map({ $0.lo.z }).min() else { return }
        let ground = min(0, lowest)
        // From below the ground there is nothing to cast a shadow on.
        guard camera.eye.z > Double(ground) + 1e-3 else { return }
        let darkBackground = (clearColor.red + clearColor.green + clearColor.blue) / 3 < 0.5
        let strength: Float = darkBackground ? 0.34 : 0.2
        enc.setRenderPipelineState(shadowPipeline)
        enc.setDepthStencilState(depthReadOnly)
        for f in footprints {
            let sx = f.hi.x - f.lo.x, sy = f.hi.y - f.lo.y
            let size = max(max(sx, sy), 0.5)
            let height = max(f.lo.z - ground, 0)
            // Floating parts throw a wider, fainter shadow: you can see they don't touch the bed.
            let blur = size * 0.12 + height * 0.4
            let darkness = strength / (1 + 2.5 * height / size)
            var s = GPUShadow(rect: SIMD4(f.lo.x, f.lo.y, f.hi.x, f.hi.y),
                              params: SIMD4(ground - size * 0.0005, blur, min(sx, sy) * 0.3, darkness))
            enc.setVertexBytes(&s, length: MemoryLayout<GPUShadow>.stride, index: 2)
            enc.setFragmentBytes(&s, length: MemoryLayout<GPUShadow>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder, pick: Bool) {
        var u = uniforms()
        enc.setVertexBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)

        // Bodies: opaque ones first, then the ground shadows, then see-through previews on top.
        enc.setDepthBias(1, slopeScale: 1.5, clamp: 0.01)
        for (i, body) in scene.bodies.enumerated() where pick || body.alpha >= 1 {
            drawBody(enc, body, index: i, pick: pick)
        }
        if !pick {
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            drawShadows(enc)
            enc.setDepthBias(1, slopeScale: 1.5, clamp: 0.01)
            for (i, body) in scene.bodies.enumerated() where body.alpha < 1 {
                drawBody(enc, body, index: i, pick: false)
            }
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)

        // Edges
        enc.setRenderPipelineState(pick ? linePickPipeline : linePipeline)
        enc.setDepthStencilState(pick ? depthOn : depthReadOnly)
        for (i, body) in scene.bodies.enumerated() where body.alpha >= 1 || !pick {
            if pick && !body.pickable { continue }
            drawLines(enc, edgeBatch(for: body, index: i, pick: pick))
        }
        if pick { return }

        // Grid (fades towards its edge and the horizon) and helper lines
        enc.setDepthStencilState(depthReadOnly)
        if let grid = gridDraw() {
            enc.setRenderPipelineState(gridPipeline)
            var g = grid.uniforms
            enc.setFragmentBytes(&g, length: MemoryLayout<GPUGridUniforms>.stride, index: 2)
            drawLines(enc, grid.batch)
            enc.setRenderPipelineState(linePipeline)
        }
        if sceneCache.lines == nil { sceneCache.lines = makeBatch(scene.lines) }
        if let lines = sceneCache.lines { drawLines(enc, lines) }

        // Sketch region fills
        enc.setRenderPipelineState(flatPipeline)
        for (k, fill) in scene.fills.enumerated() where !fill.triangles.isEmpty {
            let f = fillBatch(k, fill.triangles)
            if let buf = f.buffer { enc.setVertexBuffer(buf, offset: 0, index: 0) }
            else if !f.inline.isEmpty { enc.setVertexBytes(f.inline, length: f.inline.count * 4, index: 0) }
            else { continue }
            var color = fill.color
            enc.setFragmentBytes(&color, length: 16, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: f.vertexCount)
        }

        // Active sketch on top
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(linePipeline)
        if sceneCache.overlayLines == nil { sceneCache.overlayLines = makeBatch(scene.overlayLines) }
        if let overlay = sceneCache.overlayLines { drawLines(enc, overlay) }
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
        // Without a view nothing advances camera transitions: catch up so the image shows where they lead.
        advanceMotion(to: CACurrentMediaTime())
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
