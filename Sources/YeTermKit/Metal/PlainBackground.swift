// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 普通模式背景图片的"暗房"(v1.2 #16)
//
// 这个文件:普通终端模式(CRT 总开关关)可以给终端配一张背景图片,
//   并选一种特效(无变化/毛玻璃/像素风/暗化/黑白胶片)。本类负责:
//   ①把图片文件读成 GPU 纹理;②把选中的特效**一次性**加工进纹理缓存。
//   之后每帧合成只是"把这张成品图铺在最底下"——特效不占每帧开销,
//   类比做菜:配料预处理好冷藏(本类),开饭时直接端上桌(合成层)。
//
// 四种特效的做法(全部复用现成 Metal 管线,一次性跑完即弃):
//   ▸ 毛玻璃:先把图缩小到 1/4(缩小本身就是天然的低通滤波),再跑
//     辉光同款的稠密高斯模糊 H+V —— 缩小图上模糊 σ=10 等效原图 σ≈40,
//     绘制时线性放大又追加一层柔化,正是 macOS 毛玻璃的路数。
//   ▸ 像素风:逐次减半到 ~160 块宽的粗网格,再用 nearest(最近邻)采样
//     放大回原尺寸 —— 出大色块;同时做色阶量化(每通道 6 档),像素游戏味。
//   ▸ 暗化 / 黑白:单趟调色 fragment(×0.35 / 灰度×0.55),暗一点是为了
//     文字浮在图上仍然可读(Terminal.app 没这挡,是 YeTerm 的贴心版)。
//
// 语法看点:
//   `@discardableResult` —— 允许调用方忽略返回值不警告(类比无 @CanIgnore
//     注解的 Java,Swift 默认"没用返回值"会黄字提醒)。
//   `defer` 没出现,但«键控缓存»模式值得学:cacheKey 记住"路径|模式",
//     没变就直接复用,设置页每次广播都调进来也不会重复解码图片。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import simd

/// 普通模式背景图片(v1.2 #16):加载 + 特效一次性预处理 + 成品纹理缓存。
/// 仅 CRT 总开关关闭(colorPassthrough)时被合成层消费;任何一步失败都
/// 静默降级(特效失败给原图,加载失败当没设背景)—— 不能因为一张坏图黑屏。
final class PlainBackground {
    /// 特效模式(与配置 plainBackgroundImageMode 的 Int 对应)
    enum Mode: Int {
        case none = 0        // 无变化
        case frosted = 1     // 毛玻璃模糊
        case pixel = 2       // 像素风转换
        case dimmed = 3      // 暗化(文字可读性优先)
        case monoFilm = 4    // 黑白胶片
    }

    private let ctx: MetalContext
    private let renderer: OffscreenRenderer
    /// 成品纹理(nil = 未设置背景图/加载失败)
    private(set) var texture: MTLTexture?
    private var cacheKey: String?

    // 与 Bloom.metal / EffectChain 的同名 struct 逐字节一致(模糊 pass 复用)
    private struct BlurUniforms {
        var direction: SIMD2<Float>
        var sigmaPx: Float
        var _pad: Float = 0
    }
    private struct PadUniforms {
        var pad: SIMD2<Float>
    }
    private struct GradeUniforms {
        var mode: Float
        var dim: Float = 0    // 暗化乘数(仅 mode=1 读;与 MSL PlainBGGradeUniforms 同步)
    }

    /// 暗化滑块 0~1 → 亮度乘数(2026-08-07 用户需求「暗化程度可调」):
    /// 0 = 原图(×1)/ 1 = 全黑(×0)。**0.5 档必须精确 = 0.35**(v1.2 起的固定
    /// 观感,auto-drive 有 ×0.35 像素直读断言)—— 所以用分段线性而非幂曲线,
    /// 两段在 0.5 处相接,避免浮点幂运算差出 1 LSB
    static func dimMultiplier(_ t: Double) -> Float {
        let s = min(max(t, 0), 1)
        return Float(s <= 0.5 ? 1.0 - 1.3 * s : 0.7 * (1.0 - s))
    }

    // 像素风调色板(v2,借鉴 pixelit 等开源像素画工具;色值均为社区公开标准):
    // 0 PICO-8(Lexaloffle 幻想主机 16 色,鲜艳)/ 1 DB16(DawnBringer,沉稳)/
    // 2 GameBoy(DMG 四阶绿)/ 3 原色(无调色板,均匀量化)
    static let pixelPalettes: [[UInt32]] = [
        [0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
         0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA],
        [0x140C1C, 0x442434, 0x30346D, 0x4E4A4E, 0x854C30, 0x346524, 0xD04648, 0x757161,
         0x597DCE, 0xD27D2C, 0x8595A1, 0x6DAA2C, 0xD2AA99, 0x6DC2CA, 0xDAD45E, 0xDEEED6],
        [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F],
    ]

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.renderer = OffscreenRenderer(ctx: ctx)
    }

    /// 键控更新:路径/模式/参数没变直接复用缓存(返回 false);变了重新加载+预处理。
    /// path=nil 即清除。设置广播每 50ms 就会打进来,这层挡板是必须的。
    /// `blur`:毛玻璃强度 0~1;`palette`:像素风调色板档;`darken`:暗化程度 0~1 ——
    /// 各自只在对应模式参与缓存键(其它模式动这些值不触发重算)
    @discardableResult
    func update(path: String?, mode: Int, blur: Double = 0.5, palette: Int = 0,
                darken: Double = 0.5) -> Bool {
        let m = Mode(rawValue: mode) ?? .none
        var suffix = ""
        if m == .frosted { suffix = String(format: "|%.3f", blur) }
        if m == .pixel { suffix = "|p\(palette)" }
        if m == .dimmed { suffix = String(format: "|d%.3f", darken) }
        let key = path.map { "\($0)|\(mode)\(suffix)" }
        guard key != cacheKey else { return false }
        cacheKey = key
        if let p = path {
            texture = process(path: p, mode: m, blur: blur, palette: palette, darken: darken)
        } else {
            texture = nil
        }
        return true
    }

    // MARK: - 加载 + 预处理

    private func process(path: String, mode: Mode, blur: Double, palette: Int,
                         darken: Double) -> MTLTexture? {
        guard let src = loadTexture(path: path) else {
            FileHandle.standardError.write(Data("背景图片加载失败: \(path)\n".utf8))
            return nil
        }
        do {
            switch mode {
            case .none:     return src
            case .frosted:  return try frosted(src, strength: blur)
            case .pixel:    return try pixelated(src, palette: palette)
            case .dimmed:   return try graded(src, mode: 1, dim: Self.dimMultiplier(darken))
            case .monoFilm: return try graded(src, mode: 2)
            }
        } catch {
            // 特效失败降级原图(有图总比黑底强)
            FileHandle.standardError.write(Data("背景特效预处理失败,使用原图: \(error)\n".utf8))
            return src
        }
    }

    /// 图片文件 → BGRA8 纹理(最长边压到 2048,守内存;非 _srgb,守全链色彩纪律)
    private func loadTexture(path: String) -> MTLTexture? {
        guard let nsImage = NSImage(contentsOfFile: path),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let cap = 2048
        let scale = min(1.0, Double(cap) / Double(max(cg.width, cg.height)))
        let w = max(Int(Double(cg.width) * scale), 1)
        let h = max(Int(Double(cg.height) * scale), 1)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let cgCtx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: info) else { return nil }
        cgCtx.interpolationQuality = .high
        cgCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: buf, bytesPerRow: w * 4)
        return tex
    }

    /// 减半一次(复用 Bloom 的 pad_downsample,pad=0 即纯线性降采样:
    /// 线性采样恰为 2×2 盒平均,兼做抗锯齿低通)
    private func halve(_ src: MTLTexture) throws -> MTLTexture {
        var u = PadUniforms(pad: .zero)
        return try withUnsafeBytes(of: &u) { p in
            try renderer.renderFullscreen(library: "Bloom", fragment: "pad_downsample_fragment",
                                          source: src, uniforms: p,
                                          outWidth: max(src.width / 2, 1),
                                          outHeight: max(src.height / 2, 1))
        }
    }

    /// 毛玻璃:降采样 → 稠密高斯 H+V。成品保持小尺寸 —— 绘制时线性放大
    /// 再柔化一层,还省显存。
    /// `strength` 0~1 → 等效原图模糊 σ 8~72px(0.5 = 40,即首版固定观感);
    /// 大强度靠**多降一级采样**而非加大 σ —— blur_fragment 的 taps 上限 24,
    /// σ 超过 ~10 核会被截断出伪影,"先缩小再小核模糊"才是正路(EffectChain 同款)
    private func frosted(_ src: MTLTexture, strength: Double) throws -> MTLTexture {
        let t01 = Float(min(max(strength, 0), 1))
        let sigmaFull = 8 + t01 * 64
        var t = try halve(src)
        var sigma = sigmaFull / 2
        var level = 1
        while sigma > 10 && level < 3 {
            t = try halve(t)
            sigma /= 2
            level += 1
        }
        var uh = BlurUniforms(direction: .init(1.0 / Float(t.width), 0), sigmaPx: sigma)
        t = try withUnsafeBytes(of: &uh) { p in
            try renderer.renderFullscreen(library: "Bloom", fragment: "blur_fragment",
                                          source: t, uniforms: p,
                                          outWidth: t.width, outHeight: t.height)
        }
        var uv = BlurUniforms(direction: .init(0, 1.0 / Float(t.height)), sigmaPx: sigma)
        return try withUnsafeBytes(of: &uv) { p in
            try renderer.renderFullscreen(library: "Bloom", fragment: "blur_fragment",
                                          source: t, uniforms: p,
                                          outWidth: t.width, outHeight: t.height)
        }
    }

    /// 像素风(v2):逐次减半到 ~160 块宽的粗网格 → nearest 放大回原尺寸,
    /// 每块 Bayer 有序抖动 + 复古调色板最近色映射(shader 侧)。
    /// uniforms 布局 = 16 条调色板 float4 + 1 条 meta(与 MSL 逐字节一致,17×16=272B):
    /// meta = (色数, 抖动幅度, 小图宽, 小图高);4 色调色板(GameBoy)色距大,
    /// 抖动幅度相应放大才有点阵过渡;原色档(无调色板)幅度最小
    private func pixelated(_ src: MTLTexture, palette: Int) throws -> MTLTexture {
        var t = src
        while t.width > 160 && t.height > 90 {
            t = try halve(t)
        }
        var blob = [SIMD4<Float>](repeating: .zero, count: 17)
        var count = 0
        if palette >= 0 && palette < Self.pixelPalettes.count {
            let colors = Self.pixelPalettes[palette]
            count = colors.count
            for (i, v) in colors.enumerated() {
                blob[i] = .init(Float((v >> 16) & 0xff) / 255.0,
                                Float((v >> 8) & 0xff) / 255.0,
                                Float(v & 0xff) / 255.0, 1)
            }
        }
        let spread: Float = count == 0 ? 0.06 : (count <= 4 ? 0.30 : 0.10)
        blob[16] = .init(Float(count), spread, Float(t.width), Float(t.height))
        return try blob.withUnsafeBytes { p in
            try renderer.renderFullscreen(library: "Passthrough",
                                          fragment: "plain_bg_pixelate_fragment",
                                          source: t, uniforms: p,
                                          outWidth: src.width, outHeight: src.height)
        }
    }

    /// 暗化(mode=1,乘数滑块驱动)/ 黑白胶片(mode=2,固定灰度×0.55):单趟调色
    private func graded(_ src: MTLTexture, mode: Float, dim: Float = 0) throws -> MTLTexture {
        var u = GradeUniforms(mode: mode, dim: dim)
        return try withUnsafeBytes(of: &u) { p in
            try renderer.renderFullscreen(library: "Passthrough",
                                          fragment: "plain_bg_grade_fragment",
                                          source: src, uniforms: p,
                                          outWidth: src.width, outHeight: src.height)
        }
    }
}
