// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 服务器选单(v1.3 SSH,⇧⌘O 呼出)
//
// 这个文件:OSD 风格的"远程主机快速连接"弹层 —— 和 ⌥⌘O 调节面板、粘贴
//   确认框同族的字符画布(48×14 假想终端 → 渲染成纹理 → 合成进画面过 CRT
//   管线)。交互:↑↓ 选择、←→(或 PgUp/PgDn)翻页(每页 8 台)、数字键
//   1-8 选中本页第 N 台、回车=当前屏连接、⇧回车=分屏后在新屏连接、Esc 关。
// 选单只管"选了谁、怎么连",真正敲 ssh 命令/自动填密码在窗口控制器
//   (闭包上报,和搜索条同款解耦套路)。
//
// 语法看点:`event.modifierFlags.contains(.shift)` —— AppKit 键盘事件的
//   修饰键是 OptionSet(位标志集合),contains 即"按住了没";
//   类比 JS 的 event.shiftKey。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm

/// 服务器选单画布 + 状态机(OSDController 同构三件套之一)
final class ServerPickerController {
    private(set) var visible = false
    let cols = 48, rows = 14
    let pageSize = 8

    private(set) var hosts: [SSHHost] = []
    private(set) var selected = 0

    /// 连接请求(主机, 是否分屏连)—— 窗口控制器接线
    var onConnect: ((SSHHost, Bool) -> Void)?
    /// 关闭(Esc/连接后)—— 窗口控制器还焦点+触发重合成
    var onDismiss: (() -> Void)?

    private let terminal: Terminal
    private let termDelegate = HarnessTermDelegate()
    private let content: ContentRenderer

    init(ctx: MetalContext) {
        terminal = Terminal(delegate: termDelegate,
                            options: TerminalOptions(cols: cols, rows: rows))
        content = ContentRenderer(ctx: ctx)
    }

    var page: Int { hosts.isEmpty ? 0 : selected / pageSize }
    var pageCount: Int { max(1, (hosts.count + pageSize - 1) / pageSize) }

    func show() {
        SSHHostStore.shared.load()          // 设置页刚改完也拿到最新清单
        hosts = SSHHostStore.shared.hosts
        selected = 0
        visible = true
        redraw()
    }

    func hide() {
        visible = false
    }

    /// 键盘路由(ServerPickerKeyView 转发)。返回 true = 已消费
    func handleKey(_ event: NSEvent) -> Bool {
        guard visible else { return false }
        switch event.keyCode {
        case 53:                                  // Esc
            hide()
            onDismiss?()
            return true
        case 36, 76:                              // Return / 小键盘 Enter
            guard !hosts.isEmpty else {
                hide()
                onDismiss?()
                return true
            }
            let host = hosts[selected]
            let split = event.modifierFlags.contains(.shift)
            hide()
            onDismiss?()
            onConnect?(host, split)
            return true
        case 126: move(-1)                        // ↑
        case 125: move(+1)                        // ↓
        case 123, 116: flip(-1)                   // ← / PgUp
        case 124, 121: flip(+1)                   // → / PgDn
        default:
            // 数字 1-8:选中本页第 N 台(再回车连接)
            if let ch = event.charactersIgnoringModifiers?.first,
               let d = ch.wholeNumberValue, (1...pageSize).contains(d) {
                let idx = page * pageSize + d - 1
                if idx < hosts.count { selected = idx }
            }
            // 其余按键吞掉:选单在场不往 shell 漏字
        }
        redraw()
        return true
    }

    private func move(_ delta: Int) {
        guard !hosts.isEmpty else { return }
        selected = (selected + delta + hosts.count) % hosts.count
    }

    private func flip(_ dir: Int) {
        guard !hosts.isEmpty else { return }
        let target = page + dir
        guard (0..<pageCount).contains(target) else { return }
        selected = min(target * pageSize, hosts.count - 1)
    }

    /// 整幅重 feed(与 OSD/粘贴确认框同款手排;选中行 ANSI 反显)
    private func redraw() {
        var s = "\u{1b}[2J\u{1b}[H"
        let inner = cols - 2
        let top = "┌" + String(repeating: "─", count: inner) + "┐"
        let bottom = "└" + String(repeating: "─", count: inner) + "┘"
        func boxLine(_ text: String, invert: Bool = false) -> String {
            let body = text + String(repeating: " ",
                                     count: max(0, inner - OSDText.displayWidth(text)))
            return "│" + (invert ? "\u{1b}[7m\(body)\u{1b}[27m" : body) + "│\r\n"
        }
        // 标题:左名右页码(多页才显)
        let left = " YETERM  " + L("服务器选单")
        let right = pageCount > 1 ? Lf("第 %1$d/%2$d 页 ", page + 1, pageCount) : ""
        let gap = max(1, inner - OSDText.displayWidth(left) - OSDText.displayWidth(right))
        s += top + "\r\n"
        s += boxLine(left + String(repeating: " ", count: gap) + right, invert: true)
        s += boxLine("")
        if hosts.isEmpty {
            s += boxLine("")
            s += boxLine("      " + L("(还没有配置服务器)"))
            s += boxLine("")
            s += boxLine("      " + L("设置 > 远程主机 里添加"))
            for _ in 0..<4 { s += boxLine("") }
            s += boxLine("")
            s += boxLine(" " + L("ESC 关闭"))
        } else {
            let start = page * pageSize
            for slot in 0..<pageSize {
                let idx = start + slot
                guard idx < hosts.count else {
                    s += boxLine("")
                    continue
                }
                let h = hosts[idx]
                // 手排:序号1 + 名字12 + 地址18 + 备注吃剩余(全按显示列数补齐)
                let line = " \(slot + 1) " + OSDText.pad(h.name, to: 12) + " "
                    + OSDText.pad(h.address, to: 18) + " "
                    + OSDText.clip(h.note, to: inner - 36)
                s += boxLine(OSDText.clip(line, to: inner), invert: idx == selected)
            }
            s += boxLine("")
            s += boxLine(" " + L("ENTER 连接  SHIFT+ENTER 分屏连  ESC"))
        }
        s += bottom
        terminal.feed(text: s)
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }

    /// 画布全文(auto-drive 断言用;滤零宽 filler,同 PasteGuardController)
    func canvasText() -> String {
        var out = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            for c in 0..<terminal.cols {
                let ch = line[c].getCharacter()
                if ch != "\u{0}" { out.append(ch) }
            }
        }
        return out
    }
}

/// 隐形键盘捕手(OSDKeyView 同款):选单在场时抢 firstResponder
final class ServerPickerKeyView: NSView {
    weak var picker: ServerPickerController?
    /// 每次按键后回调(触发 overlay 重合成 —— 普通模式没有特效动画帧,
    /// 不主动踢一脚的话画布变化要等下一次内容重绘才上屏)
    var onActivity: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if picker?.handleKey(event) == true {
            onActivity?()
        }
    }
}
