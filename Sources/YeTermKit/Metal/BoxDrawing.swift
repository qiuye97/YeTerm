// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 不用字体、程序画出来的字符
//
// 这个文件:表格线(─│┌┼═║…)、方块(▀▄█░▒▓)、powerline 箭头()这些
//   "图形类字符"不查字体,直接用 CGContext 按格子的精确尺寸画。
//   为什么?字体里的 │ 字形高度往往不等于行高,上下行之间必然留缝
//   (tmux 表格断线的元凶);程序画则天然满格、跨行无缝。iTerm2/kitty 同款方案。
// 最烧脑的是双线字符(╔╬╣)的交汇:用"三阶段"法 —— 先把双线臂画成粗实条,
//   再抠掉中缝,最后画单线臂;抠缝的止点规则决定了拐角/T 形是否是标准形
//   (注释里逐条推导过)。读懂 drawArms 你就读懂了全文件。
//
// 语法看点:
//   巨型 `switch cp { case 0x2500: ... }` 打表 —— Unicode 码点(UInt32)
//     直接当整数比;`case 0x2504...0x250B:` 是区间匹配(Java 21 才有类似的)。
//   嵌套函数 `func fillArm(...)` 定义在函数体内,能捕获外层局部变量,
//     类比 Java 的局部 lambda,但可读性更像"私有小节"。
// ─────────────────────────────────────────────────────────────────────────────
import CoreGraphics
import Foundation

/// 程序化盒绘字符(U+2500–U+259F):不用字体字形,直接按 cell 精确尺寸画满整格。
/// 修复「竖线断口」的根本手段(iTerm2/kitty 同款思路):字体里的 │ 字形高度
/// 往往 ≠ cell 高度,行间必然留缝;程序化画则天然跨行连续、跨列对齐。
///
/// 画布坐标注意:CGBitmapContext 原点在左下(CG +y = 屏幕上方),
/// 内存首行 = 屏幕顶行,与 GlyphAtlas 文字路径一致。
enum BoxDrawing {
    private enum Line { case none, light, heavy, double }
    private struct Arms {
        var up: Line, down: Line, left: Line, right: Line
        init(_ u: Line, _ d: Line, _ l: Line, _ r: Line) { up = u; down = d; left = l; right = r }
    }

    /// 入口:能画返回 true(已画进 ctx),不覆盖返回 false(走字体字形)
    static func draw(text: String, in ctx: CGContext, w: Int, h: Int) -> Bool {
        guard text.unicodeScalars.count == 1, let cp = text.unicodeScalars.first?.value,
              (0x2500...0x259F).contains(cp) || (0xE0B0...0xE0BF).contains(cp) else { return false }
        let W = CGFloat(w), H = CGFloat(h)
        let t = max(1, (H / 14).rounded())          // 细线粗细(随 cell 高缩放,整像素)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))

        switch cp {
        case 0x2504...0x250B, 0x254C...0x254F:      // 虚线族
            drawDashes(cp: cp, ctx: ctx, W: W, H: H, t: t)
        case 0x256D...0x2570:                        // 圆角弧
            drawArc(cp: cp, ctx: ctx, W: W, H: H, t: t)
        case 0x2571...0x2573:                        // 对角线
            drawDiagonal(cp: cp, ctx: ctx, W: W, H: H, t: t)
        case 0x2580...0x259F:                        // 块元素/浓淡
            drawBlock(cp: cp, ctx: ctx, W: W, H: H)
        case 0xE0B0...0xE0BF:                        // powerline 分隔符(p10k 等)
            drawPowerline(cp: cp, ctx: ctx, W: W, H: H, t: t)
        default:
            drawArms(arms(cp), ctx: ctx, W: W, H: H, t: t)
        }
        return true
    }

    // MARK: - Powerline 分隔符(U+E0B0–E0BF,程序化画满整格:
    // 字体字形高度/宽度与 cell 不齐会在 p10k 段间留缝或被裁 —— 与盒绘同一根因同一修法)

    private static func drawPowerline(cp: UInt32, ctx: CGContext, W: CGFloat, H: CGFloat, t: CGFloat) {
        // CG 坐标:+y = 屏幕上方
        func fillTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            ctx.beginPath()
            ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c)
            ctx.closePath(); ctx.fillPath()
        }
        func stroke(_ pts: [CGPoint]) {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(t)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
            ctx.beginPath()
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
        // 半椭圆(rx=W, ry=H/2):bulgeRight=true 从左缘鼓向右
        func halfEllipse(bulgeRight: Bool, fill: Bool) {
            ctx.saveGState()
            ctx.translateBy(x: bulgeRight ? 0 : W, y: H / 2)
            ctx.scaleBy(x: (bulgeRight ? W : -W), y: H / 2)
            ctx.beginPath()
            ctx.addArc(center: .zero, radius: 1,
                       startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            if fill {
                ctx.closePath()
                ctx.restoreGState()
                ctx.fillPath()
            } else {
                ctx.restoreGState()
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.setLineWidth(t)
                ctx.strokePath()
            }
        }
        switch cp {
        case 0xE0B0: fillTriangle(.init(x: 0, y: H), .init(x: W, y: H / 2), .init(x: 0, y: 0))       //
        case 0xE0B1: stroke([.init(x: 0, y: H), .init(x: W, y: H / 2), .init(x: 0, y: 0)])           //
        case 0xE0B2: fillTriangle(.init(x: W, y: H), .init(x: 0, y: H / 2), .init(x: W, y: 0))       //
        case 0xE0B3: stroke([.init(x: W, y: H), .init(x: 0, y: H / 2), .init(x: W, y: 0)])           //
        case 0xE0B4: halfEllipse(bulgeRight: true, fill: true)                                        //
        case 0xE0B5: halfEllipse(bulgeRight: true, fill: false)
        case 0xE0B6: halfEllipse(bulgeRight: false, fill: true)                                       //
        case 0xE0B7: halfEllipse(bulgeRight: false, fill: false)
        case 0xE0B8: fillTriangle(.init(x: 0, y: H), .init(x: 0, y: 0), .init(x: W, y: 0))           // ◣ 下左
        case 0xE0B9: stroke([.init(x: 0, y: H), .init(x: W, y: 0)])                                   // ╲
        case 0xE0BA: fillTriangle(.init(x: W, y: H), .init(x: W, y: 0), .init(x: 0, y: 0))           // ◢ 下右
        case 0xE0BB: stroke([.init(x: 0, y: 0), .init(x: W, y: H)])                                   // ╱
        case 0xE0BC: fillTriangle(.init(x: 0, y: 0), .init(x: 0, y: H), .init(x: W, y: H))           // ◤ 上左
        case 0xE0BD: stroke([.init(x: 0, y: 0), .init(x: W, y: H)])                                   // ╱
        case 0xE0BE: fillTriangle(.init(x: W, y: 0), .init(x: W, y: H), .init(x: 0, y: H))           // ◥ 上右
        default:     stroke([.init(x: 0, y: H), .init(x: W, y: 0)])                                   // E0BF ╲
        }
    }

    // MARK: - 线臂绘制(单/粗/双线 + 正确的交汇处理)

    private static func drawArms(_ a: Arms, ctx: CGContext, W: CGFloat, H: CGFloat, t: CGFloat) {
        let cx = (W / 2).rounded(), cy = (H / 2).rounded()
        func width(_ l: Line) -> CGFloat {
            switch l {
            case .none: return 0
            case .light: return t
            case .heavy: return 2 * t
            case .double: return 3 * t
            }
        }
        // 垂直/水平臂各自的最大宽度(非双线臂越过中心的长度取决于垂直方向的臂宽)
        let vMax = max(width(a.up), width(a.down))
        let hMax = max(width(a.left), width(a.right))

        // 第一阶段:双线臂画成 3t 实条(边缘 → 越过中心 1.5t,盖住交汇区)
        // 第三阶段:单/粗臂画实条(边缘 → 越过中心「垂直臂半宽」,与之齐平)
        func fillArm(_ line: Line, vertical: Bool, positive: Bool, solidOnly: Bool) {
            guard line != .none else { return }
            if solidOnly != (line == .double) { return }
            let lw = width(line)
            let perpHalf = (line == .double) ? 1.5 * t : (vertical ? hMax : vMax) / 2
            let cross = max(perpHalf, lw / 2)        // 至少盖到自身半宽(半臂字符 ╵ 等止于中心)
            if vertical {
                let x0 = (cx - lw / 2).rounded()
                // positive=true → 屏幕上方 = CG 高 y
                let y0 = positive ? cy - cross : 0
                let y1 = positive ? H : cy + cross
                ctx.fill(CGRect(x: x0, y: y0, width: lw, height: y1 - y0))
            } else {
                let y0 = (cy - lw / 2).rounded()
                let x0 = positive ? cx - cross : 0
                let x1 = positive ? W : cx + cross
                ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: lw))
            }
        }
        // 第二阶段:抠掉双线中缝(宽 t)。终点规则:
        //   对臂也是双线 → 抠到中心(两侧中缝相接,贯通);
        //   否则 → 越过中心 t/2,恰好断开内侧描边、保留外侧描边(拐角/T 形的标准形)
        func eraseGap(_ line: Line, vertical: Bool, positive: Bool, opposite: Line) {
            guard line == .double else { return }
            let over: CGFloat = opposite == .double ? 0 : t / 2
            if vertical {
                let x0 = (cx - t / 2).rounded()
                let y0 = positive ? cy - over : 0
                let y1 = positive ? H : cy + over
                ctx.clear(CGRect(x: x0, y: y0, width: t, height: y1 - y0))
            } else {
                let y0 = (cy - t / 2).rounded()
                let x0 = positive ? cx - over : 0
                let x1 = positive ? W : cx + over
                ctx.clear(CGRect(x: x0, y: y0, width: x1 - x0, height: t))
            }
        }

        for solidOnly in [true, false] {
            fillArm(a.up, vertical: true, positive: true, solidOnly: solidOnly)
            fillArm(a.down, vertical: true, positive: false, solidOnly: solidOnly)
            fillArm(a.left, vertical: false, positive: false, solidOnly: solidOnly)
            fillArm(a.right, vertical: false, positive: true, solidOnly: solidOnly)
            if solidOnly {
                eraseGap(a.up, vertical: true, positive: true, opposite: a.down)
                eraseGap(a.down, vertical: true, positive: false, opposite: a.up)
                eraseGap(a.left, vertical: false, positive: false, opposite: a.right)
                eraseGap(a.right, vertical: false, positive: true, opposite: a.left)
            }
        }
    }

    // MARK: - 虚线

    private static func drawDashes(cp: UInt32, ctx: CGContext, W: CGFloat, H: CGFloat, t: CGFloat) {
        // 2504-2507 三段,2508-250B 四段,254C-254F 两段;奇数码点为粗线;┆┇┊┋╎╏ 为竖向
        let n: Int = cp >= 0x254C ? 2 : (cp <= 0x2507 ? 3 : 4)
        let heavy = (cp % 2) == 1
        let vertical = cp >= 0x254C ? (cp >= 0x254E) : ((cp & 0b10) != 0)
        let lw = heavy ? 2 * t : t
        let span = vertical ? H : W
        let seg = span / CGFloat(n)
        let dash = max(1, (seg * 0.6).rounded())
        for i in 0..<n {
            let start = (CGFloat(i) * seg + (seg - dash) / 2).rounded()
            if vertical {
                ctx.fill(CGRect(x: (W / 2 - lw / 2).rounded(), y: start, width: lw, height: dash))
            } else {
                ctx.fill(CGRect(x: start, y: (H / 2 - lw / 2).rounded(), width: dash, height: lw))
            }
        }
    }

    // MARK: - 圆角弧(╭╮╯╰)

    private static func drawArc(cp: UInt32, ctx: CGContext, W: CGFloat, H: CGFloat, t: CGFloat) {
        let cx = (W / 2).rounded(), cy = (H / 2).rounded()
        let r = min(cx, cy)
        // 屏幕语义 → CG 坐标(CG +y 为屏幕上方):
        //   ╭(0x256D)= 屏幕下+右 → CG (cx,0)→弧→(W,cy)
        //   ╮(0x256E)= 屏幕下+左;╯(0x256F)= 屏幕上+左;╰(0x2570)= 屏幕上+右
        let path = CGMutablePath()
        switch cp {
        case 0x256D:
            path.move(to: CGPoint(x: cx, y: 0))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: W, y: cy), radius: r)
            path.addLine(to: CGPoint(x: W, y: cy))
        case 0x256E:
            path.move(to: CGPoint(x: cx, y: 0))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: 0, y: cy), radius: r)
            path.addLine(to: CGPoint(x: 0, y: cy))
        case 0x256F:
            path.move(to: CGPoint(x: cx, y: H))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: 0, y: cy), radius: r)
            path.addLine(to: CGPoint(x: 0, y: cy))
        default: // 0x2570 ╰
            path.move(to: CGPoint(x: cx, y: H))
            path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: W, y: cy), radius: r)
            path.addLine(to: CGPoint(x: W, y: cy))
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(t)
        ctx.setLineCap(.butt)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: - 对角线(╱╲╳)

    private static func drawDiagonal(cp: UInt32, ctx: CGContext, W: CGFloat, H: CGFloat, t: CGFloat) {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(t)
        ctx.setLineCap(.butt)
        if cp == 0x2571 || cp == 0x2573 {   // ╱:屏幕左下→右上 = CG (0,0)→(W,H)
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: W, y: H))
        }
        if cp == 0x2572 || cp == 0x2573 {   // ╲:屏幕左上→右下 = CG (0,H)→(W,0)
            ctx.move(to: CGPoint(x: 0, y: H))
            ctx.addLine(to: CGPoint(x: W, y: 0))
        }
        ctx.strokePath()
    }

    // MARK: - 块元素(2580–259F)

    private static func drawBlock(cp: UInt32, ctx: CGContext, W: CGFloat, H: CGFloat) {
        func fill(_ r: CGRect, alpha: CGFloat = 1) {
            ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
            ctx.fill(r)
        }
        let cx = (W / 2).rounded(), cy = (H / 2).rounded()
        switch cp {
        case 0x2580: fill(CGRect(x: 0, y: cy, width: W, height: H - cy))           // ▀ 上半
        case 0x2581...0x2588:                                                       // ▁…█ 下 1/8…8/8
            let k = CGFloat(cp - 0x2580)
            fill(CGRect(x: 0, y: 0, width: W, height: (H * k / 8).rounded()))
        case 0x2589...0x258F:                                                       // ▉…▏ 左 7/8…1/8
            let k = CGFloat(0x2590 - cp)
            fill(CGRect(x: 0, y: 0, width: (W * k / 8).rounded(), height: H))
        case 0x2590: fill(CGRect(x: cx, y: 0, width: W - cx, height: H))           // ▐ 右半
        case 0x2591: fill(CGRect(x: 0, y: 0, width: W, height: H), alpha: 0.25)    // ░
        case 0x2592: fill(CGRect(x: 0, y: 0, width: W, height: H), alpha: 0.50)    // ▒
        case 0x2593: fill(CGRect(x: 0, y: 0, width: W, height: H), alpha: 0.75)    // ▓
        case 0x2594: fill(CGRect(x: 0, y: (H * 7 / 8).rounded(), width: W, height: H - (H * 7 / 8).rounded()))  // ▔
        case 0x2595: fill(CGRect(x: (W * 7 / 8).rounded(), y: 0, width: W - (W * 7 / 8).rounded(), height: H))  // ▕
        default:                                                                    // 2596-259F 四象限组合
            // 屏幕象限 → CG rect:上=CG 高 y 半区
            let ul = CGRect(x: 0, y: cy, width: cx, height: H - cy)
            let ur = CGRect(x: cx, y: cy, width: W - cx, height: H - cy)
            let ll = CGRect(x: 0, y: 0, width: cx, height: cy)
            let lr = CGRect(x: cx, y: 0, width: W - cx, height: cy)
            let quads: [UInt32: [CGRect]] = [
                0x2596: [ll], 0x2597: [lr], 0x2598: [ul], 0x259D: [ur],
                0x2599: [ul, ll, lr], 0x259A: [ul, lr], 0x259B: [ul, ur, ll],
                0x259C: [ul, ur, lr], 0x259E: [ur, ll], 0x259F: [ur, ll, lr],
            ]
            (quads[cp] ?? []).forEach { fill($0) }
        }
    }

    // MARK: - 0x2500–0x254B / 0x2550–0x256C / 0x2574–0x257F 臂表
    // 命名即语义:Unicode 名称「UP/DOWN/LEFT/RIGHT × LIGHT/HEAVY/DOUBLE」逐条翻译

    private static func arms(_ cp: UInt32) -> Arms {
        let n = Line.none, l = Line.light, h = Line.heavy, d = Line.double
        switch cp {
        case 0x2500: return Arms(n, n, l, l)   // ─
        case 0x2501: return Arms(n, n, h, h)   // ━
        case 0x2502: return Arms(l, l, n, n)   // │
        case 0x2503: return Arms(h, h, n, n)   // ┃
        case 0x250C: return Arms(n, l, n, l)   // ┌
        case 0x250D: return Arms(n, l, n, h)   // ┍
        case 0x250E: return Arms(n, h, n, l)   // ┎
        case 0x250F: return Arms(n, h, n, h)   // ┏
        case 0x2510: return Arms(n, l, l, n)   // ┐
        case 0x2511: return Arms(n, l, h, n)   // ┑
        case 0x2512: return Arms(n, h, l, n)   // ┒
        case 0x2513: return Arms(n, h, h, n)   // ┓
        case 0x2514: return Arms(l, n, n, l)   // └
        case 0x2515: return Arms(l, n, n, h)   // ┕
        case 0x2516: return Arms(h, n, n, l)   // ┖
        case 0x2517: return Arms(h, n, n, h)   // ┗
        case 0x2518: return Arms(l, n, l, n)   // ┘
        case 0x2519: return Arms(l, n, h, n)   // ┙
        case 0x251A: return Arms(h, n, l, n)   // ┚
        case 0x251B: return Arms(h, n, h, n)   // ┛
        case 0x251C: return Arms(l, l, n, l)   // ├
        case 0x251D: return Arms(l, l, n, h)   // ┝
        case 0x251E: return Arms(h, l, n, l)   // ┞
        case 0x251F: return Arms(l, h, n, l)   // ┟
        case 0x2520: return Arms(h, h, n, l)   // ┠
        case 0x2521: return Arms(h, l, n, h)   // ┡
        case 0x2522: return Arms(l, h, n, h)   // ┢
        case 0x2523: return Arms(h, h, n, h)   // ┣
        case 0x2524: return Arms(l, l, l, n)   // ┤
        case 0x2525: return Arms(l, l, h, n)   // ┥
        case 0x2526: return Arms(h, l, l, n)   // ┦
        case 0x2527: return Arms(l, h, l, n)   // ┧
        case 0x2528: return Arms(h, h, l, n)   // ┨
        case 0x2529: return Arms(h, l, h, n)   // ┩
        case 0x252A: return Arms(l, h, h, n)   // ┪
        case 0x252B: return Arms(h, h, h, n)   // ┫
        case 0x252C: return Arms(n, l, l, l)   // ┬
        case 0x252D: return Arms(n, l, h, l)   // ┭
        case 0x252E: return Arms(n, l, l, h)   // ┮
        case 0x252F: return Arms(n, l, h, h)   // ┯
        case 0x2530: return Arms(n, h, l, l)   // ┰
        case 0x2531: return Arms(n, h, h, l)   // ┱
        case 0x2532: return Arms(n, h, l, h)   // ┲
        case 0x2533: return Arms(n, h, h, h)   // ┳
        case 0x2534: return Arms(l, n, l, l)   // ┴
        case 0x2535: return Arms(l, n, h, l)   // ┵
        case 0x2536: return Arms(l, n, l, h)   // ┶
        case 0x2537: return Arms(l, n, h, h)   // ┷
        case 0x2538: return Arms(h, n, l, l)   // ┸
        case 0x2539: return Arms(h, n, h, l)   // ┹
        case 0x253A: return Arms(h, n, l, h)   // ┺
        case 0x253B: return Arms(h, n, h, h)   // ┻
        case 0x253C: return Arms(l, l, l, l)   // ┼
        case 0x253D: return Arms(l, l, h, l)   // ┽
        case 0x253E: return Arms(l, l, l, h)   // ┾
        case 0x253F: return Arms(l, l, h, h)   // ┿
        case 0x2540: return Arms(h, l, l, l)   // ╀
        case 0x2541: return Arms(l, h, l, l)   // ╁
        case 0x2542: return Arms(h, h, l, l)   // ╂
        case 0x2543: return Arms(h, l, h, l)   // ╃
        case 0x2544: return Arms(h, l, l, h)   // ╄
        case 0x2545: return Arms(l, h, h, l)   // ╅
        case 0x2546: return Arms(l, h, l, h)   // ╆
        case 0x2547: return Arms(h, l, h, h)   // ╇
        case 0x2548: return Arms(l, h, h, h)   // ╈
        case 0x2549: return Arms(h, h, h, l)   // ╉
        case 0x254A: return Arms(h, h, l, h)   // ╊
        case 0x254B: return Arms(h, h, h, h)   // ╋
        case 0x2550: return Arms(n, n, d, d)   // ═
        case 0x2551: return Arms(d, d, n, n)   // ║
        case 0x2552: return Arms(n, l, n, d)   // ╒
        case 0x2553: return Arms(n, d, n, l)   // ╓
        case 0x2554: return Arms(n, d, n, d)   // ╔
        case 0x2555: return Arms(n, l, d, n)   // ╕
        case 0x2556: return Arms(n, d, l, n)   // ╖
        case 0x2557: return Arms(n, d, d, n)   // ╗
        case 0x2558: return Arms(l, n, n, d)   // ╘
        case 0x2559: return Arms(d, n, n, l)   // ╙
        case 0x255A: return Arms(d, n, n, d)   // ╚
        case 0x255B: return Arms(l, n, d, n)   // ╛
        case 0x255C: return Arms(d, n, l, n)   // ╜
        case 0x255D: return Arms(d, n, d, n)   // ╝
        case 0x255E: return Arms(l, l, n, d)   // ╞
        case 0x255F: return Arms(d, d, n, l)   // ╟
        case 0x2560: return Arms(d, d, n, d)   // ╠
        case 0x2561: return Arms(l, l, d, n)   // ╡
        case 0x2562: return Arms(d, d, l, n)   // ╢
        case 0x2563: return Arms(d, d, d, n)   // ╣
        case 0x2564: return Arms(n, l, d, d)   // ╤
        case 0x2565: return Arms(n, d, l, l)   // ╥
        case 0x2566: return Arms(n, d, d, d)   // ╦
        case 0x2567: return Arms(l, n, d, d)   // ╧
        case 0x2568: return Arms(d, n, l, l)   // ╨
        case 0x2569: return Arms(d, n, d, d)   // ╩
        case 0x256A: return Arms(l, l, d, d)   // ╪
        case 0x256B: return Arms(d, d, l, l)   // ╫
        case 0x256C: return Arms(d, d, d, d)   // ╬
        case 0x2574: return Arms(n, n, l, n)   // ╴
        case 0x2575: return Arms(l, n, n, n)   // ╵
        case 0x2576: return Arms(n, n, n, l)   // ╶
        case 0x2577: return Arms(n, l, n, n)   // ╷
        case 0x2578: return Arms(n, n, h, n)   // ╸
        case 0x2579: return Arms(h, n, n, n)   // ╹
        case 0x257A: return Arms(n, n, n, h)   // ╺
        case 0x257B: return Arms(n, h, n, n)   // ╻
        case 0x257C: return Arms(n, n, l, h)   // ╼
        case 0x257D: return Arms(l, h, n, n)   // ╽
        case 0x257E: return Arms(n, n, h, l)   // ╾
        case 0x257F: return Arms(h, l, n, n)   // ╿
        default:     return Arms(n, n, n, n)
        }
    }
}
