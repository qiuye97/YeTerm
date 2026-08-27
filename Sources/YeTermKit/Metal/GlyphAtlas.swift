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
        /// 彩色字形(emoji,2026-08-27 issue #1):图集里存的是彩色位图而非
        /// 白色蒙版,shader 端要原色直出、不能拿 alpha 乘前景色(那样只剩剪影)
        let isColor: Bool
    }

    private struct Key: Hashable {
        let text: String
        let wide: Bool
        let variant: UInt8       // bit0 bold, bit1 italic
    }

    /// 图集纹理。**按需增长**(2026-08-07 内存优化)故为 var:扩容时整张换新,
    /// 旧纹理随 ARC 释放(在途命令缓冲会自动保活到用完,不会被抽走)。
    private(set) var texture: MTLTexture
    private let device: MTLDevice
    private let cellPx: (w: Int, h: Int)
    private let fonts: [CTFont]              // [normal, bold, italic, boldItalic]
    private let fontMatrix: CGAffineTransform
    private let descentPx: CGFloat
    private let capHeightPx: CGFloat         // 大写字高(图标尺寸/对齐的锚)
    private var cache: [Key: Slot] = [:]

    /// 图集边长上限(2048² ×4B = 16MB —— v1.0~v1.5.2 的**固定**尺寸,现在是天花板)
    static let maxAtlasSize = 2048

    /// 当前图集边长(起始按字体 cell 推算,装满翻倍,封顶 maxAtlasSize)。
    /// 起因(2026-08-07 内存勘查):写死 2048 时实测使用率 **2%**
    /// (27 个字形 / 用掉 46 行像素,cell=22×46),16MB 里 15.7MB 是空的;
    /// 且**每个 ContentRenderer 各持一份**(每 pane + 标签栏 + OSD + 粘贴框 + 服务器选单)。
    private(set) var atlasSize: Int
    /// 扩容代数:每扩容一次 +1。uv 是按 atlasSize **归一化**的,扩容后全部旧 uv
    /// 失效 —— ContentRenderer 靠比对这个计数器决定要不要作废行缓存重建。
    private(set) var generation: UInt32 = 0

    private var cursorX = 0
    private var cursorY = 0
    /// 迁移期护栏:grow() 内部重新栅格化旧字形时不得再触发 grow(新图集是旧的
    /// 4 倍面积,旧内容必然装得下;这个标志只防御意料外的递归)
    private var isGrowing = false

    // 栅格化画布(窄/宽两种,复用)
    private var ctxNarrow: CGContext?
    private var ctxWide: CGContext?

    /// 起始边长:够装下「ASCII 全套 × 4 个字体变体」再留点余量即可,按 cell 尺寸
    /// 从 512 起逐级翻倍试。这样小字号只花 1MB、常规字号 4MB,大字号才退回 16MB ——
    /// 而不是一律先要 16MB。装满了照样能长(grow),所以这里估小了也只是多迁移一次。
    static func initialSize(cellPx: (w: Int, h: Int)) -> Int {
        let want = 95 * 4 + 40          // 可见 ASCII × 4 变体 + 余量
        var size = 512
        while size < maxAtlasSize {
            let cols = size / max(cellPx.w, 1), rows = size / max(cellPx.h, 1)
            if cols * rows >= want { break }
            size *= 2
        }
        return min(size, maxAtlasSize)
    }

    /// 建一张图集纹理(扩容时复用同一条描述,保证格式与 usage 逐字段一致)
    private static func makeAtlasTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: size, height: size,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        return device.makeTexture(descriptor: desc)
    }

    init?(device: MTLDevice, font: NSFont, cellPx: (w: Int, h: Int), scale: CGFloat) {
        self.device = device
        self.cellPx = cellPx

        let size = Self.initialSize(cellPx: cellPx)
        guard let tex = Self.makeAtlasTexture(device: device, size: size) else { return nil }
        atlasSize = size
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
    /// "选一行选中上面一行"勘差):行高 = 逻辑点级 ceil ×scale,与 SwiftTerm 同式;
    /// 列宽 = **round(advance×scale)**,fork 补丁三(2abc31e)起 SwiftTerm 侧
    /// 也是同一公式(CT 查 'W' 字形 + round 物理像素对齐)—— 此前它用
    /// glyph(withName:) + ceil,俩差异各自坑过一次:像素字体无字形名时格宽翻倍、
    /// 补偿后 advance×scale 的 +1ulp 浮点残差被 ceil 顶成整像素(每格漂 1px,
    /// 选区越拖越偏,2026-08-26 用户实测)。改这里必须连 fork 一起改。
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

    /// 图集使用率(VRAMProbe 诊断用,只读):已缓存字形数 / 已用到的行高 / 容量估算。
    /// 行式装箱是「从上往下逐行铺」,所以 cursorY+行高 就是真正用掉的高度。
    var probeUsage: (glyphs: Int, usedRows: Int, capacityRows: Int) {
        (cache.count, min(cursorY + cellPx.h, atlasSize), atlasSize)
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
            // 满了:先试**扩容**(翻倍 + 把已有字形迁到新图集),扩不动才清空重来。
            // 比 v1.5.2 前"一满就全清"更稳 —— 全清会让已在屏字形当帧集体失踪、
            // 随后逐个重栅格化(卡顿 + 闪烁);扩容则内容连续,只是 uv 整体换算。
            if !isGrowing, grow() {
                if cursorX + w > atlasSize {      // 新图集里重新装箱
                    cursorX = 0
                    cursorY += h
                }
            }
            if cursorY + h > atlasSize {
                // 已到 2048² 上限(或扩容失败):维持 v1.0 起的原行为
                FileHandle.standardError.write(Data("GlyphAtlas 已满,清空重建\n".utf8))
                cache.removeAll()
                cursorX = 0
                cursorY = 0
            }
        }

        guard let ctx = context(wide: wide) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        var isColor = false

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
            // 彩色字形判定(2026-08-27 issue #1「emoji 只渲染轮廓」):emoji 回退到
            // Apple Color Emoji(带 colorGlyphs trait 的位图字体),CTLineDraw 画进
            // 画布的是彩色位图 —— 下游按"白色蒙版 × 前景色"处理就只剩单色剪影
            isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)

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

            if isColor {
                // emoji(2026-08-27 issue #1「渲染不清晰/不完全」的另一半):位图字形
                // 没有轮廓路径,上面的 path bounds 量出来是空 → 走默认基线绘制,
                // 超出 cell 的部分被裁掉。改按**像素墨迹**量(CTLineGetImageBounds
                // 需要画布上下文),超格等比缩小、双轴居中 —— PUA 图标同款纪律;
                // 目标高 = 大写字高 ×1.25(emoji 视觉上比大写字母略高才与文字协调)
                ctx.textPosition = .zero
                var ink = CTLineGetImageBounds(line, ctx)
                if ink.isNull || ink.isInfinite || ink.width < 0.5 || ink.height < 0.5 {
                    ink = CGRect(x: 0, y: 0, width: availW, height: availH)
                }
                let targetH = min(availH, capHeightPx * 1.25)
                let fit = min(availW * 0.96 / ink.width, targetH / ink.height)
                let centerY = descentPx + capHeightPx / 2
                ctx.saveGState()
                ctx.translateBy(x: (availW - fit * ink.width) / 2 - fit * ink.minX,
                                y: centerY - fit * (ink.minY + ink.height / 2))
                ctx.scaleBy(x: fit, y: fit)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            } else if Self.isPUAIcon(text) {
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
                                      Float(h) / Float(atlasSize)),
                     isColor: isColor)
        cursorX += w
        return s
    }

    /// 扩容一级(边长翻倍,封顶 maxAtlasSize),并把已缓存字形**全部迁到新图集**。
    /// 迁移方式是照原样重新栅格化(而不是 GPU 拷贝):字形绘制是确定性的,重画
    /// 得到逐比特相同的位图,还省掉一次 blit 编码;代价是几百次 CoreText 绘制,
    /// 只在扩容那一刻付一次。
    ///
    /// 返回 false = 已到上限,调用方走"清空重来"的老路。
    /// ⚠️ 迁移期间 `isGrowing` 置位,rasterize 不得再触发 grow(防递归)。
    private func grow() -> Bool {
        guard atlasSize < Self.maxAtlasSize else { return false }
        let newSize = min(atlasSize * 2, Self.maxAtlasSize)
        guard let newTex = Self.makeAtlasTexture(device: device, size: newSize) else { return false }

        let old = cache
        texture = newTex          // 旧纹理在此失去最后一个强引用 → ARC 回收
        atlasSize = newSize
        generation &+= 1          // uv 全体作废的信号(ContentRenderer 据此重建行缓存)
        cache.removeAll()
        cursorX = 0
        cursorY = 0

        isGrowing = true
        defer { isGrowing = false }
        for key in old.keys {
            if let s = rasterize(text: key.text, wide: key.wide, variant: key.variant) {
                cache[key] = s
            }
        }
        if ProcessInfo.processInfo.environment["YETERM_DEBUG_GLYPH"] != nil {
            FileHandle.standardError.write(Data(
                "[glyph] 图集扩容 \(atlasSize / 2)² → \(atlasSize)²(迁移 \(old.count) 个字形, gen=\(generation))\n".utf8))
        }
        return true
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
