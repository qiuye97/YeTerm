// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 终端颜色的"翻译官"
//
// 这个文件:shell 输出里的颜色不是 RGB,是"指令"——比如字节序列
//   `ESC[31m` 表示"接下来用红色"(叫 SGR 转义序列,终端界的行业黑话)。
//   SwiftTerm 解析后存成枚举(基础 16 色 / 256 色 / 真彩),本文件负责
//   翻译成着色器能用的 RGB 浮点值。
// 重要考据:16 色的具体色值**不是标准 xterm 色**,而是逐值移植
//   cool-retro-term 的专属调色板 —— 最典型:亮青色其实是奶油白!
//   `ls` 的目录名(粗体青)靠这条才能染成正确的荧光色(勘差过程见 git log)。
//
// 语法看点:
//   `enum` + `case .ansi256(let code)` —— Swift 的枚举可以**带关联值**
//     (一个枚举成员携带数据),配合 switch 模式匹配解构,
//     类比 Java 的 sealed interface + record + pattern matching,但早了十年。
//   `swap(&fg, &bg)` —— 标准库交换函数,& 表示按引用传(inout)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import simd
import SwiftTerm

/// SGR 颜色解析:Attribute.Color → RGB(0~1,sRGB 编码值)。
/// 调色板 = cool-retro-term 专用 colorscheme(qmltermwidget
/// lib/color-schemes/cool-retro-term.colorscheme 逐值移植)——观感一比一的
/// 隐蔽前提:它不是标准 xterm 色!最典型的差异是亮青=奶油白 (236,234,190),
/// `ls` 的 bold-cyan 目录名经荧光染色后呈纯磷光色而非青绿(q6 对拍勘差结论)。
enum AnsiColor {
    /// cool-retro-term colorscheme:0-7 普通,8-15 Intense(CRT 模式专属)
    static let crtBasic16: [SIMD3<Float>] = [
        rgb(0, 0, 0),       rgb(255, 43, 43),    // black, red
        rgb(28, 172, 120),  rgb(248, 213, 104),  // green, yellow
        rgb(43, 108, 196),  rgb(255, 29, 206),   // blue, magenta
        rgb(24, 167, 181),  rgb(179, 179, 179),  // cyan, white
        rgb(106, 106, 106), rgb(253, 94, 83),    // intense black..
        rgb(168, 228, 160), rgb(254, 254, 34),
        rgb(154, 206, 235), rgb(252, 116, 253),
        rgb(236, 234, 190), rgb(255, 255, 255),
    ]

    private static func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        .init(r / 255, g / 255, b / 255)
    }

    static let crtFg = SIMD3<Float>(1, 1, 1)   // colorscheme Foreground = 纯白
    static let crtBg = SIMD3<Float>(0, 0, 0)

    // ---- 普通终端模式覆盖表(v1.2 用户裁决:CRT 关时 Terminal.app 式独立
    // 颜色系统 —— 文字/背景/ANSI 16 色全可调,与 CRT 荧光染色两套互不污染)。
    // 全主线程读写;nil = CRT 模式(crterm 专属调色板)。
    static var plainOverride: (fg: SIMD3<Float>, bg: SIMD3<Float>, palette: [SIMD3<Float>])?

    // ---- CRT 模式的 ANSI 16 色覆盖(v1.2 预设大更新):经典配色预设携带官方
    // ANSI 表(Dracula/Nord…的 vim/htop 彩色也原汁);nil = crterm 专属调色板。
    // 内置经典 CRT 主题一律 nil(用户裁决:不给它们配 ANSI 定制 —— 荧光染色
    // 考据观感靠专属调色板,且单色主题 chroma=0 下 ANSI 色本就会被染成单色)
    static var crtOverride: [SIMD3<Float>]?

    /// 当前生效的默认前景/背景/16 色(消费方无感知切换;普通模式覆盖优先)
    static var defaultFg: SIMD3<Float> { plainOverride?.fg ?? crtFg }
    static var defaultBg: SIMD3<Float> { plainOverride?.bg ?? crtBg }
    static var basic16: [SIMD3<Float>] { plainOverride?.palette ?? crtOverride ?? crtBasic16 }

    /// crterm 专属调色板的 hex 形式(设置页 ANSI 网格显示"当前默认"用)
    static let crtBasic16Hex: [String] = [
        "#000000", "#ff2b2b", "#1cac78", "#f8d568",
        "#2b6cc4", "#ff1dce", "#18a7b5", "#b3b3b3",
        "#6a6a6a", "#fd5e53", "#a8e4a0", "#fefe22",
        "#9aceeb", "#fc74fd", "#eceabe", "#ffffff",
    ]

    /// 普通模式默认 ANSI 16 色 = macOS Terminal.app 同款(非 crterm 奶油白系)
    static let terminalAppAnsiHex: [String] = [
        "#000000", "#c23621", "#25bc24", "#adad27",
        "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
        "#818383", "#fc391f", "#31e722", "#eaec23",
        "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb",
    ]

    static func resolve(_ c: Attribute.Color, isFg: Bool) -> SIMD3<Float> {
        switch c {
        case .defaultColor:
            return isFg ? defaultFg : defaultBg
        case .defaultInvertedColor:
            return isFg ? defaultBg : defaultFg
        case .ansi256(let code):
            return ansi256(Int(code))
        case .trueColor(let r, let g, let b):
            return .init(Float(r) / 255, Float(g) / 255, Float(b) / 255)
        }
    }

    /// 256 色表:0-15 基色,16-231 6×6×6 立方,232-255 灰阶
    static func ansi256(_ code: Int) -> SIMD3<Float> {
        if code < 16 { return basic16[max(0, code)] }
        if code < 232 {
            let i = code - 16
            let steps: [Float] = [0, 95, 135, 175, 215, 255]
            let r = steps[(i / 36) % 6], g = steps[(i / 6) % 6], b = steps[i % 6]
            return .init(r / 255, g / 255, b / 255)
        }
        let grey = Float(8 + (code - 232) * 10) / 255
        return .init(grey, grey, grey)
    }

    /// 按样式修饰前景/背景(inverse 交换、dim 变暗、bold→Intense 色)
    static func effective(attr: Attribute) -> (fg: SIMD3<Float>, bg: SIMD3<Float>) {
        var fg = resolve(attr.fg, isFg: true)
        var bg = resolve(attr.bg, isFg: false)
        // Konsole/qmltermwidget 语义:粗体基础色(0-7)升为 Intense 变体
        // (ls 目录名 bold-cyan → 奶油白正是靠这条)
        if attr.style.contains(.bold), case .ansi256(let code) = attr.fg, code < 8 {
            fg = basic16[Int(code) + 8]
        }
        if attr.style.contains(.inverse) { swap(&fg, &bg) }
        if attr.style.contains(.dim) { fg *= 0.6 }
        return (fg, bg)
    }
}
