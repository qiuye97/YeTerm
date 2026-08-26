// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 离屏截图工具:Claude 的"眼睛"(自测体系 1/5)
//
// 这个文件:不开窗口,在内存里造一个终端内核 → 喂测试文本 → 走完整渲染
//   管线 → 存成 PNG。Claude 每次改渲染代码,都用它出图自查,还能对两张图
//   逐像素比对(PixelCompare)做回归 —— 相当于前端的截图快照测试
//   (visual regression test),只是我们自己手搓了一套。
// 关键词「确定性」:固定 time、固定字体缩放、无窗口无时序 → 同样输入
//   永远输出字节相同的 PNG,这样 diff 才有意义。
// 语法看点:`public struct RenderDemoOptions` 一堆带默认值的属性 ——
//   Swift 版"参数对象"模式,调用方只改关心的字段。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm

/// 离屏截图 harness(自动验证主回路;CLI 契约自 M0 锁定):
///   YeTerm --render-demo <out.png> [--cols N] [--rows N] [--font NAME] [--font-size N]
///                        [--effects off|passthrough|crt|crt-noise] [--tint RRGGBB]
///                        [--raster 0-4] [--time T] [--compare-with ref.png] [--tolerance N]
///                        [--shader-dir DIR] [--vres-y N] [--debug-cursor] [--frames N(兼容,忽略)]
///                        [--power-on T(0~1 开机动画进度中间帧;缺省=稳态,v1.1)]
///
/// M1a-2 起**彻底无头**:headless Terminal 同步解析 fixture → ContentRenderer(字形图集)
/// → 可选特效 pass → PNG。无窗口、无视图、无时序泵 —— 输出天然确定。
public struct RenderDemoOptions {
    public var outPath: String
    public var cols = 80
    public var rows = 24
    public var fontName = "Menlo"
    public var fontSize: CGFloat = 14
    public var frames = 2               // 兼容旧契约,新路径忽略
    public var effects = "off"
    public var compareWith: String?
    public var tolerance = 0
    public var time: Double = 0
    public var shaderDir: String?
    public var tint: String?
    public var rasterMode: Int?         // 显式传入才覆盖 preset/config
    public var vresY: Double = 0
    public var debugCursor = false
    public var fixturePath: String?     // 外部 fixture(转义格式同内置;复现/调试用)
    public var configPath: String?      // crterm 兼容配置(观感参数)
    public var presetName: String?      // 内置预设名(优先于 configPath)
    public var preeditText: String?
    public var bootTime: Double?     // --boot-time T:开机自检定格帧(v1.2 #10)
    public var degauss: Double?      // --degauss A:消磁波纹包络定格(v1.2 #13)     // 模拟 IME 预编辑(拼音自绘的离屏验证)
    public var plainBGPath: String?  // --plain-bg PATH:背景图片(v1.2 #16;v1.5.1 起 CRT 模式同样支持)
    public var plainBGMode = 0       // --plain-bg-mode 0-4:无/毛玻璃/像素风/暗化/黑白
    public var plainBGBlur = 0.5     // --plain-bg-blur 0~1:毛玻璃模糊强度
    public var plainBGPalette = 0    // --plain-bg-palette 0-3:像素风调色板(PICO-8/DB16/GameBoy/原色)
    public var plainBGDarken = 0.5   // --plain-bg-darken 0~1:暗化程度(0.5=旧固定观感 ×0.35)
    public var plainBGChroma = false // --plain-bg-chroma:CRT 模式下把背景图荧光染色(v1.5.1)
    public var powerOn: Double?         // 开机动画进度定格(0~1;nil=稳态。v1.1 自测用)
    public var screenInset: Double?     // --screen-inset Y:屏幕垂直内缩(机壳最小带的离屏调试口,2026-08-07)
}

final class HarnessTermDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

public enum RenderDemo {
    public static func run(_ opt: RenderDemoOptions) -> Int32 {
        FontLibrary.registerBundledFonts()   // --font "Terminus (TTF)" 等复古字体离屏可用
        // 1) headless 内核 + fixture(同步解析,无时序)
        let delegate = HarnessTermDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: opt.cols, rows: opt.rows))
        guard let fixture = loadFixture(path: opt.fixturePath) else {
            err("fixture 载入失败")
            return 1
        }
        terminal.feed(text: fixture)

        // 2) 字形图集渲染内容纹理(scale 固定 2.0,基线与 Retina 一致)
        guard let mtl = MetalContext() else { return 2 }
        if let dir = opt.shaderDir { mtl.shaderDirOverride = URL(fileURLWithPath: dir, isDirectory: true) }
        // 配置提前解析:fontWidth 参与字体矩阵(观感参数在 crt 分支复用同一份)
        let demoCfg: CRTConfig? = opt.presetName.flatMap { Presets.byName($0) }
            ?? opt.configPath.flatMap { CRTConfig.load(path: $0) }
        // 普通终端模式的调色板覆盖(与 GUI applyCRTMode 同源;不设则内容纹理
        // 仍是 CRT 黑底 → 与余量区 plain bg 异色,harness 出图会撒谎)
        AnsiColor.plainOverride = demoCfg?.crtEffectsEnabled == false
            ? demoCfg?.plainPalette() : nil
        // CRT 模式 ANSI 覆盖同源(v1.2 预设大更新:经典配色预设带官方 16 色表)
        AnsiColor.crtOverride = demoCfg?.crtEffectsEnabled == false
            ? nil : demoCfg?.crtAnsiPalette()
        // CRT 模式「文字颜色」同源(2026-08-03 默认前景覆盖)。内置预设一律
        // nil = 纯白;经典 CRT 的锁定在 storedConfig/设置页,harness 直读
        // 配置不再判(--config 手喂什么就渲什么,复现/调试用得上)
        AnsiColor.crtFgOverride = demoCfg?.crtEffectsEnabled == false
            ? nil : demoCfg?.crtTextFg()
        let font = TermHost.resolveFont(name: opt.fontName, size: opt.fontSize,
                                        width: CGFloat(demoCfg?.fontWidth ?? 1))
        let content = ContentRenderer(ctx: mtl)
        var preedit: ContentRenderer.Preedit?
        if let t = opt.preeditText {
            let cur = terminal.getCursorLocation()
            preedit = .init(text: t, col: cur.x, row: cur.y)
        }
        let contentTex: MTLTexture
        var bootCellPx: (w: Int, h: Int)?
        if let bt = opt.bootTime {
            // 开机自检定格帧(v1.2 #10):模拟时间线推进到 bt 秒再出图
            let boot = BootScreen(ctx: mtl, cols: opt.cols, rows: opt.rows)
            var t = 0.0
            while t < bt {
                boot.tick(now: t)
                t += 0.05
            }
            boot.tick(now: bt)
            guard let tex = boot.render(font: font, scale: 2.0) else {
                err("自检屏渲染失败")
                return 1
            }
            contentTex = tex
            bootCellPx = boot.cellPx
        } else {
            // 背景图激活判定(v1.2 #16):有图 + 普通模式配置 → 内容纹理透明清屏
            let plainBGActive = opt.plainBGPath != nil && demoCfg?.crtEffectsEnabled == false
            guard let tex = content.render(terminal: terminal, font: font, scale: 2.0,
                                           preedit: preedit,
                                           transparentDefaultBg: plainBGActive) else {
                err("内容渲染失败")
                return 1
            }
            contentTex = tex
        }

        let renderer = OffscreenRenderer(ctx: mtl)
        let finalTex: MTLTexture
        switch opt.effects {
        case "off":
            finalTex = contentTex
        case "passthrough":
            do {
                finalTex = try renderer.renderFullscreen(library: "Passthrough",
                                                         fragment: "passthrough_fragment",
                                                         source: contentTex,
                                                         outWidth: contentTex.width, outHeight: contentTex.height)
            } catch {
                err("\(error)")
                return 2
            }
        case "crt", "crt-noise":
            guard let noise = CRTPass.loadNoiseTexture(device: mtl.device) else {
                err("噪点纹理装载失败")
                return 1
            }
            var u = CRTUniforms()
            demoCfg?.apply(to: &u)
            u.time = Float(opt.time)
            u.viewportSize = .init(Float(contentTex.width), Float(contentTex.height))
            u.rgbShift = u.rgbShift * 4.0 / Float(contentTex.width)
            let marginPx = (1.0 + u.contentOffset.x * 39.0) * 2.0
            u.contentOffset = .init(marginPx / Float(contentTex.width), marginPx / Float(contentTex.height))
            if opt.vresY > 0 {
                let vy = Float(opt.vresY)
                u.virtualResolution = .init(vy * Float(contentTex.width) / Float(contentTex.height), vy)
            } else {
                u.virtualResolution = CRTPass.virtualResolution(cols: opt.cols, rows: opt.rows,
                                                                cellPx: bootCellPx ?? content.cellPx)
            }
            u.rasterizationIntensity = CRTPass.rasterizationIntensity(drawableH: contentTex.height,
                                                                      vresY: u.virtualResolution.y)
            u.scaleNoiseSize = .init(Float(contentTex.width) * 0.75 / 512.0,
                                     Float(contentTex.height) * 0.75 / 512.0)
            if let r = opt.rasterMode { u.rasterMode = Int32(r) }
            else if opt.presetName == nil && opt.configPath == nil { u.rasterMode = 1 }  // 裸 crt 模式默认扫描线(旧契约)
            if let hex = opt.tint {
                guard let c = CRTPass.color(hex: hex) else { err("--tint 需要 RRGGBB"); return 64 }
                u.fontColor = c
                u.chromaColor = 0
            }
            if opt.effects == "crt-noise" { u.staticNoise = 0.15 }
            if let t = opt.powerOn { u.powerOnProgress = Float(t) }   // 开机动画中间帧定格
            if let a = opt.degauss { u.degauss = Float(a) }           // 消磁波纹定格
            if let si = opt.screenInset { u.screenInset = .init(0, Float(si)) }   // 机壳最小带调试

            // 普通模式背景图片(v1.2 #16):背景图铺底 + 内容(透明底)预乘混合
            // 合成一张,再进直通 CRT pass —— 与 GUI performCapture 同构。
            // margin 归零 = GUI 语义(留白融入合成画面,直通全幅可见)
            var crtSource = contentTex
            if let bgPath = opt.plainBGPath, u.colorPassthrough > 0.5 {
                u.contentOffset = .zero
                let pb = PlainBackground(ctx: mtl)
                pb.update(path: bgPath, mode: opt.plainBGMode, blur: opt.plainBGBlur,
                          palette: opt.plainBGPalette, darken: opt.plainBGDarken)
                if let bgTex = pb.texture {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm,
                        width: contentTex.width, height: contentTex.height, mipmapped: false)
                    desc.usage = [.renderTarget, .shaderRead]
                    if let comp = mtl.device.makeTexture(descriptor: desc),
                       let cmd = mtl.queue.makeCommandBuffer() {
                        let clear = MTLClearColor(red: Double(u.backgroundColor.x),
                                                  green: Double(u.backgroundColor.y),
                                                  blue: Double(u.backgroundColor.z), alpha: 1)
                        do {
                            try renderer.encodeComposite(
                                into: comp, commandBuffer: cmd,
                                draws: [(contentTex, MTLViewport(originX: 0, originY: 0,
                                                                 width: Double(contentTex.width),
                                                                 height: Double(contentTex.height),
                                                                 znear: 0, zfar: 1), nil)],
                                clearColor: clear, background: bgTex)
                        } catch {
                            err("\(error)")
                            return 2
                        }
                        cmd.commit()
                        cmd.waitUntilCompleted()
                        crtSource = comp
                    }
                } else {
                    err("--plain-bg 图片加载失败: \(bgPath)")
                    return 1
                }
            }

            // 背景图片(v1.5.1):**CRT 模式**走的是另一条路 —— 图不进内容纹理,
            // 而是绑到 CRT pass 的 texture(4) 当「屏幕底图」,由着色器替换染色公式
            // 里的背景色项(与 GUI 的 buildUniforms 同构,aspect-fill 公式也同一套)。
            // 有它才能用 --render-demo 对拍 CRT 模式的背景图观感。
            var crtBGImage: MTLTexture?
            if let bgPath = opt.plainBGPath, u.colorPassthrough <= 0.5 {
                let pb = PlainBackground(ctx: mtl)
                pb.update(path: bgPath, mode: opt.plainBGMode, blur: opt.plainBGBlur,
                          palette: opt.plainBGPalette, darken: opt.plainBGDarken)
                guard let tex = pb.texture else {
                    err("--plain-bg 图片加载失败: \(bgPath)")
                    return 1
                }
                crtBGImage = tex
                u.bgImageOn = 1
                if opt.plainBGChroma { u.bgImageChroma = 1 }   // 荧光染色档(配置里也可开)
                let targetAspect = Float(crtSource.width) / Float(max(crtSource.height, 1))
                let imgAspect = Float(tex.width) / Float(max(tex.height, 1))
                u.bgImageUVScale = .init(min(1, targetAspect / imgAspect),
                                         min(1, imgAspect / targetAspect))
            }
            if opt.debugCursor {
                let pos = terminal.getCursorLocation()
                let w = 1.0 / Float(opt.cols), h = 1.0 / Float(opt.rows)
                u.cursorRectUV = .init(Float(pos.x) * w, Float(pos.y) * h, w, h)
                u.cursorOn = 1
                // 取证口(2026-08-07 失焦光标):目检失焦形态/指定样式,不动 CLI 契约
                let env = ProcessInfo.processInfo.environment
                if env["YETERM_DEBUG_CURSOR_UNFOCUSED"] != nil { u.cursorOn = 2 }
                if let s = env["YETERM_DEBUG_CURSOR_STYLE"].flatMap(Float.init) {
                    u.cursorStyle = s
                }
            }
            // M1b 派生纹理(配置驱动;离屏单步,确定性保持)
            let chain = EffectChain(ctx: mtl)
            var extras: [MTLTexture] = [noise]
            if u.bloomAmount > 0 || (u.frameOn > 0.5 && u.frameShininess > 0),
               let bl = chain?.bloom(from: crtSource, radiusPx: 80, wait: true,
                                     style: u.bloomStyle > 0.5 ? 1 : 0,
                                     shape: u.bloomShape > 0.5 ? 1 : 0) {
                extras.append(bl)                        // 半径 40 逻辑 px × scale 2.0(与 GUI 同源)
                u.bloomPad = chain?.bloomPadUV ?? .zero
            } else if let black = chain?.blackTexture {
                extras.append(black)
            }
            if u.burnIn > 0, let chain,
               let bi = chain.accumulateBurnIn(content: crtSource, time: u.time,
                                               burnInTime: u.burnInTime, wait: true) {
                u.burnInLastUpdate = chain.burnInLastUpdate
                extras.append(bi)
            } else if let black = chain?.blackTexture {
                extras.append(black)
            }
            // texture(4) = 背景图(CRT 模式);无图时黑纹理占位维持索引对齐
            if let bgi = crtBGImage {
                extras.append(bgi)
            } else if let black = chain?.blackTexture {
                extras.append(black)
            }
            do {
                finalTex = try withUnsafeBytes(of: &u) { p in
                    try renderer.renderFullscreen(library: "CRT",
                                                  fragment: "crt_fragment",
                                                  source: crtSource,
                                                  uniforms: p,
                                                  extraTextures: extras,
                                                  outWidth: crtSource.width, outHeight: crtSource.height)
                }
            } catch {
                err("\(error)")
                return 2
            }
        default:
            err("未知 --effects: \(opt.effects)")
            return 64
        }

        // 3) 回读写 PNG
        guard let img = renderer.readback(finalTex) else {
            err("回读失败")
            return 1
        }
        do {
            try PNGWriter.write(img, to: opt.outPath)
        } catch {
            err("\(error)")
            return 1
        }
        print("render-demo: \(opt.outPath) (\(finalTex.width)x\(finalTex.height)px, \(opt.cols)x\(opt.rows), font=\(opt.fontName), effects=\(opt.effects))")

        // 显存对账(YETERM_DEBUG_VRAM=1):无头路径的泄漏哨兵。图集**按需增长**后
        // 每次扩容都会换掉整张纹理,旧的必须随 ARC 走干净 —— 若泄漏,这里的
        // 总分配会包含 512²+1024²+2048² 的累加(1+4+16MB),而不是只有末级那张。
        if VRAMProbe.enabled {
            FileHandle.standardError.write(Data(
                "[vram] render-demo 结束:Metal 总分配=\(VRAMProbe.mb(mtl.device.currentAllocatedSize))\n".utf8))
        }

        // 4) 逐像素比对
        if let ref = opt.compareWith {
            let rc = PixelCompare.compare(pngA: opt.outPath, pngB: ref, tolerance: opt.tolerance)
            if rc != 0 { return rc }
        }
        return 0
    }

    /// fixture 是「转义存储」的文本:\e → ESC;\n → \r\n(直接 feed 没有 PTY 行规回填 CR)
    private static func loadFixture(path: String?) -> String? {
        let url: URL
        if let p = path {
            url = URL(fileURLWithPath: p)
        } else if let u = Bundle.module.url(forResource: "demo_cjk", withExtension: "ansi", subdirectory: "Fixtures") {
            url = u
        } else {
            return nil
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return raw
            .replacingOccurrences(of: "\\e", with: "\u{1b}")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("render-demo: \(s)\n".utf8))
    }
}

/// PNG 逐像素比对(独立小工具)
enum PixelCompare {
    /// 返回 0=一致;3=尺寸不一/读图失败;4=超容差
    static func compare(pngA: String, pngB: String, tolerance: Int) -> Int32 {
        func load(_ p: String) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let a = load(pngA), let b = load(pngB) else {
            FileHandle.standardError.write(Data("compare: 读图失败\n".utf8))
            return 3
        }
        guard a.width == b.width, a.height == b.height else {
            FileHandle.standardError.write(Data("compare: 尺寸不一 \(a.width)x\(a.height) vs \(b.width)x\(b.height)\n".utf8))
            return 3
        }
        func rawBGRA(_ img: CGImage) -> [UInt8]? {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: info)) else { return nil }
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let ba = rawBGRA(a), let bb = rawBGRA(b) else { return 3 }
        var maxDiff = 0, diffCount = 0
        for i in 0..<ba.count {
            let d = abs(Int(ba[i]) - Int(bb[i]))
            if d > 0 { diffCount += 1; maxDiff = max(maxDiff, d) }
        }
        if maxDiff > tolerance {
            FileHandle.standardError.write(Data("compare: 超容差 maxDiff=\(maxDiff) 分量差异数=\(diffCount) tolerance=\(tolerance)\n".utf8))
            return 4
        }
        print("compare: 通过(maxDiff=\(maxDiff) tolerance=\(tolerance))")
        return 0
    }
}
