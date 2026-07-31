// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— OSD 画布文本工具(v1.3 抽取)
//
// 这个文件:所有"OSD 风格字符画布"(粘贴确认框/服务器选单)共用的列宽工具。
//   终端里中文/emoji 占 2 列、英文占 1 列,画盒绘边框要按"显示列数"补空格
//   截断,不然右框会被宽字符撑歪。原先这套逻辑私藏在 PasteGuardController,
//   服务器选单也要用,抽出来(类比 Java 把工具方法提进 StringUtils)。
//
// 语法看点:`enum OSDText` 无 case 的枚举当命名空间用 —— Swift 惯用法,
//   比 struct 更明确"不可实例化,纯静态工具"(类比 final class + private 构造)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

enum OSDText {
    /// 近似 wcwidth:中日韩/全角/emoji 占 2 列,其余按 1 列。
    /// (SwiftTerm 自家的 UnicodeUtil 是 internal 摸不到;这张粗表只用于
    ///  截断与补空格,个别生僻字差 1 列顶多右框微移,不会撑爆画布)
    static func cellWidth(_ ch: Character) -> Int {
        guard let v = ch.unicodeScalars.first?.value else { return 1 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F000...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    static func displayWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + cellWidth($1) }
    }

    /// 按显示列数截断(超出补 ".." 尾标;纯 ASCII,避开 … 的宽度歧义)
    static func clip(_ s: String, to maxW: Int) -> String {
        if displayWidth(s) <= maxW { return s }
        var w = 0, out = ""
        for ch in s {
            let cw = cellWidth(ch)
            if w + cw > maxW - 2 {   // 预留 ".." 两列
                return out + ".."
            }
            out.append(ch)
            w += cw
        }
        return out
    }

    /// 按显示列数右补空格到定宽(超长先截断)
    static func pad(_ s: String, to width: Int) -> String {
        let c = clip(s, to: width)
        return c + String(repeating: " ", count: max(0, width - displayWidth(c)))
    }
}
