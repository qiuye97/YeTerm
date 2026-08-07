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
import AVFoundation
import CoreVideo
import Metal
import simd

/// 普通模式背景图片(v1.2 #16):加载 + 特效一次性预处理 + 成品纹理缓存。
/// 仅 CRT 总开关关闭(colorPassthrough)时被合成层消费;任何一步失败都
/// 静默降级(特效失败给原图,加载失败当没设背景)—— 不能因为一张坏图黑屏。
///
/// **v1.5.2 起支持动图/视频背景**(2026-08-07 用户需求),架构不变的关键选型:
/// 播放器只当「供帧机」—— 不往窗口里垫真的播放器图层(AVPlayerLayer 那种),
/// 因为 CRT 模式的背景图要进 shader 吃弧度/扫描线/机壳裁切,独立图层参与不了;
/// 这里每帧把视频/GIF 的当前帧变成纹理、过同一套特效、喂进现有上屏路径。
/// 【学】视频走系统 AVFoundation(专用硬件解码,不占 CPU/GPU;类比浏览器里
/// <video> 标签背后的那套),GIF 走 ImageIO 预解码 —— 都是系统框架,零三方依赖。
/// 帧率挡位(animFPS)限的是**取帧上屏**的节奏,越低越省电;声音恒静音。
final class PlainBackground {
    /// 特效模式(与配置 plainBackgroundImageMode 的 Int 对应)
    enum Mode: Int {
        case none = 0        // 无变化
        case frosted = 1     // 毛玻璃模糊
        case pixel = 2       // 像素风转换
        case dimmed = 3      // 暗化(文字可读性优先)
        case monoFilm = 4    // 黑白胶片
    }

    /// 背景源类别(按扩展名判定)
    enum SourceKind {
        case still, gif, video
        static func of(_ path: String) -> SourceKind {
            switch (path as NSString).pathExtension.lowercased() {
            case "gif": return .gif
            case "mp4", "mov", "m4v": return .video
            default: return .still
            }
        }
    }

    private let ctx: MetalContext
    private let renderer: OffscreenRenderer
    /// 成品纹理(nil = 未设置背景图/加载失败)
    private(set) var texture: MTLTexture?
    private var cacheKey: String?

    // 特效参数留档(动画源每帧重加工用;静图只在 update 时用一次)
    private var effMode: Mode = .none
    private var effBlur = 0.5
    private var effPalette = 0
    private var effDarken = 0.5
    /// 取帧上屏的帧率上限(挡位 15/30/60;只动"上屏"节奏,硬解照自己的来)
    private var animFPS: Double = 30
    private var lastFrameAt: CFTimeInterval = 0
    private var pausedByHost = false

    // ---- GIF(ImageIO 预算内预解码:全帧 BGRA 字节 + 累计时间轴)----
    private var gifFrames: [[UInt8]] = []
    private var gifW = 0, gifH = 0
    private var gifCum: [Double] = []          // 第 i 帧的**结束**时刻(秒)
    private var gifDuration: Double = 0
    private var gifStart: CFTimeInterval = -1
    private var gifPauseElapsed: Double = -1
    private var gifIndex = -1
    /// 上传目标乒乓双缓冲:GPU 可能还在读上一帧(在途 ≤2 帧),不能原地覆写
    private var gifUpload: [MTLTexture] = []
    private var gifFlip = 0

    // ---- 视频(AVPlayer 静音循环 + VideoOutput 拉帧 + CVMetalTexture 零拷贝)----
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var loopObserver: NSObjectProtocol?
    private var cvCache: CVMetalTextureCache?
    private var cvHold: CVMetalTexture?        // 保活当前帧包装(GPU 在读)
    private var cvHoldPrev: CVMetalTexture?    // 连上一帧一起保活(在途 ≤2 帧)

    /// 是否动画源(renderTick 据此决定要不要每帧来问)
    var isAnimated: Bool { player != nil || gifFrames.count > 1 }

    /// 显存账本条目(VRAMProbe 诊断用,只读;不参与渲染)。
    /// GIF 的 `gifFrames` 是 CPU 侧字节不在此列 —— 单独报个尺寸提示。
    var probeTextures: [(String, MTLTexture?)] {
        var out: [(String, MTLTexture?)] = [("plainBG.成品", texture)]
        for t in gifUpload { out.append(("plainBG.gif上传", t)) }
        if let cv = cvHold, let t = CVMetalTextureGetTexture(cv) { out.append(("plainBG.视频帧", t)) }
        if let cv = cvHoldPrev, let t = CVMetalTextureGetTexture(cv) { out.append(("plainBG.视频帧", t)) }
        return out
    }

    /// GIF 预解码占的 **CPU** 内存(帧字节;显存账本的补充说明)
    var probeGIFBytes: Int { gifFrames.reduce(0) { $0 + $1.count } }

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
    /// 各自只在对应模式参与缓存键(其它模式动这些值不触发重算)。
    /// `animFPS`:动画源取帧上限(静图不参与缓存键)
    @discardableResult
    func update(path: String?, mode: Int, blur: Double = 0.5, palette: Int = 0,
                darken: Double = 0.5, animFPS: Int = 30) -> Bool {
        let m = Mode(rawValue: mode) ?? .none
        var suffix = ""
        if m == .frosted { suffix = String(format: "|%.3f", blur) }
        if m == .pixel { suffix = "|p\(palette)" }
        if m == .dimmed { suffix = String(format: "|d%.3f", darken) }
        if let p = path, SourceKind.of(p) != .still { suffix += "|a\(animFPS)" }
        let key = path.map { "\($0)|\(mode)\(suffix)" }
        guard key != cacheKey else { return false }
        cacheKey = key
        effMode = m; effBlur = blur; effPalette = palette; effDarken = darken
        self.animFPS = Double(max(animFPS, 1))
        teardownAnimated()
        guard let p = path else { texture = nil; return true }
        switch SourceKind.of(p) {
        case .still:
            if let src = loadTexture(path: p) {
                texture = applyEffect(src)
            } else {
                FileHandle.standardError.write(Data("背景图片加载失败: \(p)\n".utf8))
                texture = nil
            }
        case .gif:
            setupGIF(path: p)
        case .video:
            setupVideo(path: p)
        }
        return true
    }

    // MARK: - 动画推进(renderTick 每帧来问;返回 true = 出了新帧,该重绘)

    private var dbgLastLog: CFTimeInterval = 0

    func tick(now: CFTimeInterval) -> Bool {
        // 取证口(2026-08-07 动态背景排查):每秒吐一次内部状态
        if ProcessInfo.processInfo.environment["YETERM_DEBUG_ANIMBG"] != nil, now - dbgLastLog > 1 {
            dbgLastLog = now
            FileHandle.standardError.write(Data(
                "[animbg] paused=\(pausedByHost) gif=\(gifFrames.count) idx=\(gifIndex) start=\(gifStart) player=\(player != nil) fps=\(animFPS) sinceLast=\(String(format: "%.3f", now - lastFrameAt))\n".utf8))
        }
        guard isAnimated, !pausedByHost else { return false }
        guard now - lastFrameAt >= 1.0 / animFPS else { return false }

        if !gifCum.isEmpty {
            if gifStart < 0 { gifStart = now }
            let t = (now - gifStart).truncatingRemainder(dividingBy: max(gifDuration, 0.001))
            let idx = gifCum.firstIndex(where: { t < $0 }) ?? 0
            guard idx != gifIndex else { return false }
            gifIndex = idx
            uploadGIFFrame(idx)
            lastFrameAt = now
            return true
        }
        if let out = videoOutput, let cache = cvCache {
            let it = out.itemTime(forHostTime: now)
            guard out.hasNewPixelBuffer(forItemTime: it),
                  let pb = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil) else {
                return false
            }
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                      .bgra8Unorm,
                                                      CVPixelBufferGetWidth(pb),
                                                      CVPixelBufferGetHeight(pb), 0, &cvTex)
            guard let cvt = cvTex, let frame = CVMetalTextureGetTexture(cvt) else { return false }
            cvHoldPrev = cvHold      // 上一帧可能还被在途命令读着,连保两帧
            cvHold = cvt
            texture = applyEffect(frame)
            lastFrameAt = now
            return true
        }
        return false
    }

    /// 宿主暂停/续播(窗口被遮挡/app 停摆时省硬解;GIF 记住相位不跳帧)
    func setPaused(_ p: Bool) {
        guard p != pausedByHost else { return }
        pausedByHost = p
        if p {
            player?.pause()
            if gifStart >= 0 { gifPauseElapsed = CACurrentMediaTime() - gifStart }
        } else {
            player?.play()
            if gifPauseElapsed >= 0 {
                gifStart = CACurrentMediaTime() - gifPauseElapsed
                gifPauseElapsed = -1
            }
        }
    }

    private func teardownAnimated() {
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        loopObserver = nil
        player?.pause()
        player = nil
        videoOutput = nil
        cvHold = nil
        cvHoldPrev = nil
        gifFrames = []; gifCum = []; gifUpload = []
        gifStart = -1; gifIndex = -1; gifPauseElapsed = -1
        gifDuration = 0; gifW = 0; gifH = 0
        lastFrameAt = 0
    }

    deinit {
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - 加载 + 预处理

    /// 特效加工(静图一次性/动画逐帧共用同一套;失败降级原帧)
    private func applyEffect(_ src: MTLTexture) -> MTLTexture {
        do {
            switch effMode {
            case .none:     return src
            case .frosted:  return try frosted(src, strength: effBlur)
            case .pixel:    return try pixelated(src, palette: effPalette)
            case .dimmed:   return try graded(src, mode: 1, dim: Self.dimMultiplier(effDarken))
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

    /// CGImage → BGRA 字节(sRGB 直读,与 loadTexture 同一条色彩纪律)
    private func bgraBytes(from cg: CGImage, w: Int, h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        if let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: info) {
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    // MARK: - GIF(ImageIO 预算内预解码)

    /// 全帧预解码成 BGRA 字节 + 累计时间轴。选「预解码」不选「边播边解」:
    /// ImageIO 逐帧 CPU 解码 1080p 要好几毫秒,30fps 播放就是持续的 CPU 负担;
    /// 预算内(≤128MB)一次付清换每帧近零成本。超预算先缩边(floor 320)再隔帧
    /// 抽样(被抽掉的帧时延并入前帧,节奏不变、只是粗一点)。
    /// 【学】ImageIO 的 GIF 帧是**已合成的整幅画面**(disposal 等脏活它内部干完),
    /// 不用自己叠增量帧。
    private func setupGIF(path: String) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else {
            FileHandle.standardError.write(Data("背景动图加载失败: \(path)\n".utf8))
            texture = nil
            return
        }
        let count = CGImageSourceGetCount(src)
        let p0 = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w0 = (p0?[kCGImagePropertyPixelWidth] as? Int) ?? 512
        let h0 = (p0?[kCGImagePropertyPixelHeight] as? Int) ?? 512
        let budget = 128 << 20
        var maxSide = min(1024, max(w0, h0))
        func totalBytes(_ side: Int, every stride: Int) -> Int {
            let s = Double(side) / Double(max(w0, h0, 1))
            let w = max(Int(Double(w0) * s), 1), h = max(Int(Double(h0) * s), 1)
            return w * h * 4 * ((count + stride - 1) / stride)
        }
        while totalBytes(maxSide, every: 1) > budget && maxSide > 320 { maxSide = maxSide * 3 / 4 }
        var stride = 1
        while totalBytes(maxSide, every: stride) > budget { stride += 1 }

        var frames: [[UInt8]] = []
        var cum: [Double] = []
        var total = 0.0
        var w = 0, h = 0
        var i = 0
        while i < count {
            var delay = 0.0
            for j in i..<min(i + stride, count) {
                let fp = CGImageSourceCopyPropertiesAtIndex(src, j, nil) as? [CFString: Any]
                let g = fp?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let d = (g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                delay += max(d, 0.02)
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                if w == 0 { w = cg.width; h = cg.height }
                frames.append(bgraBytes(from: cg, w: w, h: h))
                total += delay
                cum.append(total)
            }
            i += stride
        }
        guard !frames.isEmpty, w > 0 else { texture = nil; return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        gifUpload = (0..<2).compactMap { _ in ctx.device.makeTexture(descriptor: desc) }
        guard gifUpload.count == 2 else { texture = nil; return }
        gifFrames = frames; gifCum = cum; gifDuration = total; gifW = w; gifH = h
        gifIndex = 0
        uploadGIFFrame(0)
    }

    private func uploadGIFFrame(_ idx: Int) {
        guard idx < gifFrames.count, gifUpload.count == 2 else { return }
        gifFlip = 1 - gifFlip                  // 乒乓:GPU 还在读的那张不动
        let tex = gifUpload[gifFlip]
        gifFrames[idx].withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, gifW, gifH), mipmapLevel: 0,
                        withBytes: p.baseAddress!, bytesPerRow: gifW * 4)
        }
        texture = applyEffect(tex)
    }

    // MARK: - 视频(AVFoundation 硬解;恒静音循环)

    private func setupVideo(path: String) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        let pl = AVPlayer(playerItem: item)
        pl.isMuted = true                      // 壁纸恒静音(不抢音频焦点)
        pl.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak pl] _ in
            pl?.seek(to: .zero)                // 循环(seek 级,壁纸场景够平滑)
            pl?.play()
        }
        if cvCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, ctx.device, nil, &cache)
            cvCache = cache
        }
        player = pl
        videoOutput = out
        // 首帧同步取一张:设置页选完立即可见;探针/render-demo 不播也有确定性画面
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2048, height: 2048)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            let w = cg.width, h = cg.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead]
            if let tex = ctx.device.makeTexture(descriptor: desc) {
                bgraBytes(from: cg, w: w, h: h).withUnsafeBytes { p in
                    tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                withBytes: p.baseAddress!, bytesPerRow: w * 4)
                }
                texture = applyEffect(tex)
            }
        } else {
            FileHandle.standardError.write(Data("背景视频首帧解码失败: \(path)\n".utf8))
            texture = nil
        }
        if !pausedByHost { pl.play() }
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
