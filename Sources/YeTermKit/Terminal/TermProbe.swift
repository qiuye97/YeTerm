// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 终端内核冒烟测试
//
// 这个文件:不开界面,直接向 SwiftTerm 的 Terminal(纯逻辑内核)喂一段
//   含中文/颜色/样式的字节流,断言它解析出的"字符网格"是否正确
//   (中文占 2 格、颜色属性解码对不对)。这是全项目最早写的测试 ——
//   在写任何 UI 之前先确认内核数据模型,类比后端先测 DAO 再写 Controller。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import SwiftTerm

/// 无界面内核冒烟(M0-S1):
/// 用 headless `Terminal` 喂入含 CJK / SGR(16 色、256 色、真彩、样式)的字节,
/// 然后直接读字符网格,验证 M1a 自绘渲染器将依赖的全部数据通路:
///   1. 宽字符 = width-2 格 + 尾随 filler 格(code 0)
///   2. fg/bg 颜色三种表示(.ansi256 / .trueColor / .defaultColor)可解码
///   3. 样式位(bold 等)可读
/// 这是「探针」:输出网格 dump + 逐项 ✓/✗,全过返回 0。
final class ProbeDelegate: TerminalDelegate {
    // 探针不接 PTY:终端回写(如问询应答)丢弃即可
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

public enum TermProbe {
    public static func runSmoke() -> Int32 {
        let delegate = ProbeDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions.default)

        // 行序号(0 起):
        // 0: ASCII
        // 1: CJK
        // 2: SGR 颜色(16 色 / 256 色 / 真彩)
        // 3: 样式(粗体)
        let payload = "ASCII abc 123\r\n"
            + "你好，世界\r\n"
            + "\u{1b}[31mR\u{1b}[0m \u{1b}[38;5;196mC\u{1b}[0m \u{1b}[38;2;18;52;86mT\u{1b}[0m\r\n"
            + "\u{1b}[1mB\u{1b}[0m plain"
        terminal.feed(text: payload)

        // ---- 网格 dump(前 4 行的非空格) ----
        // 注:CharData.code 是 internal;公开 API 判 filler 用 width == 0
        // (宽字符本体 width==2,其后补位格 width==0,普通格 width==1)
        print("== grid dump (rows 0-3) ==")
        for row in 0..<4 {
            guard let line = terminal.getLine(row: row) else { continue }
            for col in 0..<terminal.cols {
                let cd = line[col]
                if cd.width == 0 {
                    // filler:只在前一格是宽字符时标注
                    if col > 0, line[col - 1].width == 2 {
                        print("row=\(row) col=\(col) (filler width=0)")
                    }
                    continue
                }
                let ch = cd.getCharacter()
                // 空白格:真空格或从未写过的格(getCharacter() 返回 NUL)
                if ch == " " || ch == "\0" { continue }
                print("row=\(row) col=\(col) ch='\(ch)' width=\(cd.width) fg=\(describe(cd.attribute.fg)) style=\(describeStyle(cd.attribute.style))")
            }
        }

        // ---- 断言 ----
        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        // 1) 宽字符:row1 col0 = '你' width 2;col1 = filler(code 0)
        if let l1 = terminal.getLine(row: 1) {
            let ni = l1[0]
            check("CJK 宽字符 width==2", ni.getCharacter() == "你" && ni.width == 2,
                  detail: "ch='\(ni.getCharacter())' width=\(ni.width)")
            check("宽字符尾随 filler(width==0)", l1[1].width == 0,
                  detail: "width=\(l1[1].width)")
            // '好' 应落在 col2(每个 CJK 占 2 列)
            check("列推进正确('好'在 col2)", l1[2].getCharacter() == "好",
                  detail: "col2='\(l1[2].getCharacter())'")
        } else {
            check("row1 可读", false)
        }

        // 2) 颜色解码:row2 => 'R'(SGR31→ansi 1) / 'C'(256 号 196) / 'T'(真彩 18,52,86)
        if let l2 = terminal.getLine(row: 2) {
            var found16 = false, found256 = false, foundTrue = false
            var default16 = "", detail256 = "", detailTrue = ""
            for col in 0..<terminal.cols {
                let cd = l2[col]
                guard cd.width != 0 else { continue }
                let ch = cd.getCharacter()
                switch ch {
                case "R":
                    if case .ansi256(let code) = cd.attribute.fg { found16 = (code == 1); default16 = "ansi256(\(code))" }
                    else { default16 = "\(describe(cd.attribute.fg))" }
                case "C":
                    if case .ansi256(let code) = cd.attribute.fg { found256 = (code == 196); detail256 = "ansi256(\(code))" }
                    else { detail256 = "\(describe(cd.attribute.fg))" }
                case "T":
                    if case .trueColor(let r, let g, let b) = cd.attribute.fg {
                        foundTrue = (r == 18 && g == 52 && b == 86); detailTrue = "trueColor(\(r),\(g),\(b))"
                    } else { detailTrue = "\(describe(cd.attribute.fg))" }
                default: break
                }
            }
            check("SGR 16 色解码(31→ansi 1)", found16, detail: default16)
            check("SGR 256 色解码(196)", found256, detail: detail256)
            check("SGR 真彩解码(18,52,86)", foundTrue, detail: detailTrue)
        } else {
            check("row2 可读", false)
        }

        // 3) 样式位:row3 'B' 为 bold
        if let l3 = terminal.getLine(row: 3) {
            var boldOK = false
            for col in 0..<terminal.cols {
                let cd = l3[col]
                if cd.width != 0, cd.getCharacter() == "B" {
                    boldOK = cd.attribute.style.contains(.bold)
                    break
                }
            }
            check("样式位 bold 可读", boldOK)
        } else {
            check("row3 可读", false)
        }

        print(pass ? "SMOKE-PASS" : "SMOKE-FAIL")
        return pass ? 0 : 1
    }

    private static func describe(_ c: Attribute.Color) -> String {
        switch c {
        case .defaultColor: return "default"
        case .defaultInvertedColor: return "defaultInverted"
        case .ansi256(let code): return "ansi256(\(code))"
        case .trueColor(let r, let g, let b): return "trueColor(\(r),\(g),\(b))"
        }
    }

    private static func describeStyle(_ s: CharacterStyle) -> String {
        var flags: [String] = []
        if s.contains(.bold) { flags.append("bold") }
        if s.contains(.underline) { flags.append("underline") }
        if s.contains(.inverse) { flags.append("inverse") }
        if s.contains(.dim) { flags.append("dim") }
        if s.contains(.italic) { flags.append("italic") }
        return flags.isEmpty ? "-" : flags.joined(separator: "+")
    }
}
