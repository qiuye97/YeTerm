#!/usr/bin/env swift
// ─────────────────────────────────────────────────────────────────────────────
// YeTerm App 图标生成器
//
// 设计:一台显像管显示器,屏幕上亮着两行荧光绿的开机文字 ——
//
//     >Ye
//     Ready.
//
//   「Ready.」= Commodore 64 开机后那句著名的就绪提示,也呼应内置的 C64 预设。
//
// ⚠️ 为什么字形是手工点阵、不用现成字体:
//   图标是要随 GPL-3 项目分发的美术资产,来源必须干净到没有任何模糊地带。
//   这里的每个字母都是下面 `glyphs` 里手写的 5×7 点阵 —— 不依赖任何字体文件,
//   整张图标 100% 是本项目自己的几何。5×7 也正是真·点阵终端的字模规格,
//   放大后那种方块感本身就是对的。
//   (历史留档:此前 app 里装的是从 macosicons.com 下载的第三方图标,
//    来源许可不明,开源前已替换成本文件生成的原创图标。)
//
// 用法: swift scripts/make_icon.swift <输出目录>
// 产出: <dir>/AppIcon.iconset/*.png,随后由 iconutil 打包成 .icns
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetPath = outDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// ── 手写 5×7 点阵字模 ────────────────────────────────────────────────────────
// 每个字符 7 行、每行 5 列,'#' = 点亮。只做图标需要的这几个字符。
let glyphs: [Character: [String]] = [
    ">": ["#....",
          ".#...",
          "..#..",
          "...#.",
          "..#..",
          ".#...",
          "#...."],
    "Y": ["#...#",
          "#...#",
          ".#.#.",
          "..#..",
          "..#..",
          "..#..",
          "..#.."],
    "e": [".....",
          ".....",
          ".###.",
          "#...#",
          "#####",
          "#....",
          ".###."],
    "R": ["####.",
          "#...#",
          "#...#",
          "####.",
          "#.#..",
          "#..#.",
          "#...#"],
    "a": [".....",
          ".....",
          ".###.",
          "....#",
          ".####",
          "#...#",
          ".####"],
    "d": ["....#",
          "....#",
          ".####",
          "#...#",
          "#...#",
          "#...#",
          ".####"],
    "y": [".....",
          ".....",
          "#...#",
          "#...#",
          ".####",
          "....#",
          ".###."],
    ".": [".....",
          ".....",
          ".....",
          ".....",
          ".....",
          ".##..",
          ".##.."],
]

/// 把一行字按点阵画出来。`px` = 一个点的边长,`origin` = 左上角(翻转坐标系里的上)
func drawText(_ s: String, at origin: CGPoint, px: CGFloat, ctx: CGContext) {
    var x = origin.x
    for ch in s {
        if let rows = glyphs[ch] {
            for (r, row) in rows.enumerated() {
                for (c, bit) in row.enumerated() where bit == "#" {
                    // y 轴向下:第 r 行在 origin.y 之下 r 个点
                    ctx.fill(CGRect(x: x + CGFloat(c) * px,
                                    y: origin.y - CGFloat(r + 1) * px,
                                    width: px, height: px))
                }
            }
        }
        x += 6 * px          // 5 列字模 + 1 列字间距
    }
}

func textWidth(_ s: String, px: CGFloat) -> CGFloat {
    s.isEmpty ? 0 : CGFloat(s.count) * 6 * px - px   // 末尾那列间距不算
}

/// 构图档位:同一套设计在不同尺寸下要**换构图**,不能只是缩放 ——
/// 16px 上屏幕区只剩十来个像素,两行字必然糊成一团。
enum Layout { case tiny, compact, full }

func drawIcon(size s: CGFloat, layout: Layout) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let u = s / 1024.0                       // 归一化单位:所有尺寸按 1024 设计再缩放

    // ── 机壳:macOS 标准圆角方形(824/1024,圆角 185)──────────────────────
    let bezel = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bezelPath = CGPath(roundedRect: bezel, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

    // 机壳投影:让图标从桌面上「浮」起来。极小尺寸不画 —— 模糊阴影在
    // 十几个像素上只会把边缘糊成一圈灰,反而更难辨认。
    ctx.saveGState()
    if layout != .tiny {
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 32 * u,
                      color: CGColor(gray: 0, alpha: 0.45))
    }
    ctx.addPath(bezelPath)
    ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 机壳本体:上亮下暗的塑料质感
    ctx.saveGState()
    ctx.addPath(bezelPath)
    ctx.clip()
    let caseColors = [CGColor(red: 0.30, green: 0.31, blue: 0.30, alpha: 1),
                      CGColor(red: 0.13, green: 0.14, blue: 0.13, alpha: 1)] as CFArray
    let caseGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: caseColors, locations: [0, 1])!
    ctx.drawLinearGradient(caseGrad, start: CGPoint(x: 0, y: bezel.maxY),
                           end: CGPoint(x: 0, y: bezel.minY), options: [])
    ctx.restoreGState()

    // ── 屏幕:内嵌,深绿黑 ────────────────────────────────────────────────
    // 极小尺寸把机壳收窄,尽量把像素让给屏幕
    let inset: CGFloat = layout == .tiny ? 44 : 78
    let screen = bezel.insetBy(dx: inset * u, dy: inset * u)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 96 * u, cornerHeight: 96 * u, transform: nil)

    // 屏幕内阴影(机壳压在玻璃上的那圈暗边)
    ctx.saveGState()
    ctx.addPath(bezelPath); ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: 6 * u), blur: 18 * u,
                  color: CGColor(gray: 0, alpha: 0.75))
    ctx.addPath(screenPath)
    ctx.setFillColor(CGColor(red: 0.012, green: 0.045, blue: 0.022, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()

    // 磷光余晖:屏幕中心偏上的那团绿光
    let glowColors = [CGColor(red: 0.05, green: 0.42, blue: 0.20, alpha: 0.55),
                      CGColor(red: 0.00, green: 0.10, blue: 0.05, alpha: 0.0)] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: screen.midX, y: screen.midY + screen.height * 0.06),
                           startRadius: 0,
                           endCenter: CGPoint(x: screen.midX, y: screen.midY + screen.height * 0.06),
                           endRadius: screen.width * 0.70, options: [])

    // ── 文字 ────────────────────────────────────────────────────────────
    // 小尺寸(≤32px)只画 ">Ye":两行在 16 像素上会糊成一团,不如把一行画大画清楚。
    let phosphor = CGColor(red: 0.29, green: 1.0, blue: 0.44, alpha: 1)
    ctx.setFillColor(phosphor)
    ctx.setShadow(offset: .zero, blur: 26 * u,
                  color: CGColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 0.85))

    // 点阵尺寸由「最长那行要占多少屏宽」反推:
    //   "Ready." = 6 字 × 6 点 − 1 = 35 点宽,要占屏宽 ~80% ⇒ px = 宽/44
    switch layout {
    case .tiny:
        // 只留一个提示符 + 光标:16px 上唯一还能认出来的构图
        let px = screen.width / 11
        let w = 5 * px + 2 * px + 5 * px          // ">" + 间距 + 光标
        let x = screen.midX - w / 2
        let y = screen.midY + 3.5 * px
        drawText(">", at: CGPoint(x: x, y: y), px: px, ctx: ctx)
        ctx.fill(CGRect(x: x + 7 * px, y: y - 7 * px, width: 5 * px, height: 7 * px))
    case .compact:
        // 只画 ">Ye"(3 字 = 17 点),放大到占屏宽 ~72%
        let line = ">Ye"
        let px = screen.width / 24
        let w = textWidth(line, px: px)
        drawText(line, at: CGPoint(x: screen.midX - w / 2, y: screen.midY + 3.5 * px), px: px, ctx: ctx)
    case .full:
        // 两行左对齐,像真终端那样贴着左边;下面再跟一个等待输入的光标块
        let px = screen.width / 44
        let lineGap: CGFloat = 10                       // 行距(点):7 高 + 3 空
        let left = screen.minX + screen.width * 0.10
        let blockDots = lineGap * 2 + 7                 // 三行整体垂直居中
        let topY = screen.midY + blockDots * px / 2
        drawText(">Ye", at: CGPoint(x: left, y: topY), px: px, ctx: ctx)
        drawText("Ready.", at: CGPoint(x: left, y: topY - lineGap * px), px: px, ctx: ctx)
        ctx.fill(CGRect(x: left, y: topY - lineGap * 2 * px - 7 * px, width: 5 * px, height: 7 * px))
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // ── 扫描线 ──────────────────────────────────────────────────────────
    // 小尺寸不画:一像素宽的暗线在 16px 上只会把画面糊灰
    if s >= 128 {
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
        let lineH = max(4 * u, 1)
        var y = screen.minY
        while y < screen.maxY {
            ctx.fill(CGRect(x: screen.minX, y: y, width: screen.width, height: lineH))
            y += lineH * 2.6
        }
    }

    // ── 玻璃反光:左上到右下的一道斜光(极小尺寸略去)──────────────────
    if layout != .tiny {
    ctx.saveGState()
    let hi = CGMutablePath()
    hi.move(to: CGPoint(x: screen.minX, y: screen.maxY))
    hi.addLine(to: CGPoint(x: screen.minX + screen.width * 0.52, y: screen.maxY))
    hi.addLine(to: CGPoint(x: screen.minX, y: screen.maxY - screen.height * 0.52))
    hi.closeSubpath()
    ctx.addPath(hi); ctx.clip()
    let hiColors = [CGColor(gray: 1, alpha: 0.085), CGColor(gray: 1, alpha: 0.0)] as CFArray
    let hiGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: hiColors, locations: [0, 1])!
    ctx.drawLinearGradient(hiGrad, start: CGPoint(x: screen.minX, y: screen.maxY),
                           end: CGPoint(x: screen.minX + screen.width * 0.42,
                                        y: screen.maxY - screen.height * 0.42), options: [])
    ctx.restoreGState()
    }

    ctx.restoreGState()   // 解除屏幕裁剪

    // 屏幕边缘那圈细高光(玻璃的厚度感)
    ctx.addPath(screenPath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()

    img.unlockFocus()
    return img
}

func writePNG(px: Int, name: String) {
    // 每个尺寸单独绘制(而不是缩放 1024 母版):小图用简化构图,细节才不糊
    let image = drawIcon(size: CGFloat(px), layout: px <= 16 ? .tiny : (px <= 32 ? .compact : .full))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: iconsetPath + "/" + name))
}

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in specs { writePNG(px: px, name: name) }
print("iconset 已生成: \(iconsetPath)")
