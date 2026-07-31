// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 荧光搜索条(⌘F,v1.1 #4)
//
// 这个文件:浮在窗口右上角的搜索条,纯 AppKit 手搭(黑底+主题荧光色描边,
//   刻意做成"CRT 附属仪表"的观感,而不是系统白色搜索框)。
// 它只管"长相和输入",真正的查找逻辑在 TerminalWindowController(通过三个
//   回调闭包上报:文字变了/按了回车/要关闭)—— 和 TerminalPane 一样的
//   "闭包解耦"套路:视图不知道谁在用它,谁用谁接回调(类比 React 组件
//   只发 onChange/onSubmit 事件,业务逻辑在父组件)。
//
// 语法看点:
//   NSTextFieldDelegate 的 `control(_:textView:doCommandBy:)` —— AppKit 把
//     输入框里的"命令键"(回车/Esc/上下箭头)先问代理:你要拦吗?
//     我们拦回车(搜索)和 Esc(关闭),其余放行 —— 类比 Web 里
//     input 的 keydown 拦截 preventDefault。
//   `lazy var` —— 首次访问才构造(此处用于互相引用的子视图初始化顺序)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// 悬停显示小手光标的按钮(搜索条 ◂/▸/✕ 用,用户点名"能点的要像能点的")。
/// 【学】AppKit 的光标不是按钮属性,而是"光标矩形"机制:窗口需要刷新光标时
///      会回调每个视图的 resetCursorRects,你在里面登记"这块区域用这个光标";
///      视图移动/改尺寸后系统自动重问 —— 类比 CSS 的 cursor: pointer,
///      只是要用回调声明区域而不是写一条样式。
private final class HandCursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 荧光搜索条:⌘F 唤出。回车 = 查找上一条(向历史方向,终端习惯,与 iTerm2 一致);
/// ⇧回车 = 反向;Esc = 关闭。计数样式 "2/14"。配色跟随当前主题的荧光色。
final class SearchBarView: NSView, NSTextFieldDelegate {
    /// 回调:文字增量变化(每敲一个字符搜一次)
    var onChange: ((String) -> Void)?
    /// 回调:提交搜索(词, 是否向历史方向 = 回车默认)
    var onSubmit: ((String, Bool) -> Void)?
    /// 回调:请求关闭(Esc / ✕)
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private var accent = NSColor(red: 0, green: 0.84, blue: 0.43, alpha: 1)   // 兜底荧光绿

    var term: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = L("查找…")
        field.delegate = self
        field.lineBreakMode = .byTruncatingHead

        counter.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        counter.alignment = .right

        func glyphButton(_ symbol: String, _ action: Selector) -> NSButton {
            let b = HandCursorButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                                     target: self, action: action)
            b.isBordered = false
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let prev = glyphButton("chevron.up", #selector(prevTapped))     // 向历史(旧)方向
        let next = glyphButton("chevron.down", #selector(nextTapped))   // 向新方向
        let close = glyphButton("xmark", #selector(closeTapped))
        buttons = [prev, next, close]

        // 手排布局(见 layout()):曾用 NSStackView,其 gravity/distribution 语义
        // 在无约束宿主里排不出"输入框吃满剩余宽"的效果 —— 与项目其余 AppKit
        // 视图统一改手排,几何完全可控
        [field, counter, prev, next, close].forEach(addSubview)

        applyAccent()
    }

    /// 手排:右侧固定宽的 计数|◂|▸|✕,左侧输入框吃满剩余
    override func layout() {
        super.layout()
        let h = bounds.height
        var x = bounds.maxX - 8
        for b in buttons.reversed() {          // close → next → prev 从右往左摆
            x -= 20
            b.frame = NSRect(x: x, y: (h - 20) / 2, width: 20, height: 20)
            x -= 5
        }
        x -= 52
        counter.frame = NSRect(x: x, y: (h - 15) / 2, width: 52, height: 15)
        field.frame = NSRect(x: 10, y: (h - 17) / 2, width: max(x - 18, 40), height: 17)
    }

    private var buttons: [NSButton] = []

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    /// 主题荧光色注入(打开时由窗口控制器按当前配置刷新)
    func setAccent(red: CGFloat, green: CGFloat, blue: CGFloat) {
        accent = NSColor(red: red, green: green, blue: blue, alpha: 1)
        applyAccent()
    }

    private func applyAccent() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.65).cgColor
        field.textColor = accent
        counter.textColor = accent.withAlphaComponent(0.6)
        for b in buttons { b.contentTintColor = accent }
        // 输入光标也染成荧光色(field editor 是窗口共享的,聚焦后才拿得到)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = accent
        }
    }

    /// 计数显示:“2/14”;无匹配时红色提示
    func updateCounter(index: Int, total: Int) {
        counter.stringValue = total > 0 ? "\(index)/\(total)" : (term.isEmpty ? "" : "0")
        counter.textColor = (total == 0 && !term.isEmpty)
            ? NSColor(red: 1, green: 0.35, blue: 0.3, alpha: 0.9)
            : accent.withAlphaComponent(0.6)
    }

    func focusField(in window: NSWindow?) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = accent
        }
    }

    // MARK: - 事件

    @objc private func prevTapped() { onSubmit?(term, true) }
    @objc private func nextTapped() { onSubmit?(term, false) }
    @objc private func closeTapped() { onClose?() }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(term)
    }

    /// 拦截输入框的命令键:回车=搜索(⇧反向),Esc=关闭,其余交回系统
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onSubmit?(term, !shift)   // 回车向历史方向;⇧回车反向
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
