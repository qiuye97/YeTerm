// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 全屏特效的"执行小工"
//
// 这个文件:封装 GPU 上最常用的一种操作——「全屏 pass」:拿一张输入纹理,
//   跑一个片元着色器,写出一张输出纹理。CRT 特效、辉光模糊、分屏合成
//   全靠它反复调用。理解一个词就够了:
//   ▸ pipeline(渲染管线):顶点着色器+片元着色器+输出格式的组合,
//     创建很贵所以要缓存(pipelineCache 字典)—— 类比 PreparedStatement。
//   还有个小魔术「全屏三角形」:画一个超出屏幕的大三角形恰好盖满全屏,
//   比画两个三角形拼矩形省事(GPU 界的老把戏,见 Passthrough.metal 顶点函数)。
//   encodeComposite 里的 viewport 技巧:把"视口"设成小矩形,让全屏三角形
//   只铺那一块 —— 我们用它把各分屏纹理拼进大图、顺手画荧光分割线。
//
// 语法看点:
//   `UnsafeRawBufferPointer` —— 裸内存指针(uniforms 结构体按字节喂给 GPU),
//     Swift 里带 Unsafe 前缀的都是"越过安全检查"的底层操作,用完即弃。
//   `throws` + `defer` 风格的资源管理;`guard let enc = ... else { throw }`。
// ─────────────────────────────────────────────────────────────────────────────
import CoreGraphics
import Foundation
import Metal

/// 离屏全屏 pass 渲染器:CPU 位图 → 纹理 → 全屏三角形 fragment → 目标纹理 → 回读 CGImage。
/// 色彩纪律:全链 `.bgra8Unorm`(**非** `_srgb` 变体)—— 按 sRGB 编码值直算,
/// 与 cool-retro-term 的 GLSL 数学假设一致(原版就是按 gamma 编码值做数学,
/// 线性化会改变所有移植常数的观感)。
final class OffscreenRenderer {
    let ctx: MetalContext
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]

    init(ctx: MetalContext) {
        self.ctx = ctx
    }

    /// 往指定目标纹理编码一个全屏 pass(离屏与 GUI drawable 共用)。
    /// `uniforms` 原样绑到 buffer(0);`extraTextures` 依序绑到 texture(1..)。
    func encode(into target: MTLTexture,
                commandBuffer cmd: MTLCommandBuffer,
                library: String,
                fragment: String,
                source: MTLTexture,
                uniforms: UnsafeRawBufferPointer? = nil,
                extraTextures: [MTLTexture] = []) throws {
        let pipeline = try pipelineState(library: library, fragment: fragment)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.resourceCreation
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        for (i, t) in extraTextures.enumerated() {
            enc.setFragmentTexture(t, index: i + 1)
        }
        if let u = uniforms, u.count > 0 {
            enc.setFragmentBytes(u.baseAddress!, length: u.count, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// 分屏合成 pass(M2 单显示器语义):清黑后把各 pane 内容纹理按视口位摆进
    /// 合成画面,再画荧光分割线(viewport 即画布区域,全屏三角形恰好铺满视口)。
    /// draws.texture == nil 表示实色白块(分割线)。
    /// draws.clip(2026-08-26 分屏恢复压叠防御层):非 nil 时以 scissor 把这一笔
    /// 钉死在矩形内 —— pane 内容纵有布局瞬变也**绝不**画到邻居 pane 头上。
    /// 【学】viewport 决定"纹理铺在哪、铺多大"(会缩放),scissor 只做剪刀
    /// (超出部分丢弃、不缩放)—— 裁剪必须用后者,前者会把画面压扁。
    /// `background`(v1.2 #16 普通模式背景图):非 nil 时先把它 aspect-fill 铺满
    /// 全画面,pane 内容改用**预乘 alpha 混合**叠上(内容纹理透明清屏 + 字形
    /// 覆盖度即预乘形式,默认底色格透出背景图,彩色块/文字照常遮盖)。
    func encodeComposite(into target: MTLTexture,
                         commandBuffer cmd: MTLCommandBuffer,
                         draws: [(texture: MTLTexture?, viewport: MTLViewport, clip: CGRect?)],
                         clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                         background: MTLTexture? = nil) throws {
        let blit = try pipelineState(library: "Passthrough", fragment: "passthrough_fragment",
                                     blending: background != nil)
        let solid = try pipelineState(library: "Passthrough", fragment: "solid_white_fragment")

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // margin 留白/格子整除余量都露这个色:CRT=黑(机壳盖住);
        // 直通模式=用户背景色(padding 融入背景,Terminal.app 同款,v1.2 实测勘差)
        pass.colorAttachments[0].clearColor = clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.resourceCreation
        }
        let W = Double(target.width), H = Double(target.height)
        // 背景图第一笔:全幅视口 + aspect-fill 裁剪(比例不合的边裁掉不拉伸)
        if let bg = background, bg.width > 0, bg.height > 0 {
            let bgPipe = try pipelineState(library: "Passthrough", fragment: "plain_bg_fill_fragment")
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: W, height: H, znear: 0, zfar: 1))
            enc.setRenderPipelineState(bgPipe)
            enc.setFragmentTexture(bg, index: 0)
            let targetAspect = Float(W / H)
            let imgAspect = Float(bg.width) / Float(bg.height)
            var uvScale = SIMD2<Float>(min(1, targetAspect / imgAspect),
                                       min(1, imgAspect / targetAspect))
            enc.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        for d in draws {
            // 视口裁进目标范围(Metal 越界视口非法)
            var vp = d.viewport
            let x0 = max(0, vp.originX), y0 = max(0, vp.originY)
            let x1 = min(W, vp.originX + vp.width), y1 = min(H, vp.originY + vp.height)
            guard x1 - x0 >= 1, y1 - y0 >= 1 else { continue }
            vp = MTLViewport(originX: x0, originY: y0, width: x1 - x0, height: y1 - y0,
                             znear: 0, zfar: 1)
            enc.setViewport(vp)
            // scissor 同样必须整个落在目标内;剪没了就跳过这一笔
            var scissor = MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height)
            if let clip = d.clip {
                let cx0 = max(0.0, Double(clip.minX)), cy0 = max(0.0, Double(clip.minY))
                let cx1 = min(W, Double(clip.maxX)), cy1 = min(H, Double(clip.maxY))
                guard cx1 - cx0 >= 1, cy1 - cy0 >= 1 else { continue }
                scissor = MTLScissorRect(x: Int(cx0), y: Int(cy0),
                                         width: Int(cx1 - cx0), height: Int(cy1 - cy0))
            }
            enc.setScissorRect(scissor)
            if let tex = d.texture {
                enc.setRenderPipelineState(blit)
                enc.setFragmentTexture(tex, index: 0)
            } else {
                enc.setRenderPipelineState(solid)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    /// 离屏一趟:自建目标纹理 + 同步等待(harness 用)
    func renderFullscreen(library: String,
                          fragment: String,
                          source: MTLTexture,
                          uniforms: UnsafeRawBufferPointer? = nil,
                          extraTextures: [MTLTexture] = [],
                          outWidth: Int, outHeight: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: outWidth,
                                                            height: outHeight,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let out = ctx.device.makeTexture(descriptor: desc),
              let cmd = ctx.queue.makeCommandBuffer() else {
            throw RenderError.resourceCreation
        }
        try encode(into: out, commandBuffer: cmd,
                   library: library, fragment: fragment,
                   source: source, uniforms: uniforms, extraTextures: extraTextures)
        cmd.commit()
        cmd.waitUntilCompleted()
        return out
    }

    /// 热重载:连同 MetalContext 的库缓存一起失效
    func invalidatePipelines() {
        pipelineCache.removeAll()
        ctx.invalidateCache()
    }

    /// 目标纹理回读为 CGImage(BGRA8/premultipliedFirst/little-endian/sRGB,与捕获归一化同构)
    func readback(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        buf.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider,
                       decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    enum RenderError: Error, CustomStringConvertible {
        case resourceCreation
        var description: String { "Metal 资源创建失败" }
    }

    private func pipelineState(library: String, fragment: String,
                               blending: Bool = false) throws -> MTLRenderPipelineState {
        let key = "\(library).\(fragment)\(blending ? ".blend" : "")"
        if let cached = pipelineCache[key] { return cached }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try ctx.function("fsq_vertex", library: "Passthrough")
        desc.fragmentFunction = try ctx.function(fragment, library: library)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        if blending {
            // 预乘 alpha 混合(v1.2 #16):内容纹理透明清屏后,字形边缘的
            // rgb 已含覆盖度(= 预乘形式)→ 因子取 one/oneMinusSourceAlpha
            let att = desc.colorAttachments[0]!
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        // 走 MetalContext 统一漏斗 → 命中管线二进制缓存(v1.2 #1)
        let ps = try ctx.makePipeline(desc)
        pipelineCache[key] = ps
        return ps
    }
}
