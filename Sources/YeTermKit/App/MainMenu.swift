// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 屏幕顶部的菜单栏
//
// 这个文件:用纯代码搭建菜单栏(很多 app 用可视化编辑器拖,我们全代码,
//   对学习者反而更透明:每个菜单项就是一行 addItem)。
// 关键机制「responder chain(响应者链)」:菜单项只写了"动作名"
//   (如 splitRightAction:),没写找谁执行 —— AppKit 会沿着
//   当前焦点视图 → 窗口 → 窗口控制器 → AppDelegate 一路找,谁实现了这个
//   方法就派给谁,找不到该菜单项自动置灰。类比前端的事件冒泡:
//   事件从最深的元素往上冒,谁监听了谁处理。
// 语法看点:
//   `#selector(...)` —— 编译期检查的方法引用;`Selector(("字符串"))` 是
//   免检查版(目标方法在别的类里、编译期看不见时用,拼错则运行时找不到)。
//   `keyEquivalent: "d"` = ⌘D;大写 "D" = ⇧⌘D(隐含 Shift)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// 程序化主菜单(全中文)。
/// 注意:没有「编辑」菜单的话 ⌘C/⌘V 只会「嘟」一声——AppKit 靠菜单项把快捷键
/// 派发进 responder chain(copy:/paste: 最终落到 TerminalView)。
/// 「主题」菜单动态生成(NSMenuDelegate = AppDelegate),点击即切换配置。
enum MainMenu {
    /// 动态菜单的稳定标识(delegate 靠它分流,不受界面语言影响)
    static let themeMenuID = NSUserInterfaceItemIdentifier("YeTerm.themeMenu")
    static let serverMenuID = NSUserInterfaceItemIdentifier("YeTerm.serverMenu")

    static func build(themeMenuDelegate: NSMenuDelegate?) -> NSMenu {
        let main = NSMenu()

        // ── App 菜单 ──
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于 YeTerm"), action: Selector(("showAboutAction:")), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("设置…"), action: Selector(("openSettings:")), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 YeTerm"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ── 文件 ──
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("文件"))
        fileMenu.addItem(withTitle: L("新建窗口"), action: Selector(("newWindowAction:")), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L("新建标签页"), action: Selector(("newTabAction:")), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        // 截图/录 GIF(v1.2 #7):含机壳的 CRT 同源渲染,存桌面
        fileMenu.addItem(withTitle: L("导出 CRT 截图"), action: Selector(("exportScreenshotAction:")), keyEquivalent: "S")
        fileMenu.addItem(withTitle: L("录制 GIF(开始/停止)"), action: Selector(("toggleGIFRecordingAction:")), keyEquivalent: "R")
        fileMenu.addItem(.separator())
        // ⌘W 语义(2026-08-06 窗口内多标签):先关标签,最后一个标签才关窗
        // (Terminal.app 惯例);⇧⌘W 永远整窗(全部标签一起,关机动画照旧)
        fileMenu.addItem(withTitle: L("关闭标签页"), action: Selector(("closeTabAction:")), keyEquivalent: "w")
        let closeWin = fileMenu.addItem(withTitle: L("关闭窗口"),
                                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // ── 编辑 ──
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // 查找(v1.1 #4):荧光搜索条,回车下一个 / ⇧回车上一个 / Esc 关闭
        editMenu.addItem(withTitle: L("查找…"), action: Selector(("showSearchAction:")), keyEquivalent: "f")
        editMenu.addItem(withTitle: L("查找下一个"), action: Selector(("findNextAction:")), keyEquivalent: "g")
        editMenu.addItem(withTitle: L("查找上一个"), action: Selector(("findPreviousAction:")), keyEquivalent: "G")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // ── 主题(动态:系统预设 + 我的配置,当前项打勾)──
        let themeItem = NSMenuItem()
        let themeMenu = NSMenu(title: L("主题"))
        // ⚠️ 动态菜单靠 identifier 分流,**不能**用 title —— title 现在会跟着
        //    界面语言变,英文模式下按标题比对必然失配(i18n 时踩到的坑)。
        themeMenu.identifier = MainMenu.themeMenuID
        themeMenu.delegate = themeMenuDelegate
        themeItem.submenu = themeMenu
        main.addItem(themeItem)

        // ── 分屏 ──
        let splitItem = NSMenuItem()
        let splitMenu = NSMenu(title: L("分屏"))
        splitMenu.addItem(withTitle: L("向右分屏"), action: Selector(("splitRightAction:")), keyEquivalent: "d")
        splitMenu.addItem(withTitle: L("向下分屏"), action: Selector(("splitDownAction:")), keyEquivalent: "D")
        splitMenu.addItem(withTitle: L("下一个分屏"), action: Selector(("focusNextPaneAction:")), keyEquivalent: "]")
        splitItem.submenu = splitMenu
        main.addItem(splitItem)

        // ── 命令(v1.2 #3:OSC 133 命令导航;需安装 shell 集成)──
        // 【学】keyEquivalent 用箭头键:传 Unicode 功能键字符(NSUpArrowFunctionKey)
        let cmdItem = NSMenuItem()
        let cmdMenu = NSMenu(title: L("命令"))
        let up = cmdMenu.addItem(withTitle: L("上一条命令"),
                                 action: Selector(("previousCommandAction:")), keyEquivalent: "\u{F700}")
        up.keyEquivalentModifierMask = [.command]
        let down = cmdMenu.addItem(withTitle: L("下一条命令"),
                                   action: Selector(("nextCommandAction:")), keyEquivalent: "\u{F701}")
        down.keyEquivalentModifierMask = [.command]
        cmdMenu.addItem(withTitle: L("复制上条命令输出"),
                        action: Selector(("copyLastOutputAction:")), keyEquivalent: "C")
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(withTitle: L("安装 Shell 集成…"),
                        action: Selector(("installShellIntegrationAction:")), keyEquivalent: "")
        cmdItem.submenu = cmdMenu
        main.addItem(cmdItem)

        // ── 显示 ──
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L("显示"))
        viewMenu.addItem(withTitle: L("开关 CRT 特效"), action: Selector(("toggleCRTEffects:")), keyEquivalent: "e")
        // 消磁(v1.2 #13):⇧⌘M;点机壳边框也能触发(彩蛋)
        viewMenu.addItem(withTitle: L("消磁"), action: Selector(("degaussAction:")), keyEquivalent: "M")
        // OSD 调节面板(v1.2 #14):⌥⌘O,仿 CRT 显示器屏上菜单
        let osdItem = viewMenu.addItem(withTitle: L("OSD 调节面板"),
                                       action: Selector(("osdAction:")), keyEquivalent: "o")
        osdItem.keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // ── 服务器(v1.3 SSH)──
        // 内容动态生成(delegate = AppDelegate,menuNeedsUpdate 按标题分流):
        // 每台远程主机一项点击即连 + 服务器选单 ⇧⌘O + 管理入口
        let serverItem = NSMenuItem()
        let serverMenu = NSMenu(title: L("服务器"))
        serverMenu.identifier = MainMenu.serverMenuID
        serverMenu.delegate = themeMenuDelegate
        serverItem.submenu = serverMenu
        main.addItem(serverItem)

        // ── 窗口 ──
        // 标签页项自建(2026-08-06 起标签由窗口内自管,原生 window tabbing 已弃用;
        // AppDelegate 里 allowsAutomaticWindowTabbing=false,AppKit 不再往这里
        // 自动插英文的 Show All Tabs / Merge All Windows 等)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: L("显示下一个标签页"),
                                         action: Selector(("nextTabAction:")), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let prevTab = windowMenu.addItem(withTitle: L("显示上一个标签页"),
                                         action: Selector(("previousTabAction:")), keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        // ⌘1~⌘9 直达第 N 个标签页(用户需求;tag = 目标下标,validate 按标签数启停)
        windowMenu.addItem(.separator())
        for n in 1...9 {
            let item = windowMenu.addItem(withTitle: Lf("标签页 %d", n),
                                          action: Selector(("selectTabNumberAction:")),
                                          keyEquivalent: "\(n)")
            item.tag = n - 1
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L("前置全部窗口"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
