// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 多窗口/分屏行为探针(自测体系 3/5)
//
// 这个文件:程序化按 ⌘N/⌘T/⌘D,断言窗口数、标签分组、分屏树的收缩,
//   最后在三分屏状态导出一帧合成画面(荧光分割线目检用)。
//   check(名字, 条件) 这种自造微型断言函数 —— 没引测试框架,
//   几行代码就够用(工程取舍:自测脚本要的是零依赖跑得快)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// M2 自测:多窗口/标签装配探针(--probe-windows)。
/// 程序化驱动 AppDelegate 的 ⌘N/⌘T 路径,断言窗口数量与标签分组。
public enum WindowProbe {
    public static func run(options: LaunchOptions) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        // 探针隔离(v1.2 #2):不读用户真实 session.json 恢复(窗口数断言会被污染)、
        // 不写用户配置盘 —— 探针铁律:决不碰真实数据
        delegate.settingsModel.persistenceEnabled = false
        delegate.settingsModel.restoreSession = false
        delegate.settingsModel.bootSelfTest = false   // 自检屏会顶掉 pane 合成,探针不看它
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        pump(1.0)

        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        // ---- 会话记忆纯逻辑断言(v1.2 #2,不碰磁盘)----
        let tree = SessionState.LayoutNode.split(vertical: true, weights: [400, 600], children: [
            .pane(cwd: "/tmp"),
            .split(vertical: false, weights: [1, 1], children: [.pane(cwd: nil), .pane(cwd: "/usr")]),
        ])
        let state = SessionState(windows: [.init(frame: [10, 20, 800, 600], layout: tree)])
        // 【学】JSON 对象的键序无保证(哈希+地址随机化),字节比较必须先 .sortedKeys 归一
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let rt: SessionState? = (try? enc.encode(state))
            .flatMap { try? JSONDecoder().decode(SessionState.self, from: $0) }
        let rtJSON = rt.flatMap { try? enc.encode($0) }
        check("会话存档编解码往返一致",
              rtJSON != nil && rtJSON == (try? enc.encode(state)))
        check("proc 查 cwd(自身进程)",
              SessionStore.cwdOf(pid: getpid()) == FileManager.default.currentDirectoryPath,
              detail: SessionStore.cwdOf(pid: getpid()) ?? "nil")

        func termWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.tabbingIdentifier == NSWindow.TabbingIdentifier("YeTermTerminal") && $0.isVisible }
        }

        check("初始 1 个终端窗口", termWindows().count == 1, detail: "count=\(termWindows().count)")

        delegate.newWindowAction(nil)
        pump(0.6)
        check("⌘N 后 2 个终端窗口", termWindows().count == 2, detail: "count=\(termWindows().count)")
        let maxGroupAfterN = termWindows().map { $0.tabGroup?.windows.count ?? 1 }.max() ?? 1
        check("⌘N 是独立窗口(未被并组)", maxGroupAfterN <= 1, detail: "maxGroup=\(maxGroupAfterN)")

        delegate.newTabAction(nil)
        pump(0.6)
        let windows = termWindows()
        check("⌘T 后 3 个终端会话", windows.count == 3, detail: "count=\(windows.count)")
        let grouped = windows.first { ($0.tabGroup?.windows.count ?? 0) == 2 }
        check("⌘T 并入恰 2 窗的标签分组", grouped != nil,
              detail: "groups=\(Set(windows.map { $0.tabGroup?.windows.count ?? 1 }))")

        // 关一个标签 → 会话应回收
        grouped?.tabGroup?.selectedWindow?.close()
        pump(0.6)
        check("关标签后剩 2 个会话", termWindows().count == 2, detail: "count=\(termWindows().count)")

        // ---- 分屏(M2 后半) ----
        guard let wc = (NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }).first else {
            check("找到终端窗口控制器", false)
            print("WINDOW-PROBE-FAIL")
            return 1
        }
        wc.splitRightAction(nil)
        pump(0.8)
        check("⌘D 左右分屏后 2 个 pane", wc.panes.count == 2, detail: "panes=\(wc.panes.count)")
        wc.splitDownAction(nil)
        pump(0.8)
        check("⇧⌘D 再分后 3 个 pane", wc.panes.count == 3, detail: "panes=\(wc.panes.count)")
        wc.focusNextPaneAction(nil)
        pump(0.2)
        // 3-pane 状态下真窗快照:树形状 + 每个活 shell 的 cwd 都查得到(v1.2 #2)
        if let snap = wc.snapshotState() {
            func leaves(_ n: SessionState.LayoutNode) -> [String?] {
                switch n {
                case .pane(let c): return [c]
                case .split(_, _, let ch): return ch.flatMap(leaves)
                }
            }
            let ls = leaves(snap.layout)
            check("窗口快照含 3 个 pane 叶子", ls.count == 3, detail: "leaves=\(ls.count)")
            check("快照各 pane cwd 可查", ls.allSatisfy { $0?.isEmpty == false },
                  detail: ls.map { $0 ?? "nil" }.joined(separator: " | "))
            check("快照 frame 有效", snap.frame.count == 4 && snap.frame[2] > 0 && snap.frame[3] > 0)
        } else {
            check("窗口快照生成", false)
        }
        // 单显示器分屏合成:3 pane 状态出一帧(荧光分割线/合成几何目检用)
        let dumpPath = NSTemporaryDirectory() + "yeterm-window-probe-split.png"
        check("分屏合成出帧", wc.overlayForTesting?.dumpFrame(to: dumpPath) ?? false, detail: dumpPath)
        // 正常退出一个 pane 的 shell(交互式 zsh 忽略 SIGTERM,须走 exit)→ 树应收缩
        wc.panes.last?.terminalView.send(txt: "exit\n")
        pump(1.2)
        check("pane 退出后收树剩 2", wc.panes.count == 2, detail: "panes=\(wc.panes.count)")

        // ---- 会话恢复端到端(v1.2 #2):按存档树建窗,断言结构与 cwd 注入 ----
        let restoreTree = SessionState.LayoutNode.split(vertical: true, weights: [1, 1], children: [
            .pane(cwd: "/usr"),
            .split(vertical: false, weights: [2, 1], children: [.pane(cwd: nil), .pane(cwd: "/tmp")]),
        ])
        let restored = delegate.makeWindow(restore:
            .init(frame: [80, 80, 900, 640], layout: restoreTree))
        restored.showWindow(nil)
        pump(0.4)
        restored.applyRestoredRatios()
        pump(1.0)
        check("恢复窗 3 个 pane", restored.panes.count == 3, detail: "panes=\(restored.panes.count)")
        if let snap = restored.snapshotState() {
            func leaves(_ n: SessionState.LayoutNode) -> [String?] {
                switch n {
                case .pane(let c): return [c]
                case .split(_, _, let ch): return ch.flatMap(leaves)
                }
            }
            let ls = leaves(snap.layout)
            // /tmp 在 macOS 是 /private/tmp 的符号链接,内核返回真实路径 → 后缀断言
            check("恢复 pane cwd 注入生效", ls.count == 3
                    && ls[0] == "/usr" && (ls[2]?.hasSuffix("/tmp") ?? false),
                  detail: ls.map { $0 ?? "nil" }.joined(separator: " | "))
        } else {
            check("恢复窗快照", false)
        }
        restored.window?.close()
        pump(0.5)

        print(pass ? "WINDOW-PROBE-PASS" : "WINDOW-PROBE-FAIL")
        return pass ? 0 : 1
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
