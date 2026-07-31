// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 一个分屏格子(阅读顺序第 5 站)
//
// 这个文件:一个"格子" = 一个独立的 shell 会话。里面装着 EventTerminalView
//   (SwiftTerm 的终端视图,负责跑 /bin/zsh、解析输出、接键盘/输入法)。
//   注意它**不负责画画**——渲染统一归窗口级 overlay(见上一站导读)。
// 类比后端:一个 pane ≈ 一个独立的会话进程 + 它的输入通道;多个 pane 就是
//   同窗口里的多个并行会话。
//
// 语法看点:
//   `: NSView, LocalProcessTerminalViewDelegate` —— 继承 NSView 同时实现
//     一个"委托协议"(protocol ≈ Java 的 interface);SwiftTerm 在 shell
//     退出/标题变化时回调下面那几个 func —— 又是委托模式。
//   `var onTerminated: ((TerminalPane) -> Void)?` —— 存一个"回调函数"的
//     属性(闭包类型,类比 Java 的 Consumer<TerminalPane> 字段):
//     谁关心这事(窗口控制器)就把处理函数塞进来,解耦父子组件,
//     和前端"子组件 emit 事件、父组件传 handler"一个思路。
//   `kill(pid, SIGHUP)` —— 直接调 C 函数发 Unix 信号(Swift 能无缝调 C);
//     SIGHUP=“终端挂断”,交互式 zsh 会自我保护忽略 SIGTERM,只认这个。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import CoreText
import SwiftTerm

/// 终端 Pane(M2 分屏单元):EventTerminalView 的自包含装配,可作为叶子嵌进
/// NSSplitView 树。每个 pane = 独立 shell 会话;**渲染由窗口级 overlay 统一合成**
/// (一个窗口 = 一台"显示器",用户裁决),pane 自身不再持有 CRT 管线。
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    let terminalView: EventTerminalView

    var onTerminated: ((TerminalPane) -> Void)?
    var onTitle: ((TerminalPane, String) -> Void)?

    init(options: LaunchOptions, cwd: String? = nil) {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 320)
        terminalView = TermHost.makeShellView(frame: rect, options: options, cwd: cwd)
        super.init(frame: rect)

        terminalView.autoresizingMask = []   // 布局由 layout() 管理(分屏内边距)
        terminalView.frame = bounds
        terminalView.processDelegate = self
        addSubview(terminalView)
        needsLayout = true
        // 渲染由窗口 overlay 全权接管,拦截底层 CoreText 重绘(每键一次行重绘的纯浪费)
        terminalView.suppressNativeDrawing = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    /// 分屏内边距:多 pane 时让字符与荧光分割线之间有留白(单 pane 时为 0,
    /// 外围留白由窗口级 margin 提供)。由窗口控制器在树变化时设置。
    var contentInset: CGFloat = 0 {
        didSet { if contentInset != oldValue { needsLayout = true } }
    }

    override func layout() {
        super.layout()
        let inset = min(contentInset, min(bounds.width, bounds.height) / 4)
        terminalView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    /// 字体/字号/字宽应用(观感 uniforms 由窗口 overlay 统一管)
    func applyFont(_ cfg: CRTConfig, fontSize: CGFloat) {
        guard let name = cfg.resolvedFontName else { return }
        let newFont = TermHost.resolveFont(name: name, size: fontSize,
                                           width: CGFloat(cfg.fontWidth ?? 1))
        let current = terminalView.font
        if current.fontName != newFont.fontName || current.pointSize != newFont.pointSize
            || CTFontGetMatrix(current as CTFont) != CTFontGetMatrix(newFont as CTFont) {
            terminalView.font = newFont
        }
    }

    /// 窗口失焦时终结未提交的 IME 组合(SwiftTerm 上游缺陷的宿主层兜底)
    func finalizeIMESessionIfNeeded() {
        guard terminalView.hasMarkedText() else { return }
        terminalView.inputContext?.discardMarkedText()
        terminalView.unmarkText()
    }

    func shutdown() {
        // 交互式 zsh 忽略 SIGTERM(自我保护)→ 先发 SIGHUP(终端挂断语义,shell 会退出)
        let pid = terminalView.process.shellPid
        if pid > 0 { kill(pid, SIGHUP) }
        terminalView.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(self, title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // 黑匣子:exitCode 是 waitpid 原始 status —— 低 7 位非零 = 被信号杀,
        // 值即信号号(SIGUSR1=30 → 未捕获热切信号的铁证);否则高 8 位是 exit 码
        if let st = exitCode {
            let sig = st & 0x7f
            let decoded = sig != 0 ? "被信号 \(sig) 杀死\(sig == 30 ? "(SIGUSR1!trap 未生效)" : "")"
                                   : "正常退出码 \((st >> 8) & 0xff)"
            ShellIntegration.debugLog("shell pid=\(terminalView.process.shellPid) 终止 status=\(st) → \(decoded)")
        } else {
            ShellIntegration.debugLog("shell pid=\(terminalView.process.shellPid) 终止(IO 错误,无退出码)")
        }
        onTerminated?(self)
    }
}
