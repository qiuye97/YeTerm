// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 我们对 SwiftTerm 终端视图的"改装层"(阅读顺序第 6 站)
//
// 这个文件:继承第三方库 SwiftTerm 的 LocalProcessTerminalView,加了四样改装:
//   1. 把"内容变了"的通知转成闭包回调(onRangeChanged → 通知渲染层重画);
//   2. suppressNativeDrawing:拦掉它自己的画字逻辑(画面由我们的 CRT 层出);
//   3. IME(输入法)三个方法插桩:拼音组合/上屏的瞬间同步通知渲染层;
//   4. 用"反射"读它藏起来的选区坐标(库没公开,只能这么拿)。
// 类比 Java:继承一个框架类,override 几个钩子方法 + 用反射摸私有字段——
//   思路完全一样,只是 Swift 的反射(Mirror)是只读的、更受限。
//
// 语法看点:
//   `override func` —— 重写父类方法;先调 super 保留原逻辑再加自己的。
//   `Mirror(reflecting: obj)` —— Swift 反射:枚举对象的属性名和值
//     (类比 Java 的 getDeclaredFields);`as? Position` 是"安全转型",
//     失败返回 nil 而不是抛异常(类比 instanceof + cast 的合体)。
//   元组返回值 `(start: Position, end: Position)?` —— 轻量多返回值,
//     不用专门定义小类(Java 得写个 record)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import SwiftTerm

/// 事件驱动终端视图(M1a-1):
/// LocalProcessTerminalView 的官方扩展点子类 —— `rangeChanged` 是它预留的空实现,
/// 配合 `notifyUpdateChanges = true`,SwiftTerm 会在**内容变更**与**纯光标移动**时
/// (经其内部 ~60fps 节流合并、同步输出期间自动静默)回调这里。
/// 这与 cool-retro-term 的场景图事件驱动同构:内核说变了才渲染,不轮询。
final class EventTerminalView: LocalProcessTerminalView {
    /// 内容/光标变更(startY, endY 为视口行号,纯光标移动时两者相等)
    var onRangeChanged: ((Int, Int) -> Void)?
    /// 滚动回看位置变化(0~1)
    var onScrolled: ((Double) -> Void)?

    /// 抑制原生 CoreText 渲染:渲染由 overlay 全权接管后,底层自绘纯属浪费。
    /// 两层拦截缺一不可(v1.1.1 用户同事 M1 实测勘差):
    ///   ① 拦 setNeedsDisplay —— 挡住**后续**重绘请求(省 CPU);
    ///   ② 隐藏 layer —— 窗口首次显示的强制绘制不经 ①,慢机器上 CRT 首帧
    ///     (着色器运行时编译几百 ms)之前原生画面会闪现"露馅";SwiftTerm 的
    ///     draw 是 public 非 open 不可跨模块覆写,改为把**绘制层**整个藏掉:
    ///     不上屏,但视图在 AppKit 逻辑里仍"可见" —— 键盘焦点/IME 候选框
    ///     定位/caret 几何全不受影响(isHidden 则会丢 firstResponder,不可用)。
    /// 【学】NSView(逻辑:事件/焦点/几何)与 CALayer(显示:像素上屏)是两层,
    ///      layer.isHidden 只关"显示",这是"隐形输入宿主"能成立的根据。
    // ---- 提示符热切换握手(v1.3):集成脚本启动时发 OSC 7777 上报"已装
    // TRAPUSR1"。zsh 对未 trap 的 USR1 默认直接退出 —— 只对握过手的会话发信号
    private(set) var promptHotswapReady = false

    func installPromptReadyHandler() {
        getTerminal().registerOscHandler(code: 7777) { [weak self] data in
            // 只认 v2 标记(v14 起换 PTY 按键注入促发;旧脚本没有 991~ 绑定,
            // 注入会变乱码字符 —— 旧标记一律不认,旧会话自然退化为 precmd 保底)
            if String(bytes: data, encoding: .utf8) == "prompt-ready-2" {
                self?.promptHotswapReady = true
            }
        }
    }

    var suppressNativeDrawing = false {
        didSet {
            wantsLayer = true
            layer?.isHidden = suppressNativeDrawing
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if suppressNativeDrawing { return }
        super.setNeedsDisplay(invalidRect)
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        onRangeChanged?(startY, endY)
    }

    // MARK: - 波特率限速(v1.4)

    /// 字节限速器。`bitsPerSecond = 0`(缺省)时 `enqueue` 直接透传,与改动前
    /// 完全同一条路径 —— 不开限速零成本、零行为差异。
    /// 【学】`lazy var` = 第一次用到才初始化(此处必须惰性:闭包要捕获 self,
    ///      而 self 在属性初始化阶段还不可用)。类比 Java 的双检锁懒加载,
    ///      但 Swift 帮你写好了(非线程安全版,主线程独占正合适)。
    private lazy var rateLimiter = ByteRateLimiter { [weak self] slice in
        self?.deliverToKernel(slice)
    }

    /// 波特率(bps);0 = 不限速。改小/改大即时生效,切到 0 会把积压立刻吐完。
    var outputBitRate: Int {
        get { rateLimiter.bitsPerSecond }
        set { rateLimiter.bitsPerSecond = newValue }
    }

    /// 待吐字节数(自测断言用)
    var pendingOutputBytes: Int { rateLimiter.backlogCount }

    /// 真正交给 SwiftTerm 内核 —— 闭包里不能写 `super`,故绕一层实例方法
    private func deliverToKernel(_ slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        rateLimiter.enqueue(slice)
    }

    /// 用户按 ⌃C(0x03)/ ⌃\(0x1C)时立刻吐完积压。
    ///
    /// 为什么这**不是**作弊:真 300 波特线路上根本不存在积压 —— 慢的是线路,
    /// 写不进去的程序**自己阻塞在 write 上**。我们之所以会有积压,是因为
    /// SwiftTerm 已经把 PTY 抽干了(它的背压 `enqueueReceivedData`/high-water
    /// 不对外开放),积压纯属我们的实现产物。按下"别说了"那两个键把它清掉,
    /// 比留着几秒钟的陈旧输出**更**接近真实。
    ///
    /// 钩在 `send` 而不是 `keyDown`:①`keyDown` 在上游是 public 非 open,
    /// 跨模块覆写不了(与本文件开头 `draw()` 同一个坎);②`send` 是所有输入的
    /// 总出口,键盘/粘贴/程序化发送一网打尽。
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if rateLimiter.backlogCount > 0, data.contains(where: { $0 == 0x03 || $0 == 0x1C }) {
            rateLimiter.flush()
        }
        super.send(source: source, data: data)
    }

    /// 终端 bell(\a)回调(v1.2 #5):上抛给窗口做 CRT 荧光闪屏/后台通知。
    /// 不调 super —— 上游默认 NSSound.beep,复古终端的响铃由我们自己演绎
    var onBell: (() -> Void)?

    override func bell(source: Terminal) {
        onBell?()
    }

    // MARK: - 粘贴保护(v1.2 #6)

    /// 多行粘贴须确认(防止误贴一大段直接逐行执行);单行直通
    var pasteProtectionEnabled = true
    /// 需要确认时上抛(参数=完整剪贴板文本;窗口弹荧光确认框)
    var onPasteConfirmation: ((String) -> Void)?
    private var bypassPasteGuard = false

    override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if pasteProtectionEnabled, !bypassPasteGuard,
           text.rangeOfCharacter(from: .newlines) != nil,
           let confirm = onPasteConfirmation {
            confirm(text)
            return
        }
        super.paste(sender)   // 原始路径:bracketed paste 等语义全由上游处理
    }

    /// 确认后的真粘贴:临时旁路保护再走原始路径(不自己发文本,语义零分叉)
    func performConfirmedPaste() {
        bypassPasteGuard = true
        paste(self)
        bypassPasteGuard = false
    }

    override func scrolled(source: TerminalView, position: Double) {
        onScrolled?(position)
    }

    // MARK: - IME 预编辑(事件推送)

    /// marked text 生命周期回调:组合更新/提交/取消的**同一事件内**同步触发 ——
    /// 曾靠渲染帧轮询比对,提交(按数字选字)到下一帧之间拼音会与上屏中文短暂重叠;
    /// 推送后提交瞬间即清,重叠归零。
    var onMarkedTextChanged: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onMarkedTextChanged?()   // 提交那一刻:拼音必须立即消失
    }

    // MARK: - 选区(高亮渲染用)

    /// 选区变化(拖选每一步、双击选词、清除都会触发)
    var onSelectionChanged: (() -> Void)?

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        onSelectionChanged?()
    }

    // MARK: - ⌘点击链接(v1.1 #5)

    /// 打开链接拦截钩子:nil 时走 SwiftTerm 默认(NSWorkspace.open 真打开);
    /// 自测注入闭包拦截断言(auto-drive 场景 8),不然测试会真弹浏览器。
    var onOpenLink: ((String) -> Void)?

    /// 文件路径打开测试钩子(v1.2 #9;auto-drive 拦截,不真开 Finder)
    var onOpenFilePath: ((String, Int?) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let hook = onOpenLink {
            hook(link)
            return
        }
        // ⌘点击文件路径(v1.2 #9):上游隐式识别已覆盖 ./ ~/ /abs 与含点文件名,
        // 这里接住"非 URL"的命中 —— 存在的路径按文件/目录分流打开;不存在放行给上游
        if openAsFilePath(link) {
            return
        }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// 路径打开:剥 `:行号(:列号)`(编译报错格式)→ 展开 ~/相对路径(以本 shell
    /// 当前目录为基准)→ 存在才处理:目录进 Finder,文件交默认 app(日志→编辑器、
    /// 图片→预览,跟双击一致)。返回 false = 不是可打开的路径,继续走 URL 链路。
    private func openAsFilePath(_ raw: String) -> Bool {
        guard !raw.contains("://"), !raw.hasPrefix("mailto:") else { return false }
        var path = raw
        var line: Int?
        if let m = path.range(of: #"(:\d+){1,2}$"#, options: .regularExpression) {
            line = path[m].split(separator: ":").compactMap { Int($0) }.first
            path = String(path[..<m.lowerBound])
        }
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            let base = SessionStore.cwdOf(pid: process.shellPid) ?? NSHomeDirectory()
            expanded = base + "/" + expanded
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return false
        }
        if let hook = onOpenFilePath {
            hook(expanded, line)
            return true
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded, isDirectory: isDir.boolValue))
        return true
    }

    /// ⌘悬停链接高亮范围快照(buffer 绝对行 + 列区间)。
    /// 数据源 = MacTerminalView 的 internal 属性 `linkHighlightRange`
    /// ([Terminal.LinkMatch.RowRange]),与 selectionSnapshot 同款 Mirror 挖法;
    /// 哨兵 = auto-drive 场景 8(⌘点击后断言快照非空,上游布局变了立刻红)。
    var linkHighlightSnapshot: [(row: Int, range: Range<Int>)]? {
        var mirror: Mirror? = Mirror(reflecting: self)
        var raw: Any?
        while let m = mirror, raw == nil {
            for child in m.children where child.label == "linkHighlightRange" {
                raw = Self.unwrapOptional(child.value)
            }
            mirror = m.superclassMirror
        }
        guard let raw else { return nil }
        var out: [(row: Int, range: Range<Int>)] = []
        for element in Mirror(reflecting: raw).children {
            var row: Int?
            var range: Range<Int>?
            for f in Mirror(reflecting: element.value).children {
                if f.label == "row" { row = f.value as? Int }
                if f.label == "range" { range = f.value as? Range<Int> }
            }
            if let r = row, let g = range { out.append((row: r, range: g)) }
        }
        return out.isEmpty ? nil : out
    }

    /// 选区起止坐标(缓冲区绝对行,未排序 —— 语义同上游 SelectionService.start/end)。
    /// SwiftTerm 只公开 selectionActive/getSelection(),坐标是 internal,
    /// 用 Mirror 反射读取;依赖已钉死 exact 1.15.0,属性布局稳定。
    var selectionSnapshot: (start: Position, end: Position)? {
        guard selectionActive else { return nil }
        // 沿继承链找 internal 存储属性 `selection`(声明在 MacTerminalView 层)
        var mirror: Mirror? = Mirror(reflecting: self)
        var service: Any?
        while let m = mirror, service == nil {
            for child in m.children where child.label == "selection" {
                service = Self.unwrapOptional(child.value)
            }
            mirror = m.superclassMirror
        }
        guard let service else { return nil }
        var start: Position?
        var end: Position?
        for child in Mirror(reflecting: service).children {
            if child.label == "start" { start = child.value as? Position }
            if child.label == "end" { end = child.value as? Position }
        }
        guard let s = start, let e = end else { return nil }
        return (s, e)
    }

    private static func unwrapOptional(_ any: Any) -> Any? {
        let m = Mirror(reflecting: any)
        guard m.displayStyle == .optional else { return any }
        return m.children.first?.value
    }
}
