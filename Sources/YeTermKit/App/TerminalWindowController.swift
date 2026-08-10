// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 一个终端窗口的"窗口控制器"(阅读顺序第 4 站)
//
// 这个文件:管一个窗口里的一切。AppKit 的分层惯例:
//   NSWindow(窗户本体)→ NSWindowController(管窗户的人)→ contentView(内容)。
//   类比 Web:window 是浏览器标签页,controller 是这个页面的前端框架实例。
//
// 本窗口的视图层级(理解渲染架构的关键!):
//   RootView(留白内缩容器)
//   ├─ splitHost(分屏树的家:一个个 TerminalPane 叶子,NSSplitView 当树枝)
//   └─ MetalOverlayView(★ 全窗唯一的 CRT 特效层,盖在最上面)
//   真实的 SwiftTerm 终端视图在下面"隐形工作"(收键盘/跑 shell 但不画字),
//   画面全部由 overlay 合成:各 pane 的文字纹理 + 荧光分割线 → 一块 CRT 屏。
//   这就是"一个窗口 = 一台显示器"的实现方式。
//
// 语法看点:
//   嵌套 private final class RootView —— 类中类,只给本文件用的小工具类。
//   `override func layout()` —— AppKit 的布局回调,窗口变大小时被调,
//     我们在这里手排子视图(类比前端 resize 事件里改 style)。
//   `[weak self] / [weak ov]` —— 闭包防循环引用(见 AppDelegate 导读)。
//   `panes.first { 条件 }` —— 尾随闭包版的"找第一个满足条件的元素",
//     类比 Java Stream 的 .filter(...).findFirst()。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import SwiftTerm

/// 终端窗口(M2):管理一棵 pane 树 —— 叶子 = TerminalPane,内节点 = NSSplitView。
/// **一个窗口 = 一台"显示器"**(用户裁决):窗口级单一 CRT overlay 把所有 pane
/// 的内容合成进同一块荧光屏,pane 之间用荧光线分割;机壳/弧度/扫描线只有一套。
/// ⌘D 左右分屏 / ⇧⌘D 上下分屏 / ⌘] 轮换焦点;pane 的 shell 退出即从树中收缩移除。
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let options: LaunchOptions

    // MARK: - 窗口内多标签(2026-08-06 用户需求,弃用原生 window tabbing)
    // 原生标签 = 每个标签是独立 NSWindow 由系统聚合,标签栏样式完全不可定制
    // (透明标题栏改造后尤其难看,用户裁决重做)。改为窗口内自管:一个窗口
    // 持有多个 Tab,每个 Tab 一棵分屏树;同一块 CRT 荧光屏轮流显示 —— 标签
    // 切换即"换台",与"一个窗口 = 一台显示器"的既有裁决一脉相承。
    // 【学】嵌套 final class Tab:引用类型才好在数组里原地改字段(struct 是
    //      值语义,取出改再放回,啰嗦且易错)。类比 Java 的普通对象 vs record。
    final class Tab {
        var rootView: NSView?                 // 分屏树根(pane 或 NSSplitView)
        var panes: [TerminalPane] = []
        var title = "YeTerm"                  // shell OSC 报的标题(窗口标题同源)
        var hasActivity = false               // 后台响铃/长命令完成 → 标签栏「·」
        weak var lastFocused: TerminalPane?   // 切走时记住焦点,切回还原
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    private var activeTab: Tab? { tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil }

    /// 全部标签的全部 pane(设置广播/IME 终结/关窗清理都要覆盖后台标签)
    var panes: [TerminalPane] { tabs.flatMap { $0.panes } }
    /// 活动标签的 pane(布局/焦点轮换只看得见这些)
    var activePanes: [TerminalPane] { activeTab?.panes ?? [] }

    private(set) var overlay: MetalOverlayView?
    private var resignKeyObserver: NSObjectProtocol?
    // 标签栏出现/消失时 contentLayoutRect 变高变矮但窗口 frame 不变,不会触发
    // 布局回调 —— KVO 盯着它,变了就重排(文字区顶部让位要跟着标签栏走)
    private var contentLayoutObserver: NSKeyValueObservation?
    private var isPoweringOff = false   // 关机动画进行中(防重复触发;动画放完真正 close)
    private var searchBar: SearchBarView?
    // 搜索目标 pane 在打开搜索时锁定:搜索框抢走 firstResponder 后
    // focusedPane 会回落到 panes.first,多 pane 下会搜错对象(教训:焦点相关
    // 的"当前 xx"在交互开始时就要捕存,不能每次现算)
    private weak var searchTarget: EventTerminalView?
    // ⌘N/⌘T 继承目录(v1.2 #8):首 pane 的出生目录(AppDelegate 从当前 key 窗查来)
    private let initialCwd: String?
    // 会话恢复(v1.2 #2):待应用的分屏比例(树建好后窗口 frame 才定,ratio 要延后设)
    private var pendingSplitRatios: [(sv: NSSplitView, weights: [Double])] = []
    /// 窗口即将关闭(shell 仍活着,cwd 可查)—— AppDelegate 挂快照钩子
    var onAboutToClose: ((TerminalWindowController) -> Void)?

    /// 根容器:留白内缩 pane 树(CSS padding 语义),overlay 铺满全窗
    private final class RootView: NSView {
        var marginInset: CGFloat = 1
        /// 机壳最小带让位(2026-08-10 用户实测「弧度时最下方内容被吃」的根修):
        /// 机壳开启时 shader 把屏幕玻璃**上下各**内缩一条 = 标题栏高的机壳带
        /// (MetalOverlayView.currentScreenInset 的 padding 变换),内容纹理最底下
        /// 那条带**永远不上屏**。顶部一直有 topBar 让位(文字区扣掉标题栏),
        /// 底部 2026-08-07 加带时漏了 —— 文字照排到窗底,最后一行正落在永不
        /// 显示的带里。此开关 = u.frameOn(CRTConfig.frameLayerActive 同源),
        /// 开则底部同样让出 topBar,文字区相对玻璃区上下对称。
        var caseBandActive = false {
            didSet { if caseBandActive != oldValue { needsLayout = true } }
        }
        weak var splitHost: NSView?
        weak var overlayView: NSView?
        weak var searchBarView: NSView?   // 荧光搜索条(overlay 之上,右上角)
        weak var glassBarView: NSView?    // 液态玻璃标签条(无机壳样式)
        /// 机壳区被点击(v1.2 #13 消磁彩蛋:点终端外的边框壳=按了消磁钮)
        var onCaseClick: (() -> Void)?

        // 标签栏让位(2026-08-06 双样式标签栏):reserve = splitHost 顶部额外内缩,
        // crtBarHeight>0 时布局顺手算出盒绘条的命中区(点击选标签用)
        var tabBarReserve: CGFloat = 0
        var crtBarHeight: CGFloat = 0
        private(set) var crtBarRect: CGRect?
        /// 盒绘条被点击(参数 = 条内 x 偏移,控制器换算成列→标签)
        var onTabBarClick: ((CGFloat) -> Void)?
        /// 盒绘条悬浮(2026-08-07:悬浮浮 x/浅底,与玻璃条同构;nil = 移出条外)
        var onTabBarHover: ((CGFloat?) -> Void)?
        private var barTrackingArea: NSTrackingArea?

        // 【学】NSTrackingArea:AppKit 的"鼠标移动订阅"。默认视图只收点击不收
        //      移动,要 mouseMoved 就得挂一块追踪区(类比 Web 的 mousemove 监听)。
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = barTrackingArea { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            barTrackingArea = t
        }

        override func mouseMoved(with event: NSEvent) {
            let p = contentPoint(event)
            if let r = crtBarRect, r.contains(p) {
                onTabBarHover?(p.x - r.minX)
            } else {
                onTabBarHover?(nil)
            }
            super.mouseMoved(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            onTabBarHover?(nil)
            super.mouseExited(with: event)
        }

        /// 命中用坐标:过 CRT 弧度/内缩映射(2026-08-07 修正 —— 标签条画在内容
        /// 纹理里,屏面点击点必须换算回纹理坐标才能对上;无弧度无机壳时恒等)
        private func contentPoint(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            return (overlayView as? MetalOverlayView)?.contentPoint(fromViewPoint: p) ?? p
        }

        override func mouseDown(with event: NSEvent) {
            let p = contentPoint(event)
            if ProcessInfo.processInfo.environment["YETERM_DEBUG_HIT"] != nil {
                let raw = convert(event.locationInWindow, from: nil)
                FileHandle.standardError.write(Data(
                    "[hit] raw=\(raw) mapped=\(p) bar=\(String(describing: crtBarRect)) split=\(String(describing: splitHost?.frame)) bounds=\(bounds)\n".utf8))
            }
            // 盒绘标签条优先(它画在机壳带里,不让位给消磁)
            if let r = crtBarRect, r.contains(p) {
                onTabBarClick?(p.x - r.minX)
                return
            }
            // margin 内缩区 = 机壳带;splitHost(终端区)内的点击不归这里
            if let host = splitHost, !host.frame.contains(p), bounds.contains(p) {
                onCaseClick?()
                return
            }
            super.mouseDown(with: event)
        }

        override func layout() {
            super.layout()
            let inset = min(marginInset, min(bounds.width, bounds.height) / 4)
            // 标题栏(红绿灯条)高度(2026-08-06 用户需求:画面延伸到窗顶):窗口是
            // fullSizeContentView,本视图铺满整窗含标题栏区;contentLayoutRect 是
            // AppKit 扣掉标题栏后的"安全区"。文字区(splitHost)顶部额外
            // 让出这一条 —— 文字落点与改造前完全一致;机壳/背景(overlay)则照铺
            // 到窗顶,透出到透明标题栏下面。
            let topBar = max(0, bounds.height - (window?.contentLayoutRect.height ?? bounds.height))
            // 机壳带高 = 标题栏高(与 shader 的 screenInset 同一来源 contentLayoutRect;
            // 全屏无标题栏 → 0,机壳关 → 0,两处天然一致)
            let bottomBand = caseBandActive ? topBar : 0
            // 多标签时标签栏再让一条(tabBarReserve;单标签为 0):
            //   盒绘条:标题栏 → margin → 盒绘条 → 文字;玻璃条:标题栏 → 玻璃条 → margin → 文字
            let newSplitFrame = NSRect(x: inset, y: inset + bottomBand,
                                       width: bounds.width - inset * 2,
                                       height: bounds.height - inset * 2 - topBar - bottomBand - tabBarReserve)
            // 终端区挪位后必须重捕获(2026-08-07 重影修复配套):布局跑在捕获之后
            // 的话,合成画面还钉着旧落点 —— 文字画在挪位前的位置上
            if splitHost?.frame != newSplitFrame {
                splitHost?.frame = newSplitFrame
                (overlayView as? MetalOverlayView)?.scheduleCapture()
            }
            crtBarRect = crtBarHeight > 0
                ? NSRect(x: inset, y: bounds.height - topBar - inset - crtBarHeight,
                         width: bounds.width - inset * 2, height: crtBarHeight)
                : nil
            if let bar = glassBarView, !bar.isHidden {
                bar.frame = NSRect(x: 12, y: bounds.height - topBar - 6 - GlassTabBar.height,
                                   width: bounds.width - 24, height: GlassTabBar.height)
            }
            overlayView?.frame = bounds
            if let bar = searchBarView {
                let w: CGFloat = min(330, bounds.width - 24)
                bar.frame = NSRect(x: bounds.maxX - w - 14,
                                   y: bounds.maxY - topBar - tabBarReserve - 34 - 12,
                                   width: w, height: 34)
            }
        }
    }

    private let root = RootView()
    private let splitHost = NSView()

    private static func inset(forMargin m: Double?) -> CGFloat {
        CGFloat(1.0 + 39.0 * min(max(m ?? 0.5, 0), 1))
    }

    init(options: LaunchOptions, restoreState: SessionState.WindowState? = nil,
         playBootScreen: Bool = false, initialCwd: String? = nil) {
        self.options = options
        self.initialCwd = initialCwd
        let rect = NSRect(x: 0, y: 0, width: 960, height: 600)
        // fullSizeContentView + 透明标题栏(2026-08-06 用户需求):内容视图铺满
        // 整窗含标题栏区,CRT 机壳/背景色/背景图一直画到窗顶,红绿灯悬浮在画面
        // 上(有机壳=壳延伸到红绿灯下;无机壳=红绿灯条即背景色,浑然一体)。
        // 文字区不受影响 —— RootView.layout 按 contentLayoutRect 给顶部让位。
        // 【学】styleMask 是窗口的"外观开关集合",fullSizeContentView 表示内容
        //      延伸到标题栏下面(类比 Web 的沉浸式全出血布局 + 悬浮导航条)。
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "YeTerm"
        window.titlebarAppearsTransparent = true
        // 窗口底色纯黑:CRT 首帧就绪前(慢机器上着色器编译几百 ms)的空窗期
        // 显示为"未通电的显像管",与开机动画无缝衔接,杜绝原生画面/白底闪现
        window.backgroundColor = .black
        window.center()
        super.init(window: window)
        window.delegate = self

        root.frame = window.contentView?.bounds ?? rect
        root.autoresizingMask = [.width, .height]
        // margin 按模式分支(v1.2 实测勘差:init 路径也必须适配普通模式,
        // 否则启动即普通模式时会顶着 CRT 大留白直到首次设置广播才恢复)
        root.marginInset = (options.config?.crtEffectsEnabled ?? true)
            ? Self.inset(forMargin: options.config?.margin) : 8
        root.caseBandActive = (options.config ?? CRTConfig()).frameLayerActive
        // 消磁彩蛋(v1.2 #13):点机壳边框 = 按消磁钮(overlay hitTest=nil,点击落到 root)
        root.onCaseClick = { [weak self] in self?.overlay?.playDegauss() }
        window.contentView?.addSubview(root)
        root.splitHost = splitHost
        root.addSubview(splitHost)

        if let ov = MetalOverlayView.make() {
            overlay = ov
            root.overlayView = ov
            root.addSubview(ov, positioned: .above, relativeTo: splitHost)
            if let cfg = options.config {
                cfg.apply(to: &ov.uniforms)
                ov.cursorBlinks = cfg.blinkingCursor ?? true
                ov.dividerStyle = cfg.dividerStyle ?? 0
            }
            ov.cursorStyle = options.cursorStyle
            ov.powerAnimationEnabled = (options.config?.powerOnEffect ?? true)
                && (options.config?.crtEffectsEnabled ?? true)   // 总开关关=无开机动画
            ov.powerSpeedFactor = CRTConfig.powerSpeedFactor(options.config?.powerOnSpeed)
            ov.preferredRate = options.config?.refreshRate ?? 60
            ov.animateInBackground = options.config?.animateInBackground ?? true
            ov.focusedViewProvider = { [weak self] in self?.focusedPane?.terminalView }
            ov.layoutProvider = { [weak self] in self?.currentLayout() ?? (panes: [], dividers: []) }
            // CRT 盒绘标签条的落点(布局时算好存在 root 上;nil = 不显示)
            ov.tabStripFrameProvider = { [weak self] in self?.root.crtBarRect }
            ov.start()
            ov.playPowerOn()   // 显像管开机动画(v1.1;设置可关,关闭时此调用为空操作)
        } else {
            FileHandle.standardError.write(Data("Metal 不可用,以原生渲染运行\n".utf8))
        }

        // 会话恢复(v1.2 #2;2026-08-06 起支持多标签存档):有存档按树重建
        // (pane 带 cwd),否则默认单标签单 pane。后台标签的树先不进视图层级
        // (shell 照常跑),切到时再挂 —— 见 selectTab。
        let tabLayouts: [SessionState.LayoutNode?]
        if let st = restoreState {
            tabLayouts = (st.tabs?.isEmpty == false) ? st.tabs! : [st.layout]
        } else {
            tabLayouts = [nil]
        }
        for layout in tabLayouts {
            let tab = Tab()
            tabs.append(tab)
            let tree: NSView = layout.map { buildTree($0, into: tab) }
                ?? makePane(cwd: initialCwd, into: tab)   // ⌘N/⌘T 继承目录(v1.2 #8)
            tree.autoresizingMask = [.width, .height]
            tab.rootView = tree
        }
        activeTabIndex = min(max(restoreState?.activeTab ?? 0, 0), tabs.count - 1)
        if let tree = activeTab?.rootView {
            tree.frame = splitHost.bounds
            splitHost.addSubview(tree)
        }
        updatePaneInsets()
        root.needsLayout = true
        window.makeFirstResponder(activePanes.first?.terminalView)

        // 开机自检(v1.2 #10):仅 app 首窗(AppDelegate 决定;探针不传 = 免疫)。
        // 必须在 pane 建成后启动(取真实 cols/rows)
        if playBootScreen, let ov = overlay {
            let t = activePanes.first?.terminalView.getTerminal()
            ov.startBootScreen(cols: t?.cols ?? 80, rows: t?.rows ?? 24)
        }

        // CRT/普通模式适配(v1.2 实测勘差):init 路径同样要设调色板覆盖等,
        // 不能等首次设置广播 —— 启动即普通模式时内容纹理会顶着 CRT 黑底
        if let cfg = options.config {
            applyCRTMode(cfg)
        }

        if overlay == nil {
            panes.forEach { $0.terminalView.suppressNativeDrawing = false }
        }
        if let op = options.config?.windowOpacity {
            applyWindowOpacity(op)
        }

        // 【学】KVO(Key-Value Observing)= AppKit 世代的属性监听,类比 Vue 的
        //      watch;observe 返回的凭据对象释放时自动解除监听,存成属性保活。
        contentLayoutObserver = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            self?.root.needsLayout = true
        }

        // 窗口失去 key 时终结未提交的 IME 组合(防输入法粘连,M0 事故的教训)
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.panes.forEach { $0.finalizeIMESessionIfNeeded() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    deinit {
        if let o = resignKeyObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - overlay 几何供给

    /// 各 pane 及分割线在 overlay 坐标系(AppKit y-up)的位置。
    /// ⚠️ 只数 **activePanes**(2026-08-07 重影事故):多标签后 `panes` = 全部标签
    /// 的 pane,后台标签的视图不在窗口层级里,convert 会退化出 (0,·) 的垃圾矩形,
    /// 整幅后台画面被叠画在活动画面上 —— 用户实测的"切标签重影/打字被盖住"
    /// 全由这一处引起(probe-windows 的 draws 取证钉死)。
    private func currentLayout() -> (panes: [(view: EventTerminalView, rect: CGRect)], dividers: [CGRect]) {
        guard let ov = overlay else { return ([], []) }
        var paneRects: [(EventTerminalView, CGRect)] = []
        for p in activePanes {
            paneRects.append((p.terminalView, p.terminalView.convert(p.terminalView.bounds, to: ov)))
        }
        var dividers: [CGRect] = []
        func walk(_ v: NSView) {
            if let sv = v as? NSSplitView {
                let subs = sv.arrangedSubviews
                for i in 0..<max(subs.count - 1, 0) {
                    let a = subs[i].frame, b = subs[i + 1].frame
                    let r: CGRect
                    if sv.isVertical {
                        r = CGRect(x: a.maxX, y: 0,
                                   width: max(b.minX - a.maxX, 1), height: sv.bounds.height)
                    } else {
                        r = CGRect(x: 0, y: a.maxY,
                                   width: sv.bounds.width, height: max(b.minY - a.maxY, 1))
                    }
                    dividers.append(sv.convert(r, to: ov))
                }
                subs.forEach(walk)
            } else {
                v.subviews.forEach(walk)
            }
        }
        walk(splitHost)
        return (paneRects, dividers)
    }

    // MARK: - Pane 管理

    var focusedPane: TerminalPane? {
        activePanes.first { window?.firstResponder === $0.terminalView } ?? activePanes.first
    }

    /// pane 属于哪个标签(分屏/标题/退出收缩都要先定位归属)
    private func tabOf(_ pane: TerminalPane) -> Tab? {
        tabs.first { $0.panes.contains(where: { $0 === pane }) }
    }

    // 自测通道(--auto-drive / 探针)
    var terminalViewForTesting: EventTerminalView? { focusedPane?.terminalView }
    var overlayForTesting: MetalOverlayView? { overlay }
    var crtTabBarVisibleForTesting: Bool { root.crtBarRect != nil && overlay?.tabStrip != nil }
    var crtTabBarRectForTesting: CGRect? { root.crtBarRect }
    /// 机壳最小带让位取证(2026-08-10「底部内容被机壳吃掉」回归断言用):
    /// 文字区距窗底的间隙 / 机壳带高(=标题栏高)/ 生效的窗级留白 / 机壳是否生效
    var caseBandGeometryForTesting: (bottomGap: CGFloat, bandH: CGFloat,
                                     marginInset: CGFloat, frameOn: Bool) {
        (splitHost.frame.minY,
         max(0, root.bounds.height - (window?.contentLayoutRect.height ?? root.bounds.height)),
         root.marginInset,
         (overlay?.uniforms.frameOn ?? 0) > 0.5)
    }
    var glassTabBarVisibleForTesting: Bool { glassBarHost?.isHidden == false }
    /// 几何取证(2026-08-07 重影排查)
    var tabBarGeometryForTesting: String {
        let pane = activePanes.first.map { $0.terminalView.convert($0.terminalView.bounds, to: overlay!) }
        let font = activePanes.first?.terminalView.font
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let scale = window?.backingScaleFactor ?? 2
        let stripTex = tabStrip?.render(font: font, scale: scale)
        let cell = GlyphAtlas.cellSize(font: font, scale: scale)
        return "rootH=\(root.bounds.height) margin=\(root.marginInset) reserve=\(root.tabBarReserve) "
            + "crtBarH=\(root.crtBarHeight) crtBarRect=\(String(describing: root.crtBarRect)) "
            + "splitHost=\(splitHost.frame) paneRect=\(String(describing: pane)) "
            + "cellPx=\(cell) stripTex=\(stripTex.map { "\($0.width)x\($0.height)" } ?? "nil")"
    }

    private func makePane(cwd: String? = nil, into tab: Tab) -> TerminalPane {
        let pane = TerminalPane(options: options, cwd: cwd)
        pane.onTerminated = { [weak self] p in self?.paneTerminated(p) }
        // 标签标题 = 该标签焦点 pane 的 shell 标题(后台标签也更新,标签栏可见)
        pane.onTitle = { [weak self] p, title in
            guard let self, let tab = self.tabOf(p) else { return }
            let active = (tab === self.activeTab)
            let focusedOfTab = active ? self.focusedPane : (tab.lastFocused ?? tab.panes.first)
            guard focusedOfTab === p else { return }
            tab.title = title.isEmpty ? "YeTerm" : title
            if active { self.window?.title = tab.title }
            self.refreshTabBar()
        }
        tab.panes.append(pane)
        if let ov = overlay {
            ov.attach(pane.terminalView)
            let tv = pane.terminalView
            tv.onRangeChanged = { [weak ov, weak tv] s, e in
                guard let tv else { return }
                ov?.markDirty(view: tv, rows: min(s, e)...max(s, e))
            }
            tv.onScrolled = { [weak ov] _ in ov?.scheduleCapture() }
            tv.onSelectionChanged = { [weak ov] in ov?.noteSelectionChanged() }
            tv.onMarkedTextChanged = { [weak ov] in ov?.refreshPreeditNow() }
        }
        // 通知 + Visual Bell(v1.2 #5)
        pane.terminalView.onBell = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.bellReceived(from: pane)
        }
        // 粘贴保护(v1.2 #6):多行粘贴 → 荧光确认卡
        pane.terminalView.onPasteConfirmation = { [weak self, weak pane] text in
            guard let self, let pane else { return }
            self.showPasteGuard(text: text, for: pane.terminalView)
        }
        pane.terminalView.commandMarks.onCommandFinished = { [weak self, weak pane] mark, duration in
            guard let self, let pane else { return }
            self.commandFinished(in: pane, mark: mark, duration: duration)
        }
        return pane
    }

    // MARK: - 会话记忆(v1.2 #2)

    /// 当前窗口状态快照:frame + 分屏树 + 各 pane cwd(proc 查 shell 进程)
    func snapshotState() -> SessionState.WindowState? {
        guard let w = window else { return nil }
        let f = w.frame
        // 全部标签逐个快照(后台标签的树虽不在视图层级,结构与 shell 都活着)
        let trees = tabs.compactMap { $0.rootView.map(snapshotNode) }
        guard !trees.isEmpty else { return nil }
        let act = min(max(activeTabIndex, 0), trees.count - 1)
        return .init(frame: [f.minX, f.minY, f.width, f.height],
                     layout: trees[act],          // 旧字段 = 活动标签(降级兼容)
                     tabs: trees, activeTab: act)
    }

    private func snapshotNode(_ v: NSView) -> SessionState.LayoutNode {
        if let sv = v as? NSSplitView {
            let weights = sv.arrangedSubviews.map {
                Double(sv.isVertical ? $0.frame.width : $0.frame.height)
            }
            return .split(vertical: sv.isVertical, weights: weights,
                          children: sv.arrangedSubviews.map(snapshotNode))
        }
        if let pane = v as? TerminalPane {
            return .pane(cwd: SessionStore.cwdOf(pid: pane.terminalView.process.shellPid))
        }
        return .pane(cwd: nil)
    }

    /// 按存档树重建 pane/NSSplitView 结构(比例先记账,frame 定型后应用)
    private func buildTree(_ node: SessionState.LayoutNode, into tab: Tab) -> NSView {
        switch node {
        case .pane(let cwd):
            return makePane(cwd: cwd, into: tab)
        case .split(let vertical, let weights, let children):
            let sv = NSSplitView(frame: splitHost.bounds)
            sv.isVertical = vertical
            sv.dividerStyle = .thin
            sv.autoresizingMask = [.width, .height]
            children.forEach { sv.addArrangedSubview(buildTree($0, into: tab)) }
            pendingSplitRatios.append((sv, weights))
            return sv
        }
    }

    /// 恢复分屏比例:必须在窗口 frame 设好、布局跑过之后调(AppDelegate async 调)。
    /// 多标签(v1.6)后台标签的树不在视图层级、量不出宽高 —— 量不出的先留着,
    /// 该标签首次被切到时(mountActiveTab)再补一次
    func applyRestoredRatios() {
        pendingSplitRatios = pendingSplitRatios.filter { (sv, weights) in
            let total = Double(sv.isVertical ? sv.bounds.width : sv.bounds.height)
            let sum = weights.reduce(0, +)
            guard sum > 0 else { return false }        // 权重坏档,丢弃
            guard sv.window != nil, total > 0 else { return true }   // 还没上屏,留到切入时
            var acc = 0.0
            for i in 0..<max(0, sv.arrangedSubviews.count - 1) {
                let w = i < weights.count ? weights[i] : total / Double(sv.arrangedSubviews.count)
                acc += w / sum * total
                sv.setPosition(acc, ofDividerAt: i)
            }
            return false
        }
        overlay?.scheduleCapture()
    }

    /// 分屏 → Split(⌘D 左右 / ⇧⌘D 上下)
    @objc func splitRightAction(_ sender: Any?) { split(vertical: true) }
    @objc func splitDownAction(_ sender: Any?) { split(vertical: false) }

    /// 分屏 → 下一个分屏(⌘])
    @objc func focusNextPaneAction(_ sender: Any?) {
        let list = activePanes
        guard list.count > 1, let cur = focusedPane,
              let i = list.firstIndex(where: { $0 === cur }) else { return }
        let next = list[(i + 1) % list.count]
        window?.makeFirstResponder(next.terminalView)
        overlay?.scheduleRepaint()
    }

    /// 分屏:`from` = 被劈开的 pane(nil 走当前焦点;选单等抢焦点的路径必须显式传)
    @discardableResult
    private func split(vertical: Bool, from source: TerminalPane? = nil) -> TerminalPane? {
        guard let target = source ?? focusedPane, let tab = tabOf(target),
              let host = target.superview else { return nil }
        let newPane = makePane(into: tab)

        let sv = NSSplitView(frame: target.frame)
        sv.isVertical = vertical
        sv.dividerStyle = .thin
        sv.autoresizingMask = [.width, .height]

        if let parentSplit = host as? NSSplitView,
           let index = parentSplit.arrangedSubviews.firstIndex(of: target) {
            parentSplit.removeArrangedSubview(target)
            target.removeFromSuperview()
            parentSplit.insertArrangedSubview(sv, at: index)
        } else {
            target.removeFromSuperview()
            sv.frame = host.bounds
            host.addSubview(sv)
            // target 是树根被劈开 → 新分割视图接任树根(标签持树,v1.6 起要记账)
            if tab.rootView === target { tab.rootView = sv }
        }
        sv.addArrangedSubview(target)
        sv.addArrangedSubview(newPane)

        updatePaneInsets()
        // 布局定型后均分
        DispatchQueue.main.async {
            let mid = (vertical ? sv.bounds.width : sv.bounds.height) / 2
            sv.setPosition(mid, ofDividerAt: 0)
            self.window?.makeFirstResponder(newPane.terminalView)
            self.overlay?.scheduleCapture()
        }
        return newPane
    }

    /// 分屏内边距:多 pane 时字符与荧光分割线之间留白;单 pane 归零。
    /// 按**活动标签**算(切标签时重调,后台标签切回时自然更新)
    private func updatePaneInsets() {
        let inset: CGFloat = activePanes.count > 1 ? 7 : 0
        activePanes.forEach { $0.contentInset = inset }
    }

    /// pane 的 shell 退出 → 从所属标签的树中移除并收缩;标签空了关标签;
    /// 全窗最后一个 shell 退出 = 整机关机
    private func paneTerminated(_ pane: TerminalPane) {
        pane.shutdown()
        guard let tab = tabOf(pane) else { return }
        if tab.panes.count == 1 {
            if tabs.count == 1 {
                // 最后一个 pane 退出(敲 `exit`)= 整机关机:先播显像管熄灭动画再
                // 关窗。此时**不**detach —— 渲染源拆了动画就没有画面可塌缩了;
                // close 会走 windowWillClose 统一清理(shutdown 幂等,死 pid 的 kill 无害)。
                // 会话快照:exit 退出也算"结束会话"——布局/frame 存下,cwd 已随 shell 死去缺省
                onAboutToClose?(self)
                if !isPoweringOff, let ov = overlay,
                   ov.playPowerOff(completion: { [weak self] in self?.window?.close() }) {
                    isPoweringOff = true
                    return
                }
                window?.close()
                return
            }
            // 标签的最后一个 shell 退出 = 关这个标签(closeTab 内部 detach/收尾)
            if let i = tabs.firstIndex(where: { $0 === tab }) {
                closeTab(at: i)
            }
            return
        }
        overlay?.detach(pane.terminalView)
        tab.panes.removeAll { $0 === pane }
        if tab.lastFocused === pane { tab.lastFocused = nil }
        if let sv = pane.superview as? NSSplitView {
            sv.removeArrangedSubview(pane)
            pane.removeFromSuperview()
            if sv.arrangedSubviews.count == 1 {
                let survivor = sv.arrangedSubviews[0]
                sv.removeArrangedSubview(survivor)
                survivor.removeFromSuperview()
                if let parentSplit = sv.superview as? NSSplitView,
                   let index = parentSplit.arrangedSubviews.firstIndex(of: sv) {
                    parentSplit.removeArrangedSubview(sv)
                    sv.removeFromSuperview()
                    parentSplit.insertArrangedSubview(survivor, at: index)
                } else {
                    // sv 是这个标签的树根(活动标签挂在 splitHost;后台标签
                    // superview 为 nil,量不到 —— 统一按"幸存者接任树根"处理)
                    sv.removeFromSuperview()
                    survivor.autoresizingMask = [.width, .height]
                    tab.rootView = survivor
                    if tab === activeTab {
                        survivor.frame = splitHost.bounds
                        splitHost.addSubview(survivor)
                    }
                }
            }
        } else {
            pane.removeFromSuperview()
        }
        if tab === activeTab {
            window?.makeFirstResponder(activePanes.first?.terminalView)
            updatePaneInsets()
        }
        overlay?.scheduleCapture()
    }

    // MARK: - 标签操作(2026-08-06 窗口内多标签)

    /// 文件 → 新建标签页(⌘T;AppDelegate 路由到 key 窗口)
    func newTab(cwd: String? = nil) {
        let tab = Tab()
        tabs.append(tab)
        let pane = makePane(cwd: cwd, into: tab)
        pane.autoresizingMask = [.width, .height]
        tab.rootView = pane
        // Metal 不可用的兜底路径:新 pane 恢复原生自绘(init 那次 forEach 管不到它)
        if overlay == nil { pane.terminalView.suppressNativeDrawing = false }
        selectTab(tabs.count - 1)
    }

    /// 切换活动标签:同一块荧光屏换内容 —— 配"换台"特效正合隐喻
    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        // 切走前:终结未提交 IME(M0 教训)、收起搜索条、记住焦点
        activePanes.forEach { $0.finalizeIMESessionIfNeeded() }
        if let bar = searchBar, !bar.isHidden { closeSearch() }
        activeTab?.lastFocused = focusedPane
        activeTab?.rootView?.removeFromSuperview()
        activeTabIndex = index
        mountActiveTab()
        overlay?.resetBurnIn()         // 上一"频道"的余辉别拖进新频道(重影修复)
        overlay?.playChannelSwitch()   // 内部尊重设置开关;普通模式已被钳 false
        overlay?.scheduleCapture()
        refreshTabBar()
    }

    /// 关标签(shell 一并终止);最后一页 = 关窗(关机动画走 windowShouldClose)
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 {
            window?.performClose(nil)
            return
        }
        let closingActive = (index == activeTabIndex)
        let tab = tabs[index]
        tab.panes.forEach { p in
            overlay?.detach(p.terminalView)
            p.shutdown()
        }
        tab.rootView?.removeFromSuperview()
        tabs.remove(at: index)
        if closingActive {
            activeTabIndex = min(index, tabs.count - 1)
            mountActiveTab()
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        overlay?.scheduleCapture()
        refreshTabBar()
    }

    /// 挂载活动标签的树(selectTab/closeTab 公共尾部):上屏、还焦点、清活动点
    private func mountActiveTab() {
        guard let tab = activeTab else { return }
        if let tree = tab.rootView, tree.superview !== splitHost {
            tree.frame = splitHost.bounds
            tree.autoresizingMask = [.width, .height]
            splitHost.addSubview(tree)
        }
        // 切入的标签整幅置脏(2026-08-07 重影修复的另一半):后台期间它可能被
        // 窗口缩放/标签栏出没牵连改过尺寸,脏行追踪跨不过这些事件,全量重画兜底
        tab.panes.forEach { overlay?.markAllDirty(view: $0.terminalView) }
        tab.hasActivity = false
        updatePaneInsets()
        window?.title = tab.title
        window?.makeFirstResponder((tab.lastFocused ?? tab.panes.first)?.terminalView)
        // 恢复的后台标签首次亮相:此刻树才有宽高,补应用存档的分屏比例
        if !pendingSplitRatios.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.applyRestoredRatios() }
        }
    }

    // 菜单动作(经 responder chain;MainMenu 建项)
    @objc func closeTabAction(_ sender: Any?) { closeTab(at: activeTabIndex) }
    @objc func nextTabAction(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex + 1) % tabs.count)
    }
    @objc func previousTabAction(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex + tabs.count - 1) % tabs.count)
    }
    /// 窗口 → 标签页 N(⌘1~9;item.tag = 目标下标)
    @objc func selectTabNumberAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        selectTab(item.tag)
    }

    // MARK: - 标签栏(双样式:CRT 盒绘条 / 液态玻璃条)

    private var tabStrip: TabStripController?     // CRT 盒绘条画布(荧光屏内)
    private var crtBarHovered: Int?               // 盒绘条悬浮格(浮 x/浅底;nil=无)
    private var crtBarStyle = 0                   // 盒绘条样式(预设携带;applySettings 更新)
    private let glassBarModel = GlassTabBarModel()
    private var glassBarHost: NSView?             // 液态玻璃条(AppKit 悬浮层,懒建)

    /// 标签栏全量刷新:样式判定唯一依据 = **机壳是否实际生效**(uniforms.frameOn,
    /// 它已经把 CRT 总开关/弧度联动/frameMargin 全算进去了)——
    /// 机壳开 → 盒绘条画在荧光屏里;机壳关(含普通模式)→ 液态玻璃条。
    /// 单标签两种条都不显示(与原生行为一致)。
    func refreshTabBar() {
        let multi = tabs.count > 1
        let frameOn = (overlay?.uniforms.frameOn ?? 0) > 0.5
        let wantCRT = multi && frameOn && overlay != nil
        let wantGlass = multi && !wantCRT

        if wantCRT, let ov = overlay {
            let strip = tabStrip ?? ov.makeTabStrip()
            tabStrip = strip
            ov.tabStrip = strip
            let font = focusedPane?.terminalView.font
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let scale = window?.backingScaleFactor ?? 2
            let cell = GlyphAtlas.cellSize(font: font, scale: scale)
            let cellWpt = max(CGFloat(cell.w) / scale, 1)
            let cols = max(20, Int((root.bounds.width - 2 * root.marginInset) / cellWpt))
            let hovered = (crtBarHovered.map { $0 < tabs.count ? $0 : nil } ?? nil)
            strip.update(tabs: tabs.map { .init(title: $0.title, hasActivity: $0.hasActivity) },
                         selected: activeTabIndex, hovered: hovered, cols: cols, style: crtBarStyle)
            root.crtBarHeight = CGFloat(cell.h) / scale * CGFloat(strip.rows)
            root.tabBarReserve = root.crtBarHeight + 6
            root.onTabBarClick = { [weak self] x in
                guard let self, let strip = self.tabStrip else { return }
                guard let hit = strip.hitTest(column: Int(x / cellWpt)) else { return }
                if hit.isClose {
                    self.closeTab(at: hit.tab)
                } else {
                    self.selectTab(hit.tab)
                }
            }
            // 悬浮(2026-08-07,与玻璃条同构):换格才重排(字符画布重 feed 很便宜,
            // 但没必要每次 mouseMoved 都来一趟)
            root.onTabBarHover = { [weak self] x in
                guard let self, let strip = self.tabStrip else { return }
                let idx = x.flatMap { strip.tabIndex(atColumn: Int($0 / cellWpt)) }
                if idx != self.crtBarHovered {
                    self.crtBarHovered = idx
                    self.refreshTabBar()
                }
            }
        } else {
            root.crtBarHeight = 0
            crtBarHovered = nil
            overlay?.tabStrip = nil
            if !wantGlass { root.tabBarReserve = 0 }
        }

        if wantGlass {
            ensureGlassBar()
            glassBarModel.items = tabs.enumerated().map { i, t in
                .init(id: i, title: t.title, hasActivity: t.hasActivity)
            }
            glassBarModel.selected = activeTabIndex
            glassBarHost?.isHidden = false
            root.tabBarReserve = GlassTabBar.height + 10
        } else {
            glassBarHost?.isHidden = true
        }
        root.needsLayout = true
        overlay?.scheduleCapture()
    }

    private func ensureGlassBar() {
        guard glassBarHost == nil else { return }
        let host = GlassTabBar.makeHostView(model: glassBarModel,
                                            onSelect: { [weak self] i in self?.selectTab(i) },
                                            onClose: { [weak self] i in self?.closeTab(at: i) },
                                            onNew: { [weak self] in
                                                self?.newTab(cwd: self?.currentWorkingDirectory)
                                            })
        glassBarHost = host
        root.glassBarView = host
        root.addSubview(host, positioned: .above, relativeTo: overlay)
    }

    /// 窗口拉伸 → 盒绘条列数变了要重排(玻璃条自适应,无感)
    func windowDidResize(_ notification: Notification) {
        if tabs.count > 1, root.crtBarHeight > 0 { refreshTabBar() }
    }

    // MARK: - 设置应用(全部 pane + 窗口 overlay)

    func applySettings(_ cfg: CRTConfig, fontSize: CGFloat, cursorStyle: Float) {
        panes.forEach { $0.applyFont(cfg, fontSize: fontSize) }
        applyCRTMode(cfg)
        // 提示符主题(v1.3):记到进程级(新 shell 注入)+ **热切换**(用户追加:
        // 选择/切预设立即生效)—— 主题变了就写状态文件并向已握手(OSC 7777,
        // 装了 TRAPUSR1 的新版集成脚本)的会话发 SIGUSR1,原地重画提示符;
        // 未握手的会话绝不发(zsh 对未 trap 的 USR1 默认直接退出)。
        // 首次广播(启动)只记录不发:shell 自己启动时按状态文件应用过了
        TermHost.currentPromptTheme = cfg.promptTheme
        // 状态文件无条件同步(它是 shell 读取的唯一真相源;曾因"首播只记录"
        // 跳过写入,新窗首次切换整个被吞 —— auto-drive 端到端场景抓出)
        ShellIntegration.writePromptTheme(cfg.promptTheme)
        let promptChanged = !promptThemeEverApplied || lastAppliedPromptTheme != cfg.promptTheme
        promptThemeEverApplied = true
        lastAppliedPromptTheme = cfg.promptTheme
        if promptChanged {
            // v14:促发改 **PTY 按键注入**(CSI 991~,集成脚本绑定为应用主题的
            // widget)—— 与用户手敲键盘同一条处理路径,不依赖信号/异步玄学。
            // 只对已握手(v2)且**非备用屏**(vim/htop 等全屏程序用 alternate
            // buffer,注入会漏垃圾序列)的会话发;其余靠 precmd 保底(命令
            // 结束/下次回车必达)
            for p in panes {
                let tv = p.terminalView
                let ready = tv.promptHotswapReady
                let alt = tv.getTerminal().isCurrentBufferAlternate
                ShellIntegration.debugLog("切换 theme=\(cfg.promptTheme ?? "none") pane pid=\(tv.process.shellPid) ready=\(ready) alt=\(alt)\(ready && !alt ? " → 注入 991~" : " → 跳过(precmd 保底)")")
                if ready && !alt {
                    tv.send(txt: "\u{1b}[991~")
                }
            }
        }
        if let ov = overlay {
            var u = CRTUniforms()
            cfg.apply(to: &u)
            ov.uniforms = u
            ov.cursorBlinks = cfg.blinkingCursor ?? true
            ov.cursorStyle = cursorStyle
            ov.dividerStyle = cfg.dividerStyle ?? 0
            // 动画类被动特效受 CRT 总开关钳制("看起来没有特效"含开机动画/闪屏/换台)
            let crtOn = cfg.crtEffectsEnabled ?? true
            ov.powerAnimationEnabled = (cfg.powerOnEffect ?? true) && crtOn   // 只改开关,不重播动画
            ov.powerSpeedFactor = CRTConfig.powerSpeedFactor(cfg.powerOnSpeed)
            ov.preferredRate = cfg.refreshRate ?? 60
            ov.animateInBackground = cfg.animateInBackground ?? true
            ov.visualBellEnabled = (cfg.visualBell ?? true) && crtOn
            ov.channelFXEnabled = (cfg.channelSwitchFX ?? true) && crtOn
            ov.scheduleCapture()
        }
        notifyLongCommand = cfg.notifyLongCommand ?? true
        notifyThreshold = cfg.notifyThresholdSeconds ?? 10
        notifyOnBell = cfg.notifyOnBell ?? true
        panes.forEach {
            $0.terminalView.pasteProtectionEnabled = cfg.pasteProtection ?? true
            // 小件三连(v1.2 #8):滚回行数运行时即改(上游公开 API,全窗立即生效);
            // Option=Meta 开关
            $0.terminalView.getTerminal().changeScrollback(cfg.scrollbackLines ?? 10000)
            $0.terminalView.optionAsMetaKey = cfg.optionAsMeta ?? true
            // 波特率限速(v1.4):运行时即改;切到 0 会把积压立刻吐完
            $0.terminalView.outputBitRate = cfg.bitRate ?? 0
        }
        // 普通终端模式(CRT 关)无机壳:固定小 padding(8 逻辑 px,普通终端惯例)
        let newInset = (cfg.crtEffectsEnabled ?? true) ? Self.inset(forMargin: cfg.margin) : 8
        if newInset != root.marginInset {
            root.marginInset = newInset
            root.needsLayout = true
        }
        root.caseBandActive = cfg.frameLayerActive   // didSet 里变了才 needsLayout
        applyWindowOpacity(cfg.windowOpacity ?? 1)
        // 标签栏样式跟着机壳/字体走(uniforms 刚更新完,判定才准)
        crtBarStyle = cfg.crtTabBarStyle ?? 0
        refreshTabBar()
    }

    /// windowOpacity → 容器透明度(cool-retro-term 语义:0~1 映射 0.7~1.0)
    private func applyWindowOpacity(_ opacity: Double) {
        window?.alphaValue = CGFloat(0.7 + 0.3 * min(max(opacity, 0), 1))
    }

    // MARK: - 通知 + Visual Bell(v1.2 #5,纯本机 —— 用户裁决:决不关联 iPhone)

    // 提示符主题热切换的变化检测(v1.3;per-窗口,避免多窗口首个广播吞掉后续)
    private var promptThemeEverApplied = false
    private var lastAppliedPromptTheme: String?

    var notifyLongCommand = true          // 长命令后台完成 → 通知中心
    var notifyThreshold: Double = 10      // "长"的阈值(秒,设置可调)
    var notifyOnBell = true               // 后台 bell → 通知中心

    /// 本窗是否在"用户视线内"(app 激活且本窗是 key)——在看着就不用通知
    private var isFrontmost: Bool {
        NSApp.isActive && (window?.isKeyWindow ?? false)
    }

    /// bell(\a)→ 荧光闪屏(前台后台都闪);后台再补一条通知
    private func bellReceived(from pane: TerminalPane) {
        overlay?.triggerVisualBell()
        // 后台标签响铃 → 标签栏挂活动点「·」(切到即清)
        if let tab = tabOf(pane), tab !== activeTab, !tab.hasActivity {
            tab.hasActivity = true
            refreshTabBar()
        }
        if notifyOnBell && !isFrontmost {
            Notifier.post(title: L("终端响铃"), body: window?.title ?? "YeTerm")
        }
    }

    /// 命令完成(OSC 133 D)→ 跑得够久且用户不在看 → 通知中心
    private func commandFinished(in pane: TerminalPane, mark: CommandMark, duration: TimeInterval) {
        // 后台标签的命令跑完(≥1s,过滤回车刷提示符)→ 标签栏挂活动点
        if let tab = tabOf(pane), tab !== activeTab, duration >= 1, !tab.hasActivity {
            tab.hasActivity = true
            refreshTabBar()
        }
        guard notifyLongCommand, duration >= notifyThreshold, !isFrontmost else { return }
        let status = (mark.exitCode ?? 0) == 0 ? L("完成") : Lf("失败(退出码 %d)", mark.exitCode!)
        let mins = Int(duration) / 60, secs = Int(duration) % 60
        let elapsed = mins > 0 ? Lf("%1$d 分 %2$d 秒", mins, secs) : Lf("%d 秒", secs)
        Notifier.post(title: Lf("命令%@", status),
                      body: Lf("耗时 %1$@ — %2$@", elapsed, window?.title ?? "YeTerm"))
    }

    // MARK: - 截图 / 录 GIF(v1.2 #7)

    private let gifRecorder = GIFRecorder()

    private static func desktopURL(_ name: String) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent("\(name)-\(fmt.string(from: Date()))")
    }

    /// 文件 → 导出 CRT 截图(⇧⌘S):当前画面(含机壳)存桌面
    @objc func exportScreenshotAction(_ sender: Any?) {
        _ = exportScreenshot()
    }

    @discardableResult
    func exportScreenshot(to url: URL? = nil) -> URL? {
        let dest = url ?? Self.desktopURL(L("YeTerm截图")).appendingPathExtension("png")
        guard let img = overlay?.frameImage(),
              (try? PNGWriter.write(img, to: dest.path)) != nil else { return nil }
        Notifier.post(title: L("截图已保存"), body: dest.lastPathComponent)
        return dest
    }

    /// 文件 → 录制 GIF(⇧⌘R):再按一次停止;上限 10 秒自动停
    @objc func toggleGIFRecordingAction(_ sender: Any?) {
        if gifRecorder.isRecording {
            finishGIFRecording()
        } else {
            startGIFRecording()
        }
    }

    func startGIFRecording() {
        guard let ov = overlay else { return }
        gifRecorder.start(frameProvider: { [weak ov] in ov?.frameImage(live: true) },
                          onAutoStop: { [weak self] in self?.finishGIFRecording() })
        window?.title = L("● 录制 GIF 中…(⇧⌘R 停止,上限 30 秒)")
    }

    @discardableResult
    func finishGIFRecording(to url: URL? = nil) -> URL? {
        let dest = url ?? Self.desktopURL(L("YeTerm动图")).appendingPathExtension("gif")
        let out = gifRecorder.finish(writeTo: dest)
        window?.title = activeTab?.title ?? "YeTerm"
        if let out {
            Notifier.post(title: L("GIF 已保存"), body: out.lastPathComponent)
        }
        return out
    }

    var gifRecordingForTesting: Bool { gifRecorder.isRecording }
    var gifFrameCountForTesting: Int { gifRecorder.frameCount }

    // MARK: - 消磁彩蛋(v1.2 #13)

    /// 显示 → 消磁(⇧⌘M;机壳点击也走这里)
    @objc func degaussAction(_ sender: Any?) {
        overlay?.playDegauss()
    }

    // MARK: - OSD 调节面板(v1.2 #14)

    private var osdKeyView: OSDKeyView?
    // 同 serverTarget:OSD 捕手抢焦点后 focusedPane 会回落 panes.first,
    // 关闭时得把焦点还给呼出时那个 pane(否则多分屏下焦点莫名跳去左屏)
    private weak var osdTarget: TerminalPane?

    /// 显示 → OSD 调节面板(⌥⌘O;AppDelegate 带着 settingsModel 转进来)
    func toggleOSD(model: SettingsModel) {
        guard let ov = overlay else { return }
        let osd = ov.ensureOSD(model: model)
        if osd.visible {
            osd.hide()
            ov.scheduleCapture()
            window?.makeFirstResponder((osdTarget ?? focusedPane)?.terminalView)
            return
        }
        if osdKeyView == nil {
            let kv = OSDKeyView(frame: .zero)
            root.addSubview(kv)
            osdKeyView = kv
        }
        let osdBack = focusedPane          // ← 抢焦点之前先锁定
        osdTarget = osdBack
        osdKeyView?.osd = osd
        osd.onAutoHide = { [weak self] in
            self?.overlay?.scheduleCapture()
            self?.window?.makeFirstResponder(osdBack?.terminalView)
        }
        osd.show()
        ov.scheduleCapture()
        window?.makeFirstResponder(osdKeyView)
    }

    // MARK: - 服务器选单 + SSH 连接(v1.3 SSH)

    private var serverKeyView: ServerPickerKeyView?
    // 选单开启瞬间锁定的目标 pane(用户实测:焦点在右分屏呼出选单回车,
    // 命令却发进了左分屏)—— 选单的隐形键盘捕手抢走 firstResponder 后,
    // focusedPane 就回落到 panes.first。与 searchTarget 同款教训:焦点相关的
    // "当前 pane"必须在交互开始时捕存,不能在回调里现算
    private weak var serverTarget: TerminalPane?

    /// ⇧⌘O 呼出/关闭服务器选单(OSD 三件套同款流程)
    func toggleServerPicker() {
        guard let ov = overlay else { return }
        let picker = ov.ensureServerPicker()
        if picker.visible {
            picker.hide()
            ov.scheduleCapture()
            window?.makeFirstResponder((serverTarget ?? focusedPane)?.terminalView)
            return
        }
        if serverKeyView == nil {
            let kv = ServerPickerKeyView(frame: .zero)
            root.addSubview(kv)
            serverKeyView = kv
        }
        let target = focusedPane          // ← 抢焦点之前先锁定
        serverTarget = target
        serverKeyView?.picker = picker
        serverKeyView?.onActivity = { [weak self] in self?.overlay?.scheduleCapture() }
        picker.onDismiss = { [weak self] in
            self?.overlay?.scheduleCapture()
            self?.window?.makeFirstResponder(target?.terminalView)
        }
        picker.onConnect = { [weak self] host, split in
            self?.connectSSH(host, inSplit: split, in: target)
        }
        picker.show()
        ov.scheduleCapture()
        window?.makeFirstResponder(serverKeyView)
    }

    /// 连接远程主机:替用户在目标 shell 里敲 ssh 命令(Ctrl-U 先清行,
    /// 防止提示符上有半截输入被拼进命令);存过密码则布置自动登录哨兵。
    /// inSplit = true 时先向右分屏,在新屏连接(⇧回车语义)。
    /// `target` = 落点 pane(nil 走当前焦点);选单路径必须显式传,见 serverTarget
    func connectSSH(_ host: SSHHost, inSplit: Bool, in target: TerminalPane? = nil) {
        let base = target ?? focusedPane
        let pane = inSplit ? split(vertical: true, from: base) : base
        guard let pane else { return }
        // 内网地址:先由 **app 主进程** 亲自碰一下局域网 —— macOS 只登记
        // app 自己发出的申请,光靠 ssh 子进程连,系统既不弹授权也不进设置列表
        // (2026-07-30 事故:补了 Info.plist 声明键仍然没弹窗的原因)
        LocalNetworkPermission.ensureBeforeConnect(host: host.host, port: host.port)
        let tv = pane.terminalView
        tv.send(txt: "\u{15}" + host.sshCommand + "\r")
        window?.title = host.name
        if let tab = tabOf(pane) {
            tab.title = host.name
            refreshTabBar()
        }
        // 哨兵带上主机对象:除了自动答指纹/填密码,还能在算法协商失败时
        // 抓对方 offer 的算法自动降级重连(老设备通用,不碰 ~/.ssh/config)
        SSHAutoLogin.arm(on: tv, host: host,
                         password: SSHHostStore.shared.password(id: host.id))
        overlay?.scheduleCapture()
    }

    /// 当前聚焦 shell 的工作目录(⌘N/⌘T 继承目录用;shell 死/查不到 = nil)
    var currentWorkingDirectory: String? {
        focusedPane.flatMap { SessionStore.cwdOf(pid: $0.terminalView.process.shellPid) }
    }

    // MARK: - 粘贴保护(v1.2 #6;v1.3 改版 OSD 风格画布)

    private var pasteGuard: PasteGuardView?   // 隐形键盘捕手(画面在 overlay 里合成)

    /// 弹 OSD 风格确认面板(键盘焦点移交隐形捕手;确认/取消后归还终端)
    private func showPasteGuard(text: String, for tv: EventTerminalView) {
        guard let ov = overlay else { return }
        if pasteGuard == nil {
            let g = PasteGuardView(frame: .zero)
            pasteGuard = g
            root.addSubview(g)
        }
        guard let g = pasteGuard else { return }
        ov.ensurePasteGuard().present(text: text)
        g.onConfirm = { [weak self, weak tv] in
            self?.closePasteGuard(returnFocusTo: tv)
            tv?.performConfirmedPaste()
        }
        g.onCancel = { [weak self, weak tv] in
            self?.closePasteGuard(returnFocusTo: tv)
        }
        g.isHidden = false
        ov.scheduleCapture()
        window?.makeFirstResponder(g)
    }

    private func closePasteGuard(returnFocusTo tv: EventTerminalView?) {
        pasteGuard?.isHidden = true
        overlay?.pasteGuardController?.hide()
        overlay?.scheduleCapture()
        if let tv { window?.makeFirstResponder(tv) }
    }

    // MARK: - 命令导航(v1.2 #3,OSC 133;数据在 EventTerminalView.commandMarks)

    /// 命令 → 上一条命令(⌘↑)
    @objc func previousCommandAction(_ sender: Any?) {
        focusedPane?.terminalView.jumpToPreviousCommand()
        overlay?.scheduleCapture()
    }

    /// 命令 → 下一条命令(⌘↓)
    @objc func nextCommandAction(_ sender: Any?) {
        focusedPane?.terminalView.jumpToNextCommand()
        overlay?.scheduleCapture()
    }

    /// 命令 → 复制上条命令输出(⇧⌘C)。没有书签数据时提示装 shell 集成
    @objc func copyLastOutputAction(_ sender: Any?) {
        guard let tv = focusedPane?.terminalView else { return }
        if tv.copyLastCommandOutput() == nil, tv.commandMarks.marks.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("还没有命令记录")
            alert.informativeText = L("命令导航需要 Shell 集成:菜单「命令 → 安装 Shell 集成…」一键写入,重开终端生效。")
            alert.runModal()
        }
    }

    // MARK: - ⌘F 终端内搜索(v1.1 #4;查找引擎 = SwiftTerm 自带 findNext/findPrevious,
    // 匹配即设选区 → 我们的自绘反色高亮天然生效,滚动走既有捕获链,零渲染新码)

    /// 编辑 → 查找…(⌘F):唤出荧光搜索条并聚焦
    @objc func showSearchAction(_ sender: Any?) {
        if searchBar == nil {
            let bar = SearchBarView(frame: .zero)
            bar.onChange = { [weak self] term in self?.doSearch(term: term, backward: true, incremental: true) }
            bar.onSubmit = { [weak self] term, backward in self?.doSearch(term: term, backward: backward) }
            bar.onClose = { [weak self] in self?.closeSearch() }
            searchBar = bar
            root.searchBarView = bar
            root.addSubview(bar, positioned: .above, relativeTo: overlay)
        }
        searchTarget = focusedPane?.terminalView
        if let u = overlay?.uniforms {
            searchBar?.setAccent(red: CGFloat(u.fontColor.x), green: CGFloat(u.fontColor.y),
                                 blue: CGFloat(u.fontColor.z))
        }
        searchBar?.isHidden = false
        root.needsLayout = true
        searchBar?.focusField(in: window)
    }

    /// 编辑 → 查找下一个(⌘G,向历史方向继续)/ 查找上一个(⇧⌘G,反向)
    @objc func findNextAction(_ sender: Any?) { repeatSearch(backward: true) }
    @objc func findPreviousAction(_ sender: Any?) { repeatSearch(backward: false) }

    private func repeatSearch(backward: Bool) {
        guard let bar = searchBar, !bar.isHidden, !bar.term.isEmpty else {
            showSearchAction(nil)
            return
        }
        doSearch(term: bar.term, backward: backward)
    }

    /// 执行查找。方向语义(终端习惯,与 iTerm2 一致):默认向**历史**方向
    /// (backward=true,找更旧的输出);增量输入时先清状态再找,保证每次都
    /// 命中"离底部最近"的那条,滚动位置稳定不乱跳。
    private func doSearch(term: String, backward: Bool, incremental: Bool = false) {
        guard let tv = searchTarget ?? focusedPane?.terminalView else { return }
        guard !term.isEmpty else {
            tv.clearSearch()
            searchBar?.updateCounter(index: 0, total: 0)
            overlay?.scheduleRepaint()
            return
        }
        if incremental { tv.clearSearch() }
        if backward {
            tv.findPrevious(term)
        } else {
            tv.findNext(term)
        }
        let summary = tv.searchMatchSummary(term)
        searchBar?.updateCounter(index: summary.index, total: summary.total)
        overlay?.scheduleRepaint()
    }

    private func closeSearch() {
        searchBar?.isHidden = true
        searchTarget?.clearSearch()
        overlay?.scheduleRepaint()
        if let tv = searchTarget {
            window?.makeFirstResponder(tv)   // 焦点还给终端,继续打字无缝
        }
        searchTarget = nil
    }

    // MARK: - 菜单动作(经 responder chain)

    /// 显示 → 开关 CRT 特效(⌘E):关特效时恢复原生渲染(否则黑屏)
    /// CRT 总开关落地(用户裁决 2026-07-28 重定义:**渲染管线永远 GPU 常驻**):
    /// 关 ≠ 切原生 CPU 渲染 —— overlay 不藏、原生层保持抑制;"没有特效"由
    /// CRTConfig.apply 尾部的参数中性化实现(直通观感)。这里只钳制动画类
    /// 被动特效(开机动画/闪屏/换台)并保证管线状态就位(幂等)。
    private func applyCRTMode(_ cfg: CRTConfig) {
        guard let ov = overlay else { return }
        ov.userHidden = false
        panes.forEach { $0.terminalView.suppressNativeDrawing = true }
        window?.backgroundColor = .black
        // 颜色系统切换(v1.2 用户裁决):CRT=crterm 专属调色板;普通=Terminal.app
        // 式独立配色。AnsiColor 表变了 → 行缓存全失效重建(旧色残留会串台)
        let crtOn = cfg.crtEffectsEnabled ?? true
        // 标题栏透明后(2026-08-06),标题文字/红绿灯直接压在终端画面上 —— 外观
        // 明暗必须跟着**实际背景**走:白底主题(Mac 128K/E-Ink…)若维持深色外观,
        // 浅灰标题字会隐形。取染色后的真实背景(CRT=contrast 预混;普通=独立配色),
        // 亮度公式与 CRTConfig 白热化判定同源(Rec.709 加权)。
        let crtBg = cfg.effectiveColors().background
        let bgc = crtOn ? SIMD3(crtBg.x, crtBg.y, crtBg.z) : cfg.plainPalette().bg
        let bgLum = 0.21 * bgc.x + 0.72 * bgc.y + 0.04 * bgc.z
        window?.appearance = NSAppearance(named: bgLum > 0.5 ? .aqua : .darkAqua)
        let newOverride = crtOn ? nil : cfg.plainPalette()
        var changed: Bool
        switch (AnsiColor.plainOverride, newOverride) {
        case (nil, nil):
            changed = false
        case let (old?, new?):
            changed = old.fg != new.fg || old.bg != new.bg || old.palette != new.palette
        default:
            changed = true
        }
        AnsiColor.plainOverride = newOverride
        // CRT 模式 ANSI 覆盖(v1.2 预设大更新):经典配色预设带官方 16 色表;
        // nil = crterm 专属调色板。变了同样要全量重建行缓存
        let newCrtAnsi = crtOn ? cfg.crtAnsiPalette() : nil
        if AnsiColor.crtOverride != newCrtAnsi { changed = true }
        AnsiColor.crtOverride = newCrtAnsi
        // CRT 模式「文字颜色」(2026-08-03):默认前景覆盖,只动无颜色指令的普通
        // 输出。经典 CRT 组不吃(考据观感依赖内容纯白 → 满驱动纯磷光,判定按
        // 预设名,与下方"不铺背景图"同一条产品逻辑);普通模式走 plainOverride。
        // storedConfig/设置页已锁,这里再兜一层防手改 config.json 绕过
        let classicDevice = crtOn && Presets.isClassicCRT(cfg.name ?? "")
        let newCrtFg = (crtOn && !classicDevice) ? cfg.crtTextFg() : nil
        if AnsiColor.crtFgOverride != newCrtFg { changed = true }
        AnsiColor.crtFgOverride = newCrtFg
        if changed {
            ov.invalidateContentCache()
        }
        // 背景图片(v1.2 #16;**v1.5.1 起 CRT 模式也铺**)。两种模式共用同一张图和
        // 同一套预处理特效,上屏路径不同(合成层铺底 / CRT 着色器的屏幕底图),
        // 由 overlay 内部按 colorPassthrough 自行分派 —— 这里只回答"该不该有图"。
        //
        // 唯一的例外:**内置「经典 CRT」组的 21 套真实设备还原主题不铺图**
        // (用户裁决 2026-07-31)。理由与"这组锁定 CRT 特效不可关"是同一条:
        // 它们还原的是一台具体的老机器,屏幕后面贴张壁纸就不是那台机器了。
        // 判定按预设名而非"CRT 开着就不铺"—— 经典配色/私人收藏/自定义配置在
        // CRT 模式下照铺。路径/模式没变时 overlay 侧键控缓存空转,广播打进来不
        // 重复解码;传 nil = 顺手卸载成品纹理。(classicDevice 在上方文字颜色处定义)
        let bgPath = (cfg.plainBackgroundImage?.isEmpty == false) ? cfg.plainBackgroundImage : nil
        ov.setPlainBackground(path: classicDevice ? nil : bgPath,
                              mode: cfg.plainBackgroundImageMode ?? 0,
                              blur: cfg.plainBackgroundBlur ?? 0.5,
                              palette: cfg.plainBackgroundPixelPalette ?? 0,
                              darken: cfg.plainBackgroundDarken ?? 0.5,
                              animFPS: cfg.plainBackgroundAnimFPS ?? 30)
    }

    /// 显示 → 开关 CRT 特效(⌘E):翻的是**配置项**(持久;AppDelegate 转进来)
    func toggleCRTEffects(model: SettingsModel) {
        model.crtEffectsEnabled.toggle()
    }

    /// 着色器热重载(开发用;菜单已移除,保留 action 以备调试)
    @objc func reloadShaders(_ sender: Any?) {
        guard let ov = overlay else { return }
        if let log = ov.reloadShaders() {
            let alert = NSAlert()
            alert.messageText = L("着色器重载失败(保留旧版本继续运行)")
            alert.informativeText = log
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        ov.userHidden = false
        ov.start()
    }

    // MARK: - NSWindowDelegate

    /// ⌘W / 红色关闭钮 → 先播关机动画(画面塌缩成亮线熄灭),放完才真正关窗。
    /// 【学】windowShouldClose 是 AppKit 给关窗请求留的"否决权"回调:返回 false
    ///      = 这次先不关(类比 Web 的 beforeunload 拦截)。我们随后在动画回调里
    ///      调 window.close() —— close() 不再走本回调,不会无限循环。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 会话快照钩子必须在这里(动画/清理之前):shell 还活着,cwd 才查得到
        if !isPoweringOff { onAboutToClose?(self) }
        guard !isPoweringOff, let ov = overlay else { return true }
        if ov.playPowerOff(completion: { [weak self] in self?.window?.close() }) {
            isPoweringOff = true
            return false
        }
        return true   // 动画不可用(开关关/特效隐藏)→ 直接放行
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.shutdown() }   // 关窗即终止全部 shell(含后台标签),防进程残留
    }
}

// MARK: - 菜单校验(标签相关项按标签数启停)
// 【学】NSMenuItemValidation:菜单展开前 AppKit 沿 responder chain 问"这项现在
//      能点吗"。返回 false = 项变灰;顺手还能改 state(✓ 勾选当前标签页)。
extension TerminalWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectTabNumberAction(_:)):
            item.state = (item.tag == activeTabIndex && tabs.count > 1) ? .on : .off
            return tabs.count > 1 && item.tag < tabs.count
        case #selector(nextTabAction(_:)), #selector(previousTabAction(_:)):
            return tabs.count > 1
        default:
            return true
        }
    }
}
