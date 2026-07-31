// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— OSD 屏上调节面板(v1.2 #14,复古组可选件)
//
// 老 CRT 显示器按 MENU 键,荧光屏上会叠出一块像素风调节菜单(BRIGHTNESS
// ▓▓▓░░ 那种)。这里复刻它:⌥⌘O 呼出,↑↓ 选参数、←→ 调值、Esc 关闭,
// 5 秒不动自动消失 —— 值条改的是**真参数**(直连设置模型,实时生效+写盘)。
//
// 实现三件套(BootScreen 同款思路):
//   ① OSDController:一个 34×12 的假想终端当"画布",每次变化整幅重 feed
//      (选中行用 ANSI 反显);ContentRenderer 渲染成纹理 → overlay 把它
//      合成进画面中央 → 自动过 CRT 管线,和真显示器 OSD 一个质感。
//   ② OSDKeyView:隐形视图抢键盘(不然方向键会打进 shell);
//   ③ 直连 SettingsModel:set 即触发全窗口广播与防抖写盘,零新持久化。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm

/// OSD 状态机 + 画布渲染。可调参数 = 六个 0~1 观感旋钮(直连 SettingsModel)。
final class OSDController {
    struct Item {
        let label: String
        let get: () -> Double
        let set: (Double) -> Void
    }

    private let items: [Item]
    private var selected = 0
    private(set) var visible = false
    private var lastInteraction = CACurrentMediaTime()

    private let terminal: Terminal
    private let termDelegate = HarnessTermDelegate()
    private let content: ContentRenderer
    // 值条 20 格 × 步进 0.05 = 一一对应(用户实测反馈:10 格条一格管两档,
    // 按一下 # 不一定动,手感断档)
    let cols = 40, rows = 12
    private let barSteps = 20

    /// 超时自动关闭回调(窗口控制器还焦点)
    var onAutoHide: (() -> Void)?
    private var hideTimer: Timer?

    init(ctx: MetalContext, model: SettingsModel) {
        terminal = Terminal(delegate: termDelegate,
                            options: TerminalOptions(cols: cols, rows: rows))
        content = ContentRenderer(ctx: ctx)
        items = [
            Item(label: "BRIGHTNESS", get: { model.brightness }, set: { model.brightness = $0 }),
            Item(label: "CONTRAST  ", get: { model.contrast }, set: { model.contrast = $0 }),
            Item(label: "GLOW      ", get: { model.bloom }, set: { model.bloom = $0 }),
            Item(label: "NOISE     ", get: { model.staticNoise }, set: { model.staticNoise = $0 }),
            Item(label: "CURVATURE ", get: { model.curvature }, set: { model.curvature = $0 }),
            Item(label: "AMBIENT   ", get: { model.ambientLight }, set: { model.ambientLight = $0 }),
        ]
    }

    func show() {
        visible = true
        selected = 0
        touch()
        redraw()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.visible, CACurrentMediaTime() - self.lastInteraction > 5.0 {
                self.hide()
                self.onAutoHide?()
            }
            if !self.visible {
                t.invalidate()
                self.hideTimer = nil
            }
        }
    }

    func hide() {
        visible = false
    }

    private func touch() { lastInteraction = CACurrentMediaTime() }

    /// 键盘路由(OSDKeyView 转发)。返回 true = 已消费
    func handleKey(_ event: NSEvent) -> Bool {
        guard visible else { return false }
        touch()
        switch event.keyCode {
        case 126: selected = (selected + items.count - 1) % items.count   // ↑
        case 125: selected = (selected + 1) % items.count                 // ↓
        case 123: adjust(-1.0 / Double(barSteps))                         // ←(一格一档)
        case 124: adjust(+1.0 / Double(barSteps))                         // →
        case 53, 36:                                                      // Esc / Return
            hide()
            onAutoHide?()
            return true
        default:
            return true   // 其它键吞掉(OSD 在场不往 shell 漏)
        }
        redraw()
        return true
    }

    private func adjust(_ delta: Double) {
        let item = items[selected]
        item.set(min(1, max(0, item.get() + delta)))
    }

    /// 整幅重 feed(34×12 小画布,全量重画零成本;选中行 ANSI 反显)
    private func redraw() {
        var s = "\u{1b}[2J\u{1b}[H"
        let top = "┌" + String(repeating: "─", count: cols - 2) + "┐"
        let bottom = "└" + String(repeating: "─", count: cols - 2) + "┘"
        func boxLine(_ inner: String, invert: Bool = false) -> String {
            // 手排宽度:标签+条形图均 ASCII/半角制表符,逐字符数列
            let pad = max(0, cols - 2 - inner.count)
            let body = inner + String(repeating: " ", count: pad)
            return "│" + (invert ? "\u{1b}[7m\(body)\u{1b}[27m" : body) + "│\r\n"
        }
        s += top + "\r\n"
        s += boxLine("            YETERM  OSD")
        s += boxLine("")
        // 值条用纯 ASCII(# 实 / - 虚):▓░ 是 East Asian ambiguous 宽度,
        // SwiftTerm 判宽格会把画布撑爆(右框跑丢+反显折行,首版实测)
        for (i, item) in items.enumerated() {
            let filled = Int((item.get() * Double(barSteps)).rounded())
            let bar = "[" + String(repeating: "#", count: filled)
                + String(repeating: "-", count: barSteps - filled) + "]"
            s += boxLine(" \(item.label)  \(bar)", invert: i == selected)
        }
        s += boxLine("")
        s += boxLine(" UP/DN SELECT   < > ADJUST   ESC")
        s += bottom
        terminal.feed(text: s)
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }
}

/// 隐形键盘捕手:OSD 在场时抢 firstResponder,方向键不进 shell
final class OSDKeyView: NSView {
    weak var osd: OSDController?
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if osd?.handleKey(event) != true {
            onDismiss?()
        }
    }
}
