// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 字形图集:所有字符的"贴纸册"(阅读顺序第 9 站)
//
// 这个文件:游戏行业的经典技术 texture atlas(纹理图集)。每个字符第一次
//   出现时,用 CoreText(macOS 的字体排版引擎)画成"白色字形"存进一张
//   2048×2048 的大纹理;以后再遇到直接查缓存拿贴纸,GPU 采样时
//   「白色字形 × 前景色」就能染成任何颜色 —— 一份贴纸服务所有颜色。
// 类比 Web:CSS 雪碧图(sprite sheet)+ 图标字体的合体;cache 字典就是
//   HashMap<字符+样式, 贴纸坐标>。
//
// 这里还藏着三个用户可感知的功能:
//   ▸ 字体回退:主字体没有的字(中文/图标)自动找系统里有的字体补;
//   ▸ 盒绘字符不用字体、程序直接画(BoxDrawing.swift,断口根修);
//   ▸ PUA 图标(p10k 的 //🔒)量实际墨迹,缩放到和文字等高。
//
// 语法看点:
//   `struct Key: Hashable` —— 自定义字典键,编译器自动合成 hash/==
//     (Java 得手写 hashCode/equals 或用 record)。
//   `CGContext` 绘图 —— macOS 的 2D 画布(Quartz),类比 HTML Canvas 2D:
//     ctx.fill / ctx.translateBy / ctx.scaleBy 几乎一一对应;
//     注意它的 y 轴朝上(数学系),和屏幕坐标(y 朝下)相反,是常见坑。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import CoreText
import Metal
import simd

/// 字形图集(M1a-2):把「字符 × 字体变体 × 宽窄」栅格化成图集纹理里的白色字形块,
/// 渲染时用 alpha 作 mask 乘前景色 —— 图集与颜色解耦,一份字形服务所有颜色。
///
/// 关键设计(G3 的根基):
/// - 每个字符**独立**栅格化进自己的 cell 格,按精确列位摆放(勿用 advance 累计,#422 教训)
/// - 缺字走 CTFontCreateForString 回退链(CJK/powerline 字形都靠它)
/// - CJK 宽字符占 2×cellW 的格
final class GlyphAtlas {
    struct Slot {
        let uv: SIMD4<Float>     // atlas uv x,y,w,h
    }

    private struct Key: Hashable {
        let text: String
        let wide: Bool
        let variant: UInt8       // bit0 bold, bit1 italic
    }

    let texture: MTLTexture
    private let device: MTLDevice
    private let cellPx: (w: Int, h: Int)
    private let fonts: [CTFont]              // [normal, bold, italic, boldItalic]
    private let fontMatrix: CGAffineTransform
    private let descentPx: CGFloat
    private let capHeightPx: CGFloat         // 大写字高(图标尺寸/对齐的锚)
    private var cache: [Key: Slot] = [:]

    private let atlasSize = 2048
    private var cursorX = 0
    private var cursorY = 0

    // 栅格化画布(窄/宽两种,复用)
    private var ctxNarrow: CGContext?
    private var ctxWide: CGContext?

    init?(device: MTLDevice, font: NSFont, cellPx: (w: Int, h: Int), scale: CGFloat) {
        self.device = device
        self.cellPx = cellPx

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: atlasSize, height: atlasSize,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        texture = tex

        // 字体按像素栅格化:字号 × scale;矩阵(fontWidth 横向缩放)随字体携带,
        // 与 SwiftTerm 的列宽计算同源(TermHost.resolveFont 注)
        let px = font.pointSize * scale
        var matrix = CTFontGetMatrix(font as CTFont)
        fontMatrix = matrix
        let base = CTFontCreateWithName(font.fontName as CFString, px, &matrix)
        let mgr = NSFontManager.shared
        func variant(_ traits: NSFontTraitMask) -> CTFont {
            let converted = mgr.convert(font, toHaveTrait: traits)
            var m = matrix
            return CTFontCreateWithName(converted.fontName as CFString, px, &m)
        }
        fonts = [base, variant(.boldFontMask), variant(.italicFontMask),
                 variant([.boldFontMask, .italicFontMask])]
        descentPx = CTFontGetDescent(base) + CTFontGetLeading(base)
        capHeightPx = CTFontGetCapHeight(base)
    }

    /// 字体度量 → cell 像素尺寸。
    /// ⚠️ 必须与 SwiftTerm computeFontDimensions **逐点一致**(2026-07-29 用户实测
    /// "选一行选中上面一行"勘差):鼠标→行列换算在 SwiftTerm 侧用**逻辑点级
    /// ceil 行高 + 原始 advance 列宽**,此前我们用物理像素级 ceil(更紧凑),
    /// Menlo 每行差 0.5 逻辑 px、24 行末累积 0.7 行 —— 屏幕下半部分点击即选到
    /// 上一行。行高改逻辑级 ceil ×scale;列宽靠 TermHost.resolveFont 的矩阵
    /// 微补偿(advance 对齐半逻辑点),两侧共用同一字体对象天然一致。
    static func cellSize(font: NSFont, scale: CGFloat) -> (w: Int, h: Int) {
        let ct = font as CTFont          // 逻辑点度量(与 SwiftTerm 同源同字体)
        var glyph = CGGlyph(0)
        var ch: [UniChar] = [0x57]   // 'W'
        CTFontGetGlyphsForCharacters(ct, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        let hLogical = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
        return (max(Int(round(advance.width * scale)), 2),
                max(Int(round(hLogical * scale)), 2))
    }

    func slot(text: String, wide: Bool, bold: Bool, italic: Bool) -> Slot? {
        let variant = UInt8((bold ? 1 : 0) | (italic ? 2 : 0))
        let key = Key(text: text, wide: wide, variant: variant)
        if let s = cache[key] { return s }
        guard let s = rasterize(text: text, wide: wide, variant: variant) else { return nil }
        cache[key] = s
        return s
    }

    /// 字形安放方式(自测钩子:把"什么情况该缩、什么情况只平移"钉死)
    enum FitKind: String {
        case normal      = "原样"      // 装得下且位置正常 —— 绝大多数文字走这条
        case scaled      = "缩放"      // 墨迹比格子大 >5%:再摆也装不下
        case translated  = "平移"      // 装得下、只是画到格外:整像素挪回来
    }

    /// 给定字形的安放方式(与 rasterize 里的判据同源,探针据此断言策略不被改坏)
    func fitKind(text: String, wide: Bool = false, bold: Bool = false) -> FitKind {
        let availW = CGFloat(cellPx.w * (wide ? 2 : 1)), availH = CGFloat(cellPx.h)
        var font = fonts[bold ? 1 : 0]
        if !fontHasGlyphs(font, text: text) {
            let fb = CTFontCreateForString(font, text as CFString,
                                           CFRange(location: 0, length: text.utf16.count))
            var m = fontMatrix
            font = CTFontCreateCopyWithAttributes(fb, 0, &m, nil)
        }
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard !ink.isNull, !ink.isInfinite, ink.width > 0.5, ink.height > 0.5 else { return .normal }
        if ink.width > availW * 1.05 || ink.height > availH * 1.05 { return .scaled }
        if ink.minX < -1.5 || ink.maxX > availW + 1.5
            || descentPx + ink.minY < -1.5 || descentPx + ink.maxY > availH + 1.5 {
            return .translated
        }
        return .normal
    }

    /// YETERM_DEBUG_GLYPH=1:打印被特殊处理的字形(超格缩放/偏位平移),
    /// 2026-07-30「符号显示不全」定位就靠它量出 ⑴=1.63 倍宽、Zpix「—」起笔偏 6.9px
    private static func debugGlyph(_ text: String, _ w: CGFloat, _ h: CGFloat,
                                   _ ink: CGRect, kind: String) {
        guard ProcessInfo.processInfo.environment["YETERM_DEBUG_GLYPH"] != nil else { return }
        FileHandle.standardError.write(Data(String(
            format: "[glyph] %@ 「%@」 cell=%.0fx%.0f ink=%.1fx%.1f minX=%.1f 宽比=%.2f\n",
            kind as NSString, text as NSString, w, h,
            ink.width, ink.height, ink.minX, ink.width / w).utf8))
    }

    // MARK: - 栅格化

    private func rasterize(text: String, wide: Bool, variant: UInt8) -> Slot? {
        let w = cellPx.w * (wide ? 2 : 1)
        let h = cellPx.h

        // 图集行式装箱
        if cursorX + w > atlasSize {
            cursorX = 0
            cursorY += h
        }
        if cursorY + h > atlasSize {
            // 图集满:清空重来(极端场景;M1b 再做 LRU)
            FileHandle.standardError.write(Data("GlyphAtlas 已满,清空重建\n".utf8))
            cache.removeAll()
            cursorX = 0
            cursorY = 0
        }

        guard let ctx = context(wide: wide) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        // 盒绘/块元素(U+2500–259F):程序化画满整格,跨行跨列天然连续(断口修复)
        if !BoxDrawing.draw(text: text, in: ctx, w: w, h: h) {
            // 选字体:主字体缺字 → CTFontCreateForString 回退(CJK/符号);
            // 回退字体显式重挂矩阵(fontWidth 缩放对回退字形同样生效)
            var font = fonts[Int(variant)]
            if !fontHasGlyphs(font, text: text) {
                let fb = CTFontCreateForString(font, text as CFString, CFRange(location: 0, length: text.utf16.count))
                var m = fontMatrix
                font = CTFontCreateCopyWithAttributes(fb, 0, &m, nil)
            }

            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            // 墨迹实测尺寸(useGlyphPathBounds = 字形轮廓的真实包围盒,不含排版留白)
            let inkBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let availW = CGFloat(w), availH = CGFloat(h)
            let inkUsable = !inkBounds.isNull && !inkBounds.isInfinite
                && inkBounds.width > 0.5 && inkBounds.height > 0.5
            // 会不会画出格?(默认绘制点是 x=0、基线 y=descentPx)
            // 【学】CGRect 的 minX/maxX 是墨迹左右边界,可能是负数 —— 有些字形
            //      的轮廓会伸到起笔点左边(如 ⑴ 的左括号),那一侧同样会被裁掉。
            //
            // 分两类处理(2026-07-30 埋点实测的结论,别合并成一类):
            //   ▸ **尺寸真超格**(墨迹比格子大 >5%):再怎么摆都装不下 → 等比缩小。
            //     实测 ⑴ ① 是 1.63 倍、❸ ⒈ 是 1.17~1.19 倍。
            //   ▸ **只是位置偏出格**(墨迹装得下,只是画到格外去了)→ **平移**回来,
            //     绝不缩放:实测 Zpix 的「—」ink 13.7 宽却从 x=6.9 起笔(右边裁掉
            //     4.6px);点阵字体一缩放就毁掉像素对齐,平移量还要取整到整像素。
            //   ▸ 1.5px 以内的零碎溢出(下划线/逗号的抗锯齿边缘)一律不动 ——
            //     肉眼看不见,动了反而破坏点阵字体的逐像素锐利。
            let drawnMinY = descentPx + inkBounds.minY
            let drawnMaxY = descentPx + inkBounds.maxY
            let sizeOverflow = inkUsable
                && (inkBounds.width > availW * 1.05 || inkBounds.height > availH * 1.05)
            let posOverflow = inkUsable && !sizeOverflow
                && (inkBounds.minX < -1.5 || inkBounds.maxX > availW + 1.5
                    || drawnMinY < -1.5 || drawnMaxY > availH + 1.5)

            if Self.isPUAIcon(text) {
                // PUA 图标(nerd font/p10k 的 /🔒/⏰ 等):墨迹经常比 cell 宽(被裁出
                // 「遮挡」)或不居中 —— 量实际墨迹,超格则等比缩小,双轴居中(iTerm2 同款)
                let ink = inkBounds
                if inkUsable {
                    // 尺寸锚定**文字**而非格子(CJK 字体行高远大于字高,按格高限会失真):
                    // 目标高 = 大写字高 ×1.1,**双向缩放**(nerd font 图标自然墨迹常偏小,
                    // 只缩不放会比文字小 —— q8 时钟实测;矢量绘制,放大不糊),宽度受 cell 限
                    let availW = CGFloat(w)
                    let targetH = capHeightPx * 1.1
                    let fit = min(availW * 0.96 / ink.width, targetH / ink.height)
                    let centerY = descentPx + capHeightPx / 2
                    ctx.saveGState()
                    ctx.translateBy(x: (availW - fit * ink.width) / 2 - fit * ink.minX,
                                    y: centerY - fit * (ink.minY + ink.height / 2))
                    ctx.scaleBy(x: fit, y: fit)
                    ctx.textPosition = .zero
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                } else {
                    ctx.textPosition = CGPoint(x: 0, y: descentPx)
                    CTLineDraw(line, ctx)
                }
            } else if sizeOverflow {
                Self.debugGlyph(text, availW, availH, inkBounds, kind: "缩放")
                // 装不下:等比缩进格内并居中(用户实测 q2.png:✳ ❸ ① ⑴ ◯ Ⓥ 这类
                // 符号 —— 终端按 East Asian 宽度表判它们占 1 格,字体里的字形实际
                // 比一格宽,默认绘制被裁掉半个,看起来像"显示不全 + 互相压")。
                // **只缩不放**;水平居中,垂直对齐大写字高中轴。iTerm2/WezTerm 同款。
                let fit = min(1.0, min(availW * 0.98 / inkBounds.width,
                                       availH * 0.98 / inkBounds.height))
                let centerY = descentPx + capHeightPx / 2
                ctx.saveGState()
                ctx.translateBy(x: (availW - fit * inkBounds.width) / 2 - fit * inkBounds.minX,
                                y: centerY - fit * (inkBounds.minY + inkBounds.height / 2))
                ctx.scaleBy(x: fit, y: fit)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            } else if posOverflow {
                Self.debugGlyph(text, availW, availH, inkBounds, kind: "平移")
                // 装得下、只是位置偏出去:最小平移量挪回格内(取整到整像素,
                // 保住点阵字体的逐像素锐利);不缩放 → 字形形状分毫不变
                var dx: CGFloat = 0, dy: CGFloat = 0
                if inkBounds.minX < 0 { dx = -inkBounds.minX }
                else if inkBounds.maxX > availW { dx = availW - inkBounds.maxX }
                if drawnMinY < 0 { dy = -drawnMinY }
                else if drawnMaxY > availH { dy = availH - drawnMaxY }
                ctx.textPosition = CGPoint(x: dx.rounded(), y: descentPx + dy.rounded())
                CTLineDraw(line, ctx)
            } else {
                ctx.textPosition = CGPoint(x: 0, y: descentPx)   // 基线 = 底部 + descent
                CTLineDraw(line, ctx)
            }
        }

        guard let data = ctx.data else { return nil }
        // 写入图集
        texture.replace(region: MTLRegionMake2D(cursorX, cursorY, w, h),
                        mipmapLevel: 0,
                        withBytes: data,
                        bytesPerRow: ctx.bytesPerRow)

        let s = Slot(uv: SIMD4<Float>(Float(cursorX) / Float(atlasSize),
                                      Float(cursorY) / Float(atlasSize),
                                      Float(w) / Float(atlasSize),
                                      Float(h) / Float(atlasSize)))
        cursorX += w
        return s
    }

    /// 私有使用区 = 图标字体的地盘(powerline E0B0–E0BF 已由 BoxDrawing 程序化,不到这里)
    private static func isPUAIcon(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let v = text.unicodeScalars.first?.value else { return false }
        switch v {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            return true
        default:
            return false
        }
    }

    private func fontHasGlyphs(_ font: CTFont, text: String) -> Bool {
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
    }

    private func context(wide: Bool) -> CGContext? {
        if wide, let c = ctxWide { return c }
        if !wide, let c = ctxNarrow { return c }
        let w = cellPx.w * (wide ? 2 : 1)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let c = CGContext(data: nil, width: w, height: cellPx.h,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: info)
        if wide { ctxWide = c } else { ctxNarrow = c }
        return c
    }
}
