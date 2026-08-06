// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— App 全局大管家(阅读顺序第 3 站)
//
// 这个文件:macOS 图形程序的"总控"。AppKit(macOS 的 UI 框架,类比前端的
//   DOM+浏览器 API)规定:一个 GUI 程序 = 一个 NSApplication 单例 + 一个
//   AppDelegate(委托对象)。系统在关键时刻(启动完成/点菜单/退出…)
//   回调 delegate 的方法 —— 这就是 macOS 无处不在的「委托模式」,
//   类比 Web 框架里实现接口的生命周期钩子(如 Servlet 的 init/destroy)。
//
// 本文件管四件事:
//   1. 启动:建菜单栏、开第一个终端窗口(applicationDidFinishLaunching);
//   2. 多窗口:⌘N 新窗 / ⌘T 新标签(windowControllers 数组持有所有窗);
//   3. 设置:⌘, 打开设置窗;常驻一个 SettingsModel 广播设置变更到全部窗口;
//   4. 「主题」菜单:动态生成、点击即切换配置。
//
// 语法看点:
//   `@objc func xxx(_ sender: Any?)` —— 暴露给 Objective-C 运行时的方法,
//     菜单点击靠"消息名"找到它(AppKit 的 target-action 机制,
//     类比前端的事件绑定 onClick="xxx")。
//   `lazy var` —— 第一次被访问才初始化(类比 Spring 的懒加载 Bean)。
//   `[weak self]` —— 闭包捕获列表:弱引用防"循环引用内存泄漏"
//     (Swift 用引用计数管内存,不是 Java 那种 GC,两个对象互相强持有就永远
//     释放不掉;weak 类比 Java 的 WeakReference)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// GUI 启动器:程序化 NSApplication 生命周期(无 storyboard/xib)。
/// `swift run YeTerm` 直接跑;真正的 .app 打包在 M0-S8。
public enum AppRunner {
    public static func runGUI(options: LaunchOptions) -> Int32 {
        let app = NSApplication.shared
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        // 无 bundle 也要 Dock 图标 + 菜单栏
        app.setActivationPolicy(.regular)
        app.run()
        return 0
    }
}

/// CLI 解析出的启动参数
public struct LaunchOptions {
    public var fontName: String = "Menlo"
    public var fontSize: CGFloat = 14
    public var config: CRTConfig?          // --config <crterm.json>(兼容 cool-retro-term 导出)
    public var cursorStyle: Float = 0      // 0 块/1 下划线/2 竖线(--cursor-style;M3 进设置页)
    public init() {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private var windowControllers: [TerminalWindowController] = []
    private var settingsController: SettingsWindowController?
    /// 最近一次应用的设置(新窗口继承;全局单一 profile,与 cool-retro-term 同语义)
    private var lastApplied: (cfg: CRTConfig, size: CGFloat, style: Float)?

    /// 常驻设置模型:设置窗与「主题」快切菜单共用(变更实时广播全窗口)
    lazy var settingsModel: SettingsModel = {
        let model = SettingsModel(from: options.config)
        model.applyHandler = { [weak self] cfg, size, style in
            self?.lastApplied = (cfg, size, style)
            self?.windowControllers.forEach {
                $0.applySettings(cfg, fontSize: size, cursorStyle: style)
            }
        }
        // 换台效果(v1.2 #12):切主题瞬间全窗口闪断一下(老电视换台)
        model.onPresetSwitch = { [weak self] in
            self?.windowControllers.forEach { $0.overlay?.playChannelSwitch() }
        }
        return model
    }()

    init(options: LaunchOptions) {
        self.options = options
    }

    // MARK: - 主题快切菜单(NSMenuDelegate,打开时动态生成)

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 同一个 delegate 管两个动态菜单:「主题」与「服务器」,按 identifier 分流
        // (i18n 后菜单标题会跟着界面语言变,**不能**再按标题比对)
        if menu.identifier == MainMenu.serverMenuID {
            rebuildServerMenu(menu)
            return
        }
        menu.removeAllItems()
        let model = settingsModel
        model.refreshUserProfiles()
        func addTheme(_ name: String) {
            let item = NSMenuItem(title: Presets.displayName(name), action: #selector(themeSelected(_:)), keyEquivalent: "")
            item.target = self
            // ⚠️ 预设**标识符**挂在 representedObject 上,回调按它取 ——
            //    不能再用 sender.title 反查:标题现在是翻译过的显示名,
            //    英文界面下「MS-DOS 蓝」显示成「MS-DOS Blue」,拿标题去
            //    loadPreset 会找不到预设(i18n 时抓到的真 bug)。
            item.representedObject = name
            item.state = model.presetName == name ? .on : .off
            menu.addItem(item)
        }
        let header = NSMenuItem(title: L("系统预设"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        Presets.names.forEach(addTheme)
        if !model.userProfileNames.isEmpty {
            menu.addItem(.separator())
            let header2 = NSMenuItem(title: L("我的配置"), action: nil, keyEquivalent: "")
            header2.isEnabled = false
            menu.addItem(header2)
            model.userProfileNames.forEach(addTheme)
        }
    }

    @objc private func themeSelected(_ sender: NSMenuItem) {
        // representedObject 里放的是预设标识符(见 menuNeedsUpdate 的说明);
        // 兜底回落 title 只为兼容意外情况。
        let name = (sender.representedObject as? String) ?? sender.title
        settingsModel.loadPreset(name)
    }

    // MARK: - 关于面板

    /// 「关于 YeTerm」:走系统标准面板,但塞进自定义 credits ——
    /// 版本号取自 Info.plist(不硬编码),作者/仓库/上游致谢一并列出。
    /// 【学】orderFrontStandardAboutPanel(options:) 可以只覆盖想改的字段,
    ///   剩下的(图标、名字、版本)系统自己从 Info.plist 填,比自绘一个窗省事得多。
    @objc func showAboutAction(_ sender: Any?) {
        let body = NSMutableAttributedString()
        func line(_ s: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor,
                  bold: Bool = false) {
            body.append(NSAttributedString(string: s + "\n", attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]))
        }
        line(L("原生 arm64 的 macOS 复古 CRT 终端"), size: 12, color: .labelColor, bold: true)
        line("")
        line("github.com/qiuye97/YeTerm", color: .labelColor)
        line("")
        line(L("CRT 着色器移植自 cool-retro-term(GPL-3.0)"))
        line(L("终端内核 SwiftTerm(MIT)"))
        line(L("内置字体的许可见 app 内 Fonts/LICENSES/"))
        line("")
        line("GPL-3.0-or-later")

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: body,
            .init(rawValue: "Copyright"): "Copyright © 2026 qiuye97",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 窗口/标签(M2)

    /// 建一个新终端窗口(独立 session + 独立渲染管线)。
    /// `restore`(v1.2 #2):按会话存档恢复分屏树与窗口 frame
    @discardableResult
    /// 探针入口(auto-drive 场景 23 端到端):开一个真实新窗(真 shell/真 zshrc)
    public func newWindowForTesting() -> TerminalWindowController {
        let wc = makeWindow()
        wc.showWindow(nil)
        return wc
    }

    func makeWindow(restore: SessionState.WindowState? = nil) -> TerminalWindowController {
        // 开机自检(v1.2 #10):仅 app 启动的第一个窗口播(后续新窗只播显像管动画,
        // 不打断工作流);设置可关
        let playBoot = windowControllers.isEmpty && settingsModel.bootSelfTest
            && settingsModel.crtEffectsEnabled   // 总开关关=普通终端观感,自检也免
        // ⌘N/⌘T 继承目录(v1.2 #8):从当前 key 窗的聚焦 shell 查 cwd 注入新窗
        // (会话恢复窗自带目录,不掺和)
        var inheritedCwd: String?
        if restore == nil, settingsModel.inheritCwd,
           let keyWC = NSApp.keyWindow?.windowController as? TerminalWindowController
               ?? windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
            inheritedCwd = keyWC.currentWorkingDirectory
        }
        let wc = TerminalWindowController(options: options, restoreState: restore,
                                          playBootScreen: playBoot, initialCwd: inheritedCwd)
        // 2026-08-06 起标签由窗口内自管(样式可定制),原生 window tabbing 一律禁掉
        // (identifier 保留:探针按它过滤终端窗)
        wc.window?.tabbingMode = .disallowed
        wc.window?.tabbingIdentifier = NSWindow.TabbingIdentifier("YeTermTerminal")
        if let f = restore?.frame, f.count == 4, let w = wc.window {
            // 存档 frame 仍落在某块屏幕上才用(外接显示器拔了别把窗口摆到看不见的地方)
            let rect = NSRect(x: f[0], y: f[1], width: max(320, f[2]), height: max(240, f[3]))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                w.setFrame(rect, display: false)
            }
        } else if windowControllers.isEmpty {
            // 首窗记忆位置尺寸(无会话存档时的兜底);后续窗口级联偏移
            wc.window?.setFrameAutosaveName("YeTermMainWindow")
        } else if let anchor = NSApp.keyWindow ?? windowControllers.last?.window, let w = wc.window {
            w.cascadeTopLeft(from: NSPoint(x: anchor.frame.minX + 28, y: anchor.frame.maxY - 28))
        }
        // 关窗前快照(shell 活着才查得到 cwd):最后一个窗口关闭 = 退出会话,存档
        wc.onAboutToClose = { [weak self] closing in
            guard let self, self.settingsModel.restoreSession else { return }
            if self.windowControllers.count == 1, self.windowControllers.first === closing {
                self.saveSession()
            }
        }
        windowControllers.append(wc)
        if let l = lastApplied {
            wc.applySettings(l.cfg, fontSize: l.size, cursorStyle: l.style)
        }
        // 关窗即回收(shell 终止在 TerminalWindowController.windowWillClose)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: wc.window, queue: .main
        ) { [weak self, weak wc] _ in
            guard let self, let wc else { return }
            self.windowControllers.removeAll { $0 === wc }
        }
        return wc
    }

    /// File → New Window(⌘N):独立窗口(原生并标签已全局禁用,无需再防劫持)
    @objc func newWindowAction(_ sender: Any?) {
        let wc = makeWindow()
        wc.showWindow(nil)
    }

    /// File → New Tab(⌘T):在当前 key 终端窗里建**窗口内标签**(2026-08-06 起
    /// 弃用原生 addTabbedWindow —— 每标签一扇窗的模式样式完全不可定制);
    /// 没有终端窗在前台就退化成开新窗
    @objc func newTabAction(_ sender: Any?) {
        let target = (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? (NSApp.mainWindow?.windowController as? TerminalWindowController)
            ?? windowControllers.last
        guard let target else {
            newWindowAction(sender)
            return
        }
        // ⌘T 继承目录(v1.2 #8 同语义):新标签从当前聚焦 shell 的 cwd 出发
        let cwd = settingsModel.inheritCwd ? target.currentWorkingDirectory : nil
        target.newTab(cwd: cwd)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        newTabAction(sender)
    }

    // MARK: - 设置(全局广播)

    /// 命令 → 安装 Shell 集成…(v1.2 #3):一键写 ~/.zshrc,弹窗告知结果
    @objc func installShellIntegrationAction(_ sender: Any?) {
        let already = ShellIntegration.isInstalled
        let error = ShellIntegration.install()
        let alert = NSAlert()
        if let error {
            alert.alertStyle = .warning
            alert.messageText = L("安装失败")
            alert.informativeText = error
        } else if already {
            alert.messageText = L("Shell 集成已是最新")
            alert.informativeText = L("~/.zshrc 早已接线,集成脚本已刷新到最新版。新开的终端立即生效。")
        } else {
            alert.messageText = L("Shell 集成安装完成")
            alert.informativeText = L("已在 ~/.zshrc 末尾追加一行接线(只在 YeTerm 里生效,不影响其它终端)。新开的终端窗口即可使用 ⌘↑/⌘↓ 跳命令、⇧⌘C 复制上条输出。")
        }
        alert.runModal()
    }

    /// 显示 → 开关 CRT 特效(⌘E):翻配置项(持久化,广播全窗;v1.2 用户追加)。
    /// 模式切换也是"换台"(v1.2 补丁用户追加):尊重用户的换台效果开关,
    /// force 绕过 channelFXEnabled 的 crtOn 钳制时序(开方向此刻旧值还是 false)
    @objc func toggleCRTEffects(_ sender: Any?) {
        // 经典 CRT 主题锁定(v1.2 补丁用户裁决):设备还原主题不可关特效,
        // ⌘E 与设置页开关同一道闸,响一声系统提示音告知被拦
        if settingsModel.crtEffectsEnabled, Presets.isClassicCRT(settingsModel.presetName) {
            NSSound.beep()
            return
        }
        settingsModel.crtEffectsEnabled.toggle()
        if settingsModel.channelSwitchFX {
            windowControllers.forEach { $0.overlay?.playChannelSwitch(force: true) }
        }
    }

    /// 显示 → OSD 调节面板(⌥⌘O):当前 key 窗弹像素风屏上菜单(v1.2 #14)
    @objc func osdAction(_ sender: Any?) {
        let wc = NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? windowControllers.first
        wc?.toggleOSD(model: settingsModel)
    }

    // MARK: - 服务器菜单(v1.3 SSH)

    /// 「服务器」菜单打开时动态重建(menuNeedsUpdate 按标题分流到这里):
    /// 每台主机一项点击即连,下方选单快捷键与管理入口
    private func rebuildServerMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        SSHHostStore.shared.load()
        let hosts = SSHHostStore.shared.hosts
        if hosts.isEmpty {
            let empty = NSMenuItem(title: L("(还没有配置服务器)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for h in hosts {
            let item = NSMenuItem(title: h.name.isEmpty ? h.address : h.name,
                                  action: #selector(connectServerAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = h.id
            item.toolTip = h.note.isEmpty ? h.address : "\(h.address) — \(h.note)"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // 【学】keyEquivalent 大写字母隐含 ⇧:"O" = ⇧⌘O(小写 "o" 才是纯 ⌘O)
        let picker = NSMenuItem(title: L("服务器选单"),
                                action: #selector(serverPickerAction(_:)), keyEquivalent: "O")
        picker.target = self
        menu.addItem(picker)
        let manage = NSMenuItem(title: L("管理服务器…"),
                                action: #selector(manageServersAction(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        // 本地网络权限自检(2026-07-30 事故入口):内网连不上时点这里主动申请授权
        let netCheck = NSMenuItem(title: L("检查本地网络权限…"),
                                  action: #selector(checkLocalNetworkAction(_:)), keyEquivalent: "")
        netCheck.target = self
        menu.addItem(netCheck)
    }

    /// 「检查本地网络权限…」:app 主进程亲自申请一次并回报结果
    @objc func checkLocalNetworkAction(_ sender: Any?) {
        let probeHost = SSHHostStore.shared.hosts
            .first { LocalNetworkPermission.isLocalAddress($0.host) }?.host
        LocalNetworkPermission.runDiagnostic(probeHost: probeHost) { msg in
            let alert = NSAlert()
            alert.messageText = L("本地网络权限")
            alert.informativeText = msg
            alert.addButton(withTitle: L("打开设置"))
            alert.addButton(withTitle: L("好"))
            if alert.runModal() == .alertFirstButtonReturn {
                let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 菜单点击某台服务器 → 当前窗口开新标签页连接(不打扰当前工作现场)
    @objc func connectServerAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID,
              let host = SSHHostStore.shared.hosts.first(where: { $0.id == id }) else { return }
        newTabAction(nil)
        // 新标签的 shell 刚起步 —— PTY 有类型预读缓冲,命令先到也不会丢,
        // 但等一拍让新窗成为 key window 再定位控制器
        DispatchQueue.main.async { [weak self] in
            let wc = NSApp.keyWindow?.windowController as? TerminalWindowController
                ?? self?.windowControllers.last
            wc?.connectSSH(host, inSplit: false)
        }
    }

    /// ⇧⌘O 呼出服务器选单(OSD 家族:⌥⌘O 调节面板 / ⇧⌘O 选单)
    @objc func serverPickerAction(_ sender: Any?) {
        let wc = NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? windowControllers.first
        wc?.toggleServerPicker()
    }

    /// 菜单「管理服务器…」→ 设置窗直达「远程主机」页
    @objc func manageServersAction(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(model: settingsModel)
        }
        settingsController?.show(sectionID: "远程主机")
    }

    /// App 菜单 设置…(⌘,)经 responder chain 到达这里
    @objc func openSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(model: settingsModel)
        }
        settingsController?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLibrary.registerBundledFonts()   // 内置 13 款复古字体(进程级,无需安装)
        // 2026-08-06:标签改窗口内自管(样式可定制),系统级窗口并标签整个关掉
        // (顺带 AppKit 不再往「窗口」菜单自动塞英文的 Show All Tabs 等项)
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build(themeMenuDelegate: self)
        // 切换界面语言时重建菜单栏。SwiftUI 那半边(设置页)自己会响应式重画,
        // AppKit 这半边是命令式的,菜单项标题在 build 时就固化了 —— 只能整个重建。
        // 【学】NSMenu 是一次性搭好的对象树,没有"数据变了自动更新"这回事;
        //   前端类比:innerHTML 一次性渲染的静态区块,数据变了得重新渲染。
        NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSApp.mainMenu = MainMenu.build(themeMenuDelegate: self)
        }
        // 多实例检测(2026-07-29):工作实例 + 测试实例并存是用户的**正常工作流**
        // (用户在 YeTerm 里跑 Claude 开发 YeTerm 自己),不弹窗打扰 ——
        // 只在 stderr 记一行,排查"设置互相覆盖"类怪象时有据可查
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.yeterm.YeTerm")
            .filter { $0.processIdentifier != selfPid }
        if !peers.isEmpty {
            FileHandle.standardError.write(Data(
                "提示:检测到另一个 YeTerm 实例(PID \(peers.map { String($0.processIdentifier) }.joined(separator: ", "))),多实例共写配置可能互相覆盖\n".utf8))
        }
        // 会话恢复(v1.2 #2):有存档且开关开 → 照存档还原窗口/分屏/工作目录
        if settingsModel.restoreSession, let session = SessionStore.load() {
            for ws in session.windows {
                let wc = makeWindow(restore: ws)
                wc.showWindow(nil)
                // 分屏比例要等窗口 frame 定型、AppKit 布局跑完才应用
                DispatchQueue.main.async { wc.applyRestoredRatios() }
            }
        }
        if windowControllers.isEmpty {
            makeWindow().showWindow(nil)
        }
        // 只激活一次。曾经的"异步二次 activate(ignoringOtherApps:)"已移除:
        // beta 协作式激活下反复抢激活有夺焦嫌疑(M0 IME 事故排查时排雷)。
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 当前全部窗口的会话存档(⌘Q 与"关最后一个窗"两条退出路径都走这里)
    func saveSession() {
        let windows = windowControllers.compactMap { $0.snapshotState() }
        guard !windows.isEmpty else { return }
        SessionStore.save(SessionState(windows: windows))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q:此刻窗口都还活着,shell 未杀,cwd 可查
        if settingsModel.restoreSession {
            saveSession()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
