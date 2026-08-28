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

        // 2026-08-06 起 ⌘T = **窗口内标签**(原生 window tabbing 已弃用):
        // 窗口数不变,key 窗的 tabs 多一页且成为活动页
        delegate.newTabAction(nil)
        pump(0.6)
        check("⌘T 后窗口数不变(仍 2)", termWindows().count == 2,
              detail: "count=\(termWindows().count)")
        let tabbedWC = NSApp.windows
            .compactMap { $0.windowController as? TerminalWindowController }
            .first { $0.tabs.count == 2 }
        check("⌘T 在窗口内建出第 2 个标签", tabbedWC != nil)
        check("新标签成为活动标签", tabbedWC?.activeTabIndex == 1,
              detail: "active=\(tabbedWC?.activeTabIndex ?? -1)")
        check("每个标签一个 pane、共 2 个 shell", tabbedWC?.panes.count == 2,
              detail: "panes=\(tabbedWC?.panes.count ?? -1)")
        // ── 标签栏双样式(2026-08-06):机壳生效 = CRT 盒绘条;否则液态玻璃条 ──
        // 先把样式判定的前提钉死(别的机器上用户配置可能关着 CRT/机壳)
        delegate.settingsModel.crtEffectsEnabled = true
        delegate.settingsModel.frameEnabled = true
        pump(0.5)
        check("机壳生效时盒绘标签条上屏", tabbedWC?.crtTabBarVisibleForTesting == true)
        let tabBarShot = NSTemporaryDirectory() + "yeterm-window-probe-tabbar.png"
        _ = tabbedWC?.overlayForTesting?.dumpFrame(to: tabBarShot)
        print("frame: \(tabBarShot)")
        delegate.settingsModel.crtEffectsEnabled = false
        pump(0.5)
        check("普通模式切液态玻璃标签条",
              tabbedWC?.glassTabBarVisibleForTesting == true
                  && tabbedWC?.crtTabBarVisibleForTesting != true)
        let glassShot = NSTemporaryDirectory() + "yeterm-window-probe-glassbar.png"
        _ = tabbedWC?.overlayForTesting?.dumpFrame(to: glassShot)
        print("frame: \(glassShot)")
        // 机壳关(普通模式)→ 无机壳带,底部间隙 = 窗级留白,不许多让(反向回归)
        if let g = tabbedWC?.caseBandGeometryForTesting {
            check("普通模式底部不让机壳带",
                  !g.frameOn && abs(g.bottomGap - g.marginInset) < 0.6,
                  detail: String(format: "bottomGap=%.1f margin=%.1f frameOn=%d",
                                 g.bottomGap, g.marginInset, g.frameOn ? 1 : 0))
        }
        delegate.settingsModel.crtEffectsEnabled = true
        pump(0.5)
        check("CRT 恢复后回盒绘条", tabbedWC?.crtTabBarVisibleForTesting == true)

        // 六款盒绘条样式(2026-08-07):逐一切换渲染出帧(目检)+ 断言在场
        for s in 0...5 {
            delegate.settingsModel.crtTabBarStyle = s
            pump(0.4)
            check("盒绘条样式 \(s) 在场", tabbedWC?.crtTabBarVisibleForTesting == true)
            let styleShot = NSTemporaryDirectory() + "yeterm-window-probe-tabbar-style\(s).png"
            _ = tabbedWC?.overlayForTesting?.dumpFrame(to: styleShot)
            print("frame: \(styleShot)")
        }
        delegate.settingsModel.crtTabBarStyle = 0
        pump(0.3)

        // 命中修正(2026-08-07 用户实测:弧度把顶部内容"下顶",极简块/翻页卡这类
        // 矮条几乎整条点不中):点击点须过与 shader 同一套弧度/内缩映射。
        // 断言:弧度全开时,条正下方一点经映射后**向上**进入条的纹理区间;
        // 关掉弧度(机壳仍开→仍有最小带内缩)时映射不应产生弧度那么大的位移
        delegate.settingsModel.curvature = 1.0
        pump(0.5)
        if let ov = tabbedWC?.overlayForTesting, let r = tabbedWC?.crtTabBarRectForTesting {
            let below = CGPoint(x: r.midX, y: r.minY - 6)
            let mapped = ov.contentPoint(fromViewPoint: below)
            check("弧度下条命中映射向上修正进区间", mapped.y > below.y && r.contains(mapped),
                  detail: String(format: "below.y=%.1f mapped.y=%.1f rect=%.1f..%.1f",
                                 below.y, mapped.y, r.minY, r.maxY))
        } else {
            check("命中映射测试前置(overlay/条命中区在场)", false)
        }
        // 机壳最小带让位(2026-08-10 用户实测「弧度时最下方内容被吃」回归):
        // 机壳开启时 shader 把玻璃区上下各内缩一条 = 标题栏高的机壳带,内容纹理
        // 最底那条带永不上屏 —— 文字区底部必须让出同高的带(顶部一直有 topBar
        // 让位,底部曾漏,最后一行文字正落在永不显示的带里)。
        // 精确断言:机壳开 → 底部间隙 = 窗级留白 + 带高
        if let g = tabbedWC?.caseBandGeometryForTesting {
            check("机壳开时文字区底部让出机壳带",
                  g.frameOn && g.bandH > 0 && abs(g.bottomGap - (g.marginInset + g.bandH)) < 0.6,
                  detail: String(format: "bottomGap=%.1f margin=%.1f bandH=%.1f frameOn=%d",
                                 g.bottomGap, g.marginInset, g.bandH, g.frameOn ? 1 : 0))
        } else {
            check("机壳带让位取证前置(窗口在场)", false)
        }
        delegate.settingsModel.curvature = 0
        pump(0.4)

        // ── 回归(2026-08-07 用户实测三连 bug):切标签重影 / 输入不可见 / 焦点 ──
        // tab2 活动期间给 tab1 的 shell 灌输出(后台标签内容照样变),再切回:
        // 画面必须是 tab1 的**完整现状**,焦点必须回到 tab1 的 pane
        let t1pane = tabbedWC?.tabs[0].panes.first
        t1pane?.terminalView.send(txt: "echo GHOST-CHECK\n")
        pump(0.8)

        // ⌘1 直达切回第 1 页
        tabbedWC?.selectTab(0)
        pump(0.8)
        check("selectTab(0) 切回第 1 页", tabbedWC?.activeTabIndex == 0)
        check("切回后活动 pane 只剩标签 1 的", tabbedWC?.activePanes.count == 1)
        check("切回后焦点在 tab1 的 pane(否则打字进隐形的 tab2)",
              tabbedWC?.window?.firstResponder === t1pane?.terminalView,
              detail: "firstResponder=\(type(of: tabbedWC?.window?.firstResponder as Any))")
        let ghostShot = NSTemporaryDirectory() + "yeterm-window-probe-ghost.png"
        _ = tabbedWC?.overlayForTesting?.dumpFrame(to: ghostShot)
        print("frame: \(ghostShot)")
        // 合成只许画**活动标签**的 pane(重影事故的回归断言:后台 pane 混进
        // draws 就是全屏重影 + 打字被盖住)
        check("合成布局只含活动标签的 1 个 pane",
              tabbedWC?.overlayForTesting?.layoutProvider?().panes.count == 1,
              detail: "panes=\(tabbedWC?.overlayForTesting?.layoutProvider?().panes.count ?? -1)")
        let ghostComp = NSTemporaryDirectory() + "yeterm-window-probe-ghost-composite.png"
        tabbedWC?.overlayForTesting?.dumpDrawsOnNextCapture = true
        _ = tabbedWC?.overlayForTesting?.dumpComposite(to: ghostComp)
        print("frame: \(ghostComp)")
        print("  [几何] \(tabbedWC?.tabBarGeometryForTesting ?? "nil")")
        if let t = t1pane?.terminalView.getTerminal() {
            for row in 0..<min(5, t.rows) {
                guard let line = t.getLine(row: row) else { continue }
                var s = ""
                for col in 0..<t.cols {
                    let ch = t.getCharacter(for: line[col])
                    if ch != "\0" { s.append(ch) }
                }
                print("  [t1 屏 r\(row)] \(s.trimmingCharacters(in: .whitespaces))")
            }
            print("  [t1 尺寸] cols=\(t.cols) rows=\(t.rows)")
        }
        // 关掉后台那页 → shell 终止、标签回收
        tabbedWC?.closeTab(at: 1)
        pump(0.6)
        check("关标签后剩 1 页", tabbedWC?.tabs.count == 1,
              detail: "tabs=\(tabbedWC?.tabs.count ?? -1)")
        check("窗口仍在(关的是标签不是窗)", termWindows().count == 2,
              detail: "count=\(termWindows().count)")

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

        // ---- 恢复竞态回归(2026-08-26 用户实测「恢复后分屏压叠」)----
        // 病灶:buildTree 在 splitHost 0×0 时建树,NSSplitView 首次 tiling 按子视图
        // 现有尺寸比例分配 → 0 尺寸子树分到 0 宽、旁边默认 frame 的 pane 铺满压住它;
        // applyRestoredRatios 那记异步若跑在首次布局之前(量不到宽高被留档),
        // 活动标签无人重试 → 压叠永久保留。修法 = buildTree 权重播种 +
        // RootView.onLayout 补应用。这里故意把比例应用打在 showWindow 之前
        // (复刻竞态输的一侧),布局必须仍收敛:不退化、不压叠、纹理不越界、比例正确。
        let raceTree = SessionState.LayoutNode.split(vertical: true, weights: [1269.5, 1275.5], children: [
            .pane(cwd: nil),
            .split(vertical: false, weights: [631.5, 749.5],
                   children: [.pane(cwd: nil), .pane(cwd: nil)]),
        ])
        let raceWC = delegate.makeWindow(restore: .init(frame: [60, 60, 1280, 800], layout: raceTree))
        raceWC.applyRestoredRatios()   // 竞态复刻:比例应用先于窗口首次布局
        raceWC.showWindow(nil)
        pump(1.2)
        let racePanes = raceWC.panes
        check("竞态恢复 3 pane", racePanes.count == 3, detail: "panes=\(racePanes.count)")
        let raceRects = racePanes.map { $0.convert($0.bounds, to: nil) }
        check("竞态恢复无退化 pane", raceRects.allSatisfy { $0.width > 50 && $0.height > 50 },
              detail: raceRects.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: " | "))
        var raceOverlap = false
        for i in 0..<raceRects.count {
            for j in (i + 1)..<raceRects.count {
                let inter = raceRects[i].intersection(raceRects[j])
                if inter.width > 1, inter.height > 1 { raceOverlap = true }
            }
        }
        check("竞态恢复 pane 互不压叠", !raceOverlap)
        let raceScale = raceWC.window?.backingScaleFactor ?? 2
        var texFits = true
        var texDetail = ""
        for p in racePanes {
            let cell = GlyphAtlas.cellSize(font: p.terminalView.font, scale: raceScale)
            let t = p.terminalView.getTerminal()
            if CGFloat(t.cols * cell.w) > p.terminalView.frame.width * raceScale + 2
                || CGFloat(t.rows * cell.h) > p.terminalView.frame.height * raceScale + 2 {
                texFits = false
            }
            texDetail += "(\(t.cols)x\(t.rows))"
        }
        check("竞态恢复纹理不越出 pane", texFits, detail: texDetail)
        if racePanes.count == 3 {
            // 内层上下比例应收敛到存档权重 631.5:749.5(占比 0.457,容差 5%)
            let h1 = racePanes[1].frame.height, h2 = racePanes[2].frame.height
            let frac = min(h1, h2) / max(h1 + h2, 1)
            check("竞态恢复分屏比例收敛", abs(frac - 631.5 / 1381.0) < 0.05,
                  detail: String(format: "h=%.0f/%.0f 小侧占比=%.3f(期望 0.457)", h1, h2, frac))
        }
        raceWC.window?.close()
        pump(0.5)

        // ---- 连环关 pane 回归(2026-08-28 用户实测「⌘D×3 成 4 屏,关 #4 再关 #1
        // → 终端内容全部消失,窗底剩半截光标,再 ⌃D 才恢复」)----
        // 手势复刻:⌘D 每次劈开焦点 pane 且焦点跟去新 pane → 全右劈得
        // sv1[p1, sv2[p2, sv3[p3, p4]]];关 #4 是「幸存者=pane」塌缩(旧探针
        // 已覆盖),关 #1 走的是**树根塌缩、幸存者=NSSplitView 接任树根**分支
        // (此前探针从没踩过)。断言分两层:几何(pane 铺满互不压叠)+
        // **活路径**像素(debugRenderTick + dumpCompositeAsIs,不强制重捕获 ——
        // dumpFrame 会 performCapture 把「活画面卡死」类 bug 当场修好藏掉)。
        /// **活路径**像素统计(debugRenderTick + dumpCompositeAsIs,不强制重捕获
        /// —— dumpFrame 会 performCapture 把「活画面卡死」类 bug 当场修好藏掉)。
        /// 返回 (左/上半, 右/下半) 亮像素数;axis: true=左右分,false=上下分
        func liveHalves(_ wc: TerminalWindowController, tag: String,
                        splitLeftRight: Bool) -> (a: Int, b: Int) {
            guard let ov = wc.overlayForTesting else { return (-1, -1) }
            var t = 0.0
            while t < 1.5 {
                ov.debugRenderTick(skipOcclusionCheck: true)
                pump(0.05)
                t += 0.05
            }
            let compPath = NSTemporaryDirectory() + "yeterm-window-probe-\(tag).png"
            guard ov.dumpCompositeAsIs(to: compPath),
                  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: compPath) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return (-1, -1) }
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let info = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let cg = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: info) else { return (-1, -1) }
            cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            var a = 0, b = 0
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 350 {
                        if splitLeftRight ? (x < w / 2) : (y < h / 2) { a += 1 } else { b += 1 }
                    }
                }
            }
            print("  [\(tag)] 活帧 lit=(\(a), \(b)) 帧=\(compPath)")
            return (a, b)
        }
        func paneRectsSane(_ wc: TerminalWindowController, name: String) {
            let rects = wc.panes.map { $0.convert($0.bounds, to: nil) }
            check("\(name):pane 几何无退化",
                  rects.allSatisfy { $0.width > 50 && $0.height > 50 },
                  detail: rects.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: " | "))
            var overlap = false
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    let inter = rects[i].intersection(rects[j])
                    if inter.width > 1, inter.height > 1 { overlap = true }
                }
            }
            check("\(name):pane 互不压叠", !overlap)
        }

        // ---- 连环关 pane 回归 A:用户原手势(2026-08-28 实测「⌘D×3 成 4 屏,
        // 关 #4 再关 #1 → 内容全消失,窗底剩半截光标」)。同方向扁平化后
        // ⌘D×3 = 一个 4 子视图的平树,顺带断言扁平化与焦点接位新行为 ----
        let chainWC = delegate.newWindowForTesting()
        pump(1.0)
        for _ in 0..<3 {
            chainWC.splitRightAction(nil)
            pump(0.6)
        }
        check("连环A:⌘D×3 后 4 pane", chainWC.panes.count == 4,
              detail: "panes=\(chainWC.panes.count)")
        // 扁平化(2026-08-28 分屏优化):同向连续分屏不再一刀一层嵌套,
        // 树根就是一个 4 子视图的 NSSplitView(深嵌套约束树 = 崩溃报告病灶)
        let chainRoot = chainWC.activeRootViewForTesting as? NSSplitView
        check("连环A:同向分屏扁平化(树根 4 子视图)",
              chainRoot?.arrangedSubviews.count == 4,
              detail: "subs=\(chainRoot?.arrangedSubviews.count ?? -1)")
        check("连环A:焦点跟随到 #4", chainWC.focusedPane === chainWC.panes.last)
        // 最小尺寸闸(2026-08-28):逮着焦点连刀是指数变窄的,第 4 刀要切的
        // pane 只剩 ~118pt,对半 59 < 80 必被拒 —— 2pt 宽 pane 时代的回归
        chainWC.splitRightAction(nil)
        pump(0.4)
        check("连环A:第 4 刀被最小尺寸闸拦下", chainWC.panes.count == 4,
              detail: "panes=\(chainWC.panes.count) 最窄=\(Int(chainWC.panes.map { $0.bounds.width }.min() ?? 0))pt")
        // ⌃D 关 #4(交互 zsh 只认 exit;⌃D=EOF 同义)→ 焦点应落邻居 #3,
        // 不再跳回 #1(旧行为 panes.first,用户实测反直觉)
        chainWC.panes.last?.terminalView.send(txt: "exit\n")
        pump(1.5)
        check("连环A:关 #4 后 3 pane", chainWC.panes.count == 3,
              detail: "panes=\(chainWC.panes.count)")
        check("连环A:关 #4 后焦点落邻居 #3",
              chainWC.focusedPane === chainWC.panes.last,
              detail: "焦点=#\((chainWC.panes.firstIndex { $0 === chainWC.focusedPane } ?? -2) + 1)")
        chainWC.panes.first?.terminalView.send(txt: "exit\n")
        pump(1.5)
        check("连环A:关 #1 后 2 pane", chainWC.panes.count == 2,
              detail: "panes=\(chainWC.panes.count)")
        paneRectsSane(chainWC, name: "连环A")
        check("连环A:合成布局含 2 个 pane",
              chainWC.overlayForTesting?.layoutProvider?().panes.count == 2,
              detail: "panes=\(chainWC.overlayForTesting?.layoutProvider?().panes.count ?? -1)")
        let halvesA = liveHalves(chainWC, tag: "chainA", splitLeftRight: true)
        check("连环A:活画面左半有文字", halvesA.a > 300, detail: "lit=\(halvesA.a)")
        check("连环A:活画面右半有文字", halvesA.b > 300, detail: "lit=\(halvesA.b)")
        chainWC.window?.close()
        pump(0.5)

        // ---- 连环关 pane 回归 B:混合方向逼出**树根塌缩、幸存者=NSSplitView
        // 接任树根**分支(原 bug 病灶:约束世代 NSSplitView 收编 arranged
        // subview 时设 translates=false,幸存者摘出重挂后被约束引擎解算成
        // 0 高 → 内容全灭;扁平化后纯同向手势不再走这支,必须专门钉住)----
        let chainB = delegate.newWindowForTesting()
        pump(1.0)
        chainB.splitRightAction(nil)   // sv1[p1, p2]
        pump(0.6)
        chainB.splitDownAction(nil)    // sv1[p1, sv2[p2, p3]]
        pump(0.6)
        check("连环B:⌘D+⇧⌘D 后 3 pane", chainB.panes.count == 3,
              detail: "panes=\(chainB.panes.count)")
        chainB.panes.first?.terminalView.send(txt: "exit\n")   // 关 #1 → sv2 接任树根
        pump(1.5)
        check("连环B:关 #1 后 2 pane", chainB.panes.count == 2,
              detail: "panes=\(chainB.panes.count)")
        check("连环B:幸存 NSSplitView 接任树根",
              chainB.activeRootViewForTesting is NSSplitView)
        paneRectsSane(chainB, name: "连环B")
        let halvesB = liveHalves(chainB, tag: "chainB", splitLeftRight: false)
        check("连环B:活画面上半有文字", halvesB.a > 300, detail: "lit=\(halvesB.a)")
        check("连环B:活画面下半有文字", halvesB.b > 300, detail: "lit=\(halvesB.b)")

        // ---- 分屏上限(2026-08-28 用户裁决 10;按住 ⌘D 连发曾深嵌套崩溃)----
        // 每刀切**面积最大**的 pane、按形状选方向(实际用户把屏幕铺成网格的
        // 合理手势;逮着同一焦点连刀会更早撞上最小尺寸闸 —— 那是另一条断言)
        while chainB.panes.count < 10 {
            let before = chainB.panes.count
            if let largest = chainB.panes.max(by: {
                $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
            }) {
                for _ in 0..<chainB.panes.count where chainB.focusedPane !== largest {
                    chainB.focusNextPaneAction(nil)
                }
                if largest.bounds.width > largest.bounds.height {
                    chainB.splitRightAction(nil)
                } else {
                    chainB.splitDownAction(nil)
                }
            }
            pump(0.4)
            if chainB.panes.count == before { break }   // 防死循环(闸拦下即止)
        }
        check("上限:分到 10 pane", chainB.panes.count == 10,
              detail: "panes=\(chainB.panes.count)")
        chainB.splitRightAction(nil)
        pump(0.4)
        check("上限:第 11 刀被拒", chainB.panes.count == 10,
              detail: "panes=\(chainB.panes.count)")
        paneRectsSane(chainB, name: "上限 10 屏")
        // 扁平化的 N 子 split 节点走一遍快照(buildTree/权重链路天生支持 N 子,
        // 但此前只有 2 子档案在跑 —— 钉住)
        if let snap = chainB.snapshotState() {
            func leaves10(_ n: SessionState.LayoutNode) -> Int {
                switch n {
                case .pane: return 1
                case .split(_, _, let ch): return ch.map(leaves10).reduce(0, +)
                }
            }
            check("上限:10 屏快照叶子数 10", leaves10(snap.layout) == 10,
                  detail: "leaves=\(leaves10(snap.layout))")
        } else {
            check("上限:10 屏快照生成", false)
        }

        // ---- tab 中键关闭(2026-08-28 用户需求;盒绘条命中链路)----
        chainB.newTab()
        pump(0.8)
        check("中键:新标签后 2 页", chainB.tabs.count == 2)
        check("中键:盒绘条在场", chainB.crtTabBarVisibleForTesting,
              detail: "rect=\(String(describing: chainB.crtTabBarRectForTesting))")
        if let bar = chainB.crtTabBarRectForTesting {
            chainB.middleClickTabBarForTesting(atX: bar.width * 0.75)   // 右半 = 第 2 页
            pump(0.8)
        }
        check("中键:中键点第 2 格关回 1 页", chainB.tabs.count == 1,
              detail: "tabs=\(chainB.tabs.count)")
        chainB.window?.close()
        pump(0.5)

        print(pass ? "WINDOW-PROBE-PASS" : "WINDOW-PROBE-FAIL")
        return pass ? 0 : 1
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
