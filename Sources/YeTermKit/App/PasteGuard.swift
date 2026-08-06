// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 粘贴保护确认框(v1.2 #6;v1.3 改版 OSD 风格)
//
// 这个文件:往终端粘贴**多行文本**时弹出的确认面板。为什么要拦?
//   终端里每个换行都会被 shell 当"回车执行"——误贴一段含 rm 的脚本,
//   贴进去的瞬间就跑完了。所有现代终端(iTerm2/Kitty/Windows Terminal)
//   都有这道闸。
// v1.3 改版:观感从"AppKit 浮层卡片"换成 **OSD 菜单同款**(用户点名)——
//   一块小的假想终端画布画出盒绘边框菜单,渲染成纹理后合成进画面中央,
//   跟内容一起过 CRT 管线:CRT 模式吃荧光/扫描线/弧度,普通模式跟配色,
//   和老显示器屏上菜单一个质感(实现三件套与 OSDController 同构)。
// 交互不变:⏎ 确认粘贴、⎋ 取消;预览只读。
//
// 语法看点:`Character.unicodeScalars` —— Swift 的字符串按"用户感知字符"
//   (grapheme)遍历,一个 emoji 算一个 Character;取首个 Unicode 标量查
//   区间表就能近似判断"占终端 1 列还是 2 列"(中文/emoji 占 2 列)。
//   类比 Java:String.codePoints() + 手写 wcwidth。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm

/// 粘贴确认面板(OSD 风格):48×12 假想终端画布,整幅重 feed。
/// onConfirm/onCancel 由窗口控制器接线(确认→真粘贴;取消→纯关闭)。
final class PasteGuardController {
    private(set) var visible = false
    let cols = 48, rows = 12

    private let terminal: Terminal
    private let termDelegate = HarnessTermDelegate()
    private let content: ContentRenderer

    init(ctx: MetalContext) {
        terminal = Terminal(delegate: termDelegate,
                            options: TerminalOptions(cols: cols, rows: rows))
        content = ContentRenderer(ctx: ctx)
    }

    /// 装填并显示:标题反显(警示语义,同 OSD 选中行)+ 预览前 6 行
    func present(text: String) {
        visible = true
        redraw(text: text)
    }

    func hide() {
        visible = false
    }

    /// 预览净化:粘贴内容是任意字节,控制字符(含 ESC)直接 feed 会被
    /// 画布终端当转义序列执行 —— 制表符换两空格,其余控制字符换 "·"
    private func sanitize(_ line: Substring) -> String {
        var out = ""
        for ch in line {
            if ch == "\t" {
                out += "  "
            } else if let v = ch.unicodeScalars.first?.value, v < 0x20 || v == 0x7f {
                out += "·"
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 整幅重 feed(OSDController.redraw 同款手排;宽度按显示列数逐行补齐)
    private func redraw(text: String) {
        var s = "\u{1b}[2J\u{1b}[H"
        let top = "┌" + String(repeating: "─", count: cols - 2) + "┐"
        let bottom = "└" + String(repeating: "─", count: cols - 2) + "┘"
        func boxLine(_ inner: String, invert: Bool = false) -> String {
            let pad = max(0, cols - 2 - OSDText.displayWidth(inner))
            let body = inner + String(repeating: " ", count: pad)
            return "│" + (invert ? "\u{1b}[7m\(body)\u{1b}[27m" : body) + "│\r\n"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let title = " YETERM  " + Lf("粘贴确认 -- %1$d 行 / %2$d 字符", lines.count, text.count)
        s += top + "\r\n"
        s += boxLine(OSDText.clip(title, to: cols - 2), invert: true)
        s += boxLine("")
        // 预览区固定 6 行(不足补空行);超过 6 行时末行改成"还有 N 行"
        let previewRows = 6
        for i in 0..<previewRows {
            if lines.count > previewRows && i == previewRows - 1 {
                s += boxLine(" " + Lf("...(还有 %d 行)", lines.count - previewRows + 1))
            } else if i < lines.count {
                s += boxLine(OSDText.clip(" " + sanitize(lines[i]), to: cols - 2))
            } else {
                s += boxLine("")
            }
        }
        s += boxLine("")
        s += boxLine("        " + L("ENTER 粘贴          ESC 取消"))
        s += bottom
        terminal.feed(text: s)
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }

    /// 画布全文(auto-drive 断言预览如实上画用)。
    /// 宽字符(CJK)在网格里占"本体格+零宽 filler 格",filler 的字符是 \0 ——
    /// 不滤掉的话拼出来是"粘\0贴\0确\0认",contains 断言必失败(首版实测)
    func canvasText() -> String {
        var out = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            for c in 0..<terminal.cols {
                let ch = terminal.getCharacter(for: line[c])
                if ch != "\u{0}" { out.append(ch) }
            }
        }
        return out
    }
}

/// 隐形键盘捕手(OSDKeyView 同款):确认框在场时抢 firstResponder,
/// ⏎/⎋ 分流到回调,其余按键吞掉不往终端漏字。isHidden 兼作"在场"标志
/// (auto-drive 场景 12 靠它断言拦截状态)。
final class PasteGuardView: NSView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return / 小键盘 Enter
            onConfirm?()
        case 53:       // Esc
            onCancel?()
        default:
            break
        }
    }
}
