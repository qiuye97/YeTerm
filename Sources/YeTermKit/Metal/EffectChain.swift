// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 辉光与余辉:两种"派生纹理"的加工车间
//
// 这个文件:两条特效的 GPU 加工线,输入都是合成好的内容大图 ——
//   ▸ 辉光 bloom:内容先缩小到 1/4(降采样),做稠密高斯模糊,再放大回去
//     叠加 = 文字周围的柔光。"先缩小再模糊"是图形学省钱套路:小图上模糊
//     5px 等效大图 20px,还更平滑。图周围留了圈"出血边距",光晕才能
//     自然溢进留白区(否则会被边界硬切,用户实测过的 bug)。
//   ▸ 余辉 burn-in:老 CRT 关掉内容后残影缓慢消退。实现是"乒乓缓冲":
//     两张纹理 A/B 轮流当"上一帧累积"和"本帧输出",每帧把旧影衰减一点
//     再叠上新内容 —— 类比双缓冲交换,或者两个变量倒手的 reduce 累积。
//
// 语法看点:
//   `private(set) var` —— 对外只读、对内可写的属性(类比只有 getter 的字段)。
//   `withUnsafeBytes(of:)` —— 把 struct 借出为字节串喂 GPU(作用域内有效)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Metal
import simd

/// 特效链资源(M1b):辉光模糊 + 余辉乒乓累积。GUI 与 harness 共用。
/// 与 cool-retro-term 的对应:bloomSource(FastBlur 输出)/ burnInSource(递归 SES)。
final class EffectChain {
    private let ctx: MetalContext
    private let renderer: OffscreenRenderer

    /// 特效关闭时的占位绑定(1×1 黑)
    let blackTexture: MTLTexture

    // 辉光:降采样链(1/2 → 1/4)+ 1/4 分辨率稠密高斯 H+V
    private var bloomHalf: MTLTexture?
    private var bloomQuarterA: MTLTexture?
    private var bloomQuarterB: MTLTexture?
    private var bloomQuarterC: MTLTexture?   // 双尺度光晕的「紧核」中间结果(v1.4)

    // 余辉:乒乓累积(内容分辨率 × 0.5,对应 burnInQuality 0.5 的缓冲缩放语义)
    private var burnA: MTLTexture?
    private var burnB: MTLTexture?
    private var burnUseA = true
    private(set) var burnInLastUpdate: Float = 0
    private(set) var prevLastUpdate: Float = 0

    private struct BlurUniforms {
        var direction: SIMD2<Float>
        var sigmaPx: Float
        var _pad: Float = 0
    }
    /// 双尺度光晕末趟合成用(与 Bloom.metal 的 DualBlurUniforms 逐字节一致,16B)
    private struct DualBlurUniforms {
        var direction: SIMD2<Float>
        var sigmaPx: Float
        var wideWeight: Float
    }
    private struct PadUniforms {
        var pad: SIMD2<Float>
    }

    /// 双尺度光晕的两个常数。**不是从照片拟合来的** —— 实测那张 VT220 照片的竖向剖面是
    /// 整行均值(含字间空隙),无法可靠地反卷积出点扩散函数,所以这两个值是按物理意图选的:
    /// 紧核 σ = 宽 σ / 4(半高宽约 0.5 倍墨迹高,接近照片量到的 0.62),长尾占 30%。
    /// 只知道方向对(真 halation 远端近似 1/x,比高斯衰减慢),数值可按口味调。
    static let tightSigmaRatio: Float = 4.0
    static let wideWeight: Float = 0.30

    /// 辉光纹理的出血边距(UV;CRT 主 pass 用它把内容 UV 映射进内嵌区)
    private(set) var bloomPadUV: SIMD2<Float> = .zero
    private struct BurnInUniforms {
        var burnInLastUpdate: Float
        var prevLastUpdate: Float
        var burnInTime: Float
        var _pad: Float = 0
        var cursorRect: SIMD4<Float> = .zero   // 光标块(合成 UV;w=0 无光标)→ 拖尾
        var cursorStyle: Float = 0
        var _pad2: Float = 0
        var _pad3: Float = 0
        var _pad4: Float = 0                   // 48B,与 BurnIn.metal 逐字节一致
    }

    init?(ctx: MetalContext) {
        self.ctx = ctx
        self.renderer = OffscreenRenderer(ctx: ctx)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let black = ctx.device.makeTexture(descriptor: desc) else { return nil }
        var zero: UInt32 = 0xFF000000
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        blackTexture = black
    }

    // MARK: - 辉光

    /// 内容纹理 → 1/2 → 1/4(带出血边距)降采样 → 1/4 分辨率稠密高斯 H+V → bloom 纹理。
    /// radiusPx 对标 FastBlur.radius=lint(16,64,q) **换算到物理像素**;σ = radius/2。
    /// 出血边距 = 光晕扩散范围(2.5σ):光晕溢入 pad 区,主 pass 里留白不再切断辉光。
    /// 只在内容变更时重算,1/4 分辨率下几十 tap 成本可忽略;线性上采样保证光晕平滑。
    ///
    /// `style`(v1.4):0 = 归一化高斯(缺省,与 v1.3 逐字节一致)/ 1 = 光晕 halation
    /// (加权 max)。只换 H/V 两趟的 fragment 函数名,降采样与纹理尺寸完全共用 ——
    /// 所以切换风格不会重建纹理、不会走 `makeTarget`(尺寸判据只看宽高)。
    /// pipeline 无需注册:`OffscreenRenderer.pipelineState` 按 "库名.函数名" 惰性建并缓存。
    ///
    /// `shape`(v1.4):0 = 单层(缺省)/ 1 = 紧核 + 长尾(双尺度)。用高斯的卷积半群性质
    /// `G_σ1 ∗ G_σ2 = G_√(σ1²+σ2²)` 省一趟:先做紧模糊得 T,再在 T 上做
    /// σ2 = √(σ宽²−σ紧²) 的模糊即得 σ宽 的宽模糊,末趟顺便把 T 采进来合成。
    /// **绝不能**在单趟里同时算两个高斯(会出十字伪影,理由见 Bloom.metal 的长注释)。
    func bloom(from content: MTLTexture, radiusPx: Float, wait: Bool,
               style: Int = 0, shape: Int = 0) -> MTLTexture? {
        let blurFn = style == 1 ? "blur_max_fragment" : "blur_fragment"
        let combineFn = style == 1 ? "blur_max_combine_fragment" : "blur_combine_fragment"
        let sigmaQ = max(radiusPx / 2.0 / 4.0, 0.5)
        let padQ = Int(ceil(sigmaQ * 2.5))
        let hw = max(content.width / 2, 1), hh = max(content.height / 2, 1)
        let qw = max(content.width / 4, 1) + 2 * padQ
        let qh = max(content.height / 4, 1) + 2 * padQ
        if bloomHalf == nil || bloomHalf!.width != hw || bloomHalf!.height != hh
            || bloomQuarterA?.width != qw || bloomQuarterA?.height != qh {
            bloomHalf = makeTarget(w: hw, h: hh)
            bloomQuarterA = makeTarget(w: qw, h: qh)
            bloomQuarterB = makeTarget(w: qw, h: qh)
            bloomQuarterC = makeTarget(w: qw, h: qh)
        }
        bloomPadUV = .init(Float(padQ) / Float(qw), Float(padQ) / Float(qh))
        guard let half = bloomHalf, let qa = bloomQuarterA, let qb = bloomQuarterB,
              let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        do {
            // 两级 2× 降采样:线性采样恰为 2×2 盒平均,细笔画不丢样;第二级同时内嵌出血边距
            try renderer.encode(into: half, commandBuffer: cmd, library: "Passthrough",
                                fragment: "passthrough_fragment", source: content)
            var up = PadUniforms(pad: bloomPadUV)
            try withUnsafeBytes(of: &up) { p in
                try renderer.encode(into: qa, commandBuffer: cmd, library: "Bloom",
                                    fragment: "pad_downsample_fragment", source: half, uniforms: p)
            }
            if shape == 1, let qc = bloomQuarterC {
                // ── 紧核 + 长尾(双尺度)──
                let sigmaTight = max(sigmaQ / Self.tightSigmaRatio, 0.5)
                // 半群:在紧模糊结果上再模糊 σ2,合成出 σ宽 = sigmaQ
                let sigma2 = max((sigmaQ * sigmaQ - sigmaTight * sigmaTight).squareRoot(), 0.5)
                var th = BlurUniforms(direction: .init(1.0 / Float(qw), 0), sigmaPx: sigmaTight)
                try withUnsafeBytes(of: &th) { p in
                    try renderer.encode(into: qb, commandBuffer: cmd, library: "Bloom",
                                        fragment: blurFn, source: qa, uniforms: p)
                }
                var tv = BlurUniforms(direction: .init(0, 1.0 / Float(qh)), sigmaPx: sigmaTight)
                try withUnsafeBytes(of: &tv) { p in
                    try renderer.encode(into: qc, commandBuffer: cmd, library: "Bloom",
                                        fragment: blurFn, source: qb, uniforms: p)   // qc = 紧核
                }
                var wh = BlurUniforms(direction: .init(1.0 / Float(qw), 0), sigmaPx: sigma2)
                try withUnsafeBytes(of: &wh) { p in
                    try renderer.encode(into: qb, commandBuffer: cmd, library: "Bloom",
                                        fragment: blurFn, source: qc, uniforms: p)
                }
                var wv = DualBlurUniforms(direction: .init(0, 1.0 / Float(qh)),
                                          sigmaPx: sigma2, wideWeight: Self.wideWeight)
                try withUnsafeBytes(of: &wv) { p in
                    try renderer.encode(into: qa, commandBuffer: cmd, library: "Bloom",
                                        fragment: combineFn, source: qb, uniforms: p,
                                        extraTextures: [qc])
                }
            } else {
            var uh = BlurUniforms(direction: .init(1.0 / Float(qw), 0), sigmaPx: sigmaQ)
            try withUnsafeBytes(of: &uh) { p in
                try renderer.encode(into: qb, commandBuffer: cmd, library: "Bloom",
                                    fragment: blurFn, source: qa, uniforms: p)
            }
            var uv = BlurUniforms(direction: .init(0, 1.0 / Float(qh)), sigmaPx: sigmaQ)
            try withUnsafeBytes(of: &uv) { p in
                try renderer.encode(into: qa, commandBuffer: cmd, library: "Bloom",
                                    fragment: blurFn, source: qb, uniforms: p)
            }
            }
        } catch {
            FileHandle.standardError.write(Data("bloom: \(error)\n".utf8))
            return nil
        }
        cmd.commit()
        if wait { cmd.waitUntilCompleted() }
        return bloomQuarterA
    }

    // MARK: - 余辉

    /// 清空余辉累积(2026-08-07 重影修复):标签切换/布局挪位后,缓冲里躺着的
    /// 是**旧几何/旧频道**的画面,拖出来就是一套错位重影。置 nil 即作废 ——
    /// 下次累积走"首建"分支,时间差把垃圾 prev 衰减干净(与冷启动同一条路)。
    func resetBurnIn() {
        burnA = nil
        burnB = nil
    }

    /// 内容更新驱动一次累积(对应原版 kterminal.onImagePainted)。返回最新累积纹理。
    func accumulateBurnIn(content: MTLTexture, time: Float, burnInTime: Float,
                          cursorRect: SIMD4<Float> = .zero, cursorStyle: Float = 0,
                          wait: Bool) -> MTLTexture? {
        let w = max(content.width / 2, 1), h = max(content.height / 2, 1)
        var justCreated = false
        if burnA == nil || burnA!.width != w || burnA!.height != h {
            burnA = makeTarget(w: w, h: h)
            burnB = makeTarget(w: w, h: h)
            burnUseA = true
            burnInLastUpdate = 0
            prevLastUpdate = 0
            justCreated = true
        }
        guard let a = burnA, let b = burnB,
              let cmd = ctx.queue.makeCommandBuffer() else { return nil }
        // 新建缓冲必须显式清零(2026-08-07 重影修复):Metal 纹理初始内容
        // **未定义**,常直接复用刚释放的旧缓冲内存 —— resetBurnIn 置 nil 重建后,
        // "垃圾"恰好就是上一个频道的旧帧,余辉把它原样拖回屏幕。
        // 【学】loadAction=.clear 的空 render pass = GPU 版 memset。
        if justCreated {
            for tex in [a, b] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = tex
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
        }
        let target = burnUseA ? a : b
        let prev = burnUseA ? b : a
        prevLastUpdate = burnInLastUpdate
        burnInLastUpdate = time
        var u = BurnInUniforms(burnInLastUpdate: burnInLastUpdate,
                               prevLastUpdate: prevLastUpdate,
                               burnInTime: burnInTime,
                               cursorRect: cursorRect,
                               cursorStyle: cursorStyle)
        do {
            try withUnsafeBytes(of: &u) { p in
                try renderer.encode(into: target, commandBuffer: cmd, library: "BurnIn",
                                    fragment: "burnin_accumulate_fragment", source: content,
                                    uniforms: p, extraTextures: [prev])
            }
        } catch {
            FileHandle.standardError.write(Data("burn-in: \(error)\n".utf8))
            return nil
        }
        cmd.commit()
        if wait { cmd.waitUntilCompleted() }
        burnUseA.toggle()
        return target
    }

    /// 当前累积纹理(帧间复用;无更新时沿用)
    var currentBurnIn: MTLTexture? {
        burnUseA ? burnB : burnA   // 上一次写入的那张
    }

    func invalidatePipelines() {
        renderer.invalidatePipelines()
    }

    private func makeTarget(w: Int, h: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        return ctx.device.makeTexture(descriptor: desc)
    }
}
