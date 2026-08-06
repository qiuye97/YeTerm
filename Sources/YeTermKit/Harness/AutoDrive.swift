// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 真键盘模拟自测(自测体系 2/5)
//
// 这个文件:开一个**真实** GUI 窗口,用 NSEvent 合成键盘事件(和真按键走
//   同一条系统分发链),模拟"疯狂打字/按住方向键",逐段导出画面帧。
//   为什么不直接往终端塞字符?因为有一类 bug(残影/顿挫)只在真实事件
//   洪峰下出现 —— 用户实测教会我们的:测试必须贴近真实输入路径。
// 类比 Web:Selenium/Playwright 的真实浏览器事件 vs 直接改 DOM 的区别。
// 语法看点:`NSEvent.keyEvent(...)` 合成事件 + `NSApp.sendEvent` 注入;
//   RunLoop.main.run(until:) —— 手动泵事件循环,让 UI 在脚本里"活"起来。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm

/// GUI 自动驾驶自测(M1a-3):
///   YeTerm --auto-drive <outPrefix> [--font NAME] [--font-size N]
/// 真实 GUI 窗口 + 真实 PTY shell,程序化模拟「按住键连续输入」等场景,
/// 按节点把「与屏幕同源的渲染」(同 contentTexture、同 uniforms 公式)导出 PNG 帧。
/// 目的:把"只有用户打字才能看到"的动态渲染问题变成我(Claude)自己可见。
public enum AutoDrive {
    private static var frames: [(String, () -> Void)] = []

    public static func run(outPrefix: String, options: LaunchOptions) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 不抢焦点

        let wc = TerminalWindowController(options: options)
        guard let window = wc.window else { return 1 }
        window.orderFront(nil)   // 需要真实 window(backingScale/caret 逻辑)

        guard let tv = wc.terminalViewForTesting, let overlay = wc.overlayForTesting else {
            FileHandle.standardError.write(Data("auto-drive: 组件不可用\n".utf8))
            return 1
        }

        // 等 shell 就绪:轮询屏幕出现稳定的非空提示符行(固定 1.5s 在
        // gitstatusd 被并发测试打挂后不够 —— shell 启动重试拖慢数秒,
        // 后续场景连锁错位,2026-07-29 两次大面积假红的元凶)
        func screenLine() -> String {
            let t = tv.getTerminal()
            for row in stride(from: t.rows - 1, through: 0, by: -1) {
                guard let line = t.getLine(row: row) else { continue }
                var s = ""
                for col in 0..<t.cols {
                    let ch = t.getCharacter(for: line[col])
                    if ch != "\0" { s.append(ch) }
                }
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return ""
        }
        var readyWait = 0.0
        var lastSeen = ""
        while readyWait < 15 {
            pump(0.5)
            readyWait += 0.5
            let now = screenLine()
            if !now.isEmpty && now == lastSeen && readyWait >= 1.5 { break }   // 提示符稳定
            lastSeen = now
        }

        var step = 0
        func snap(_ tag: String) {
            step += 1
            let path = "\(outPrefix)_\(String(format: "%02d", step))_\(tag).png"
            if overlay.dumpFrame(to: path) {
                print("frame: \(path)")
            } else {
                print("frame FAILED: \(tag)")
            }
        }

        // 场景 1:提示符就绪
        snap("prompt")

        // 场景 2:**真实键盘事件**按住 '1'(300 次 key repeat,15ms)
        window.makeKeyAndOrderFront(nil)
        pump(0.1)
        pressKey(window: window, keyCode: 18, character: "1")
        for _ in 0..<299 {
            pressKey(window: window, keyCode: 18, character: "1", isRepeat: true)
            pump(0.015)
        }
        pump(0.3)
        snap("held_key_wrap")

        // 场景 2.5(用户指定复现):**真实键盘事件**长按左方向键横穿(150 步)
        // 密集拍帧 —— 单帧若有多个光标块 = 内容级 bug;每帧一个 = 时序/感知问题
        let leftChar = String(UnicodeScalar(0xF702)!)   // NSLeftArrowFunctionKey
        pressKey(window: window, keyCode: 123, character: leftChar, modifiers: [.function, .numericPad])
        for i in 0..<149 {
            pressKey(window: window, keyCode: 123, character: leftChar,
                     modifiers: [.function, .numericPad], isRepeat: true)
            pump(0.015)
            if i % 10 == 9 { snap("hold_left_\(i)") }
        }
        pump(0.3)
        snap("hold_left_done")

        // 场景 3:退格连删 30 个
        for _ in 0..<30 {
            tv.send(txt: "\u{7f}")
            pump(0.03)
        }
        pump(0.3)
        snap("after_backspace")

        // 场景 4:清行 + 中文回显 + 光标移动
        tv.send(txt: "\u{15}")            // ^U 清行
        pump(0.2)
        tv.send(txt: "echo 你好世界测试")
        pump(0.3)
        snap("cjk_typed")
        for _ in 0..<5 { tv.send(txt: "\u{1b}[D"); pump(0.03) }   // 左移 5 格(zle 内)
        pump(0.3)
        snap("cursor_moved_left")

        // 场景 5:执行命令,产生滚动输出
        tv.send(txt: "\u{15}seq 1 100\n")
        pump(0.8)
        snap("after_scroll_output")

        // 场景 5.5:光标快速左右横跳(残影/卡顿回归场景,用户实测反馈)
        tv.send(txt: "echo abcdefghijklmnopqrstuvwxyz")
        pump(0.3)
        // 判别实验:逐移动拍帧 —— 若单帧含多个光标块则为内容级 bug;每帧一个则为时序/感知问题
        for i in 0..<6 {
            tv.send(txt: "\u{1b}[D")
            pump(0.02)
            snap("midmove_\(i)")
        }
        for _ in 0..<14 { tv.send(txt: "\u{1b}[D"); pump(0.01) }
        pump(0.2)
        snap("rapid_left_20")
        for _ in 0..<10 { tv.send(txt: "\u{1b}[C"); pump(0.01) }
        pump(0.2)
        snap("rapid_right_10")
        tv.send(txt: "\u{15}")
        pump(0.2)

        // 场景 6:内核藏光标(DECTCEM)→ 应消失;恢复 → 应回来(镜像 caretView 的正确性)
        tv.send(txt: "printf '\\e[?25l'\n")
        pump(0.5)
        snap("cursor_hidden")
        tv.send(txt: "printf '\\e[?25h'\n")
        pump(0.5)
        snap("cursor_shown")

        // 场景 7(v1.1 #4):⌘F 搜索全链 —— 唤出搜索条、真键盘敲 "50"
        // (增量搜索命中 seq 输出里的 50)、断言选区命中、Esc 关闭后清空还焦
        var searchOK = true
        wc.showSearchAction(nil)
        pump(0.3)
        pressKey(window: window, keyCode: 23, character: "5")
        pump(0.15)
        pressKey(window: window, keyCode: 29, character: "0")
        pump(0.5)
        let hit = tv.selectionSnapshot != nil
        print(hit ? "✓ 搜索命中(选区已设)" : "✗ 搜索未命中")
        if !hit { searchOK = false }
        snap("search_hit_50")
        // 搜索条是普通 AppKit 视图(不进 CRT 管线,dumpFrame 拍不到)——
        // 用 cacheDisplay 拍整窗层级目检它的布局与配色(Metal 层拍出来是黑,无碍)
        if let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let p = "\(outPrefix)_searchbar_ui.png"
                try? data.write(to: URL(fileURLWithPath: p))
                print("frame: \(p)")
            }
        }
        pressKey(window: window, keyCode: 53, character: "\u{1b}")   // Esc
        pump(0.3)
        let cleared = tv.selectionSnapshot == nil
        let focusBack = window.firstResponder === tv
        print(cleared && focusBack ? "✓ 关闭搜索:选区清空 + 焦点还给终端"
                                   : "✗ 关闭搜索异常 cleared=\(cleared) focusBack=\(focusBack)")
        if !cleared || !focusBack { searchOK = false }
        snap("search_closed")

        // 场景 8(v1.1 #5):⌘点击链接 —— 回显 URL、在网格中定位、合成 ⌘鼠标点击,
        // 断言走到 requestOpenLink(onOpenLink 钩子拦截,不真弹浏览器)。
        // 这同时是 linkHighlightSnapshot(Mirror 反射)的哨兵:上游属性布局变了立刻红。
        var linkOK = true
        tv.send(txt: "echo https://example.com/yeterm\n")
        pump(0.8)
        let terminal = tv.getTerminal()
        var linkPos: (row: Int, col: Int)?
        for row in (0..<terminal.rows).reversed() {           // 从底往上找最近一处
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            for c in 0..<terminal.cols { text.append(terminal.getCharacter(for: line[c])) }
            if let r = text.range(of: "https://example.com/yeterm") {
                linkPos = (row, text.distance(from: text.startIndex, to: r.lowerBound))
                break
            }
        }
        if let pos = linkPos {
            var opened: String?
            tv.onOpenLink = { opened = $0 }
            // cell 尺寸必须取 SwiftTerm 真实值(getOptimalFrameSize = cellDimension×行列数):
            // 曾用 tv.frame÷行列数估算 —— 字体格子与窗口不整除时(如 Apple ][ 预设的
            // Print Char 21)view 有边角余量,行高估算偏大,累计到屏幕底部差出数行,
            // 点空导致本场景假红(2026-07-27 用户切预设后现形;探针读真实 config 之故)。
            let optimal = tv.getOptimalFrameSize()
            let cellH = optimal.height / CGFloat(terminal.rows)
            let cellW = optimal.width / CGFloat(terminal.cols)
            // 点进 URL 内部第 4 列的格中心(半格容错;AppKit y 轴向上,行 0 在顶,
            // SwiftTerm 行换算基于 frame.height - y,故 y 仍从 tv.frame.height 翻转)
            let local = NSPoint(x: (CGFloat(pos.col) + 3.5) * cellW,
                                y: tv.frame.height - (CGFloat(pos.row) + 0.5) * cellH)
            let winPoint = tv.convert(local, to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: winPoint, modifierFlags: [.command],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let d = mouse(.leftMouseDown) { tv.mouseDown(with: d) }
            pump(0.05)
            if let u = mouse(.leftMouseUp) { tv.mouseUp(with: u) }
            pump(0.3)
            let hover = tv.linkHighlightSnapshot != nil
            if opened == "https://example.com/yeterm" {
                print("✓ ⌘点击链接触发打开(hover快照=\(hover ? "有" : "无"))")
            } else {
                print("✗ ⌘点击未触发 opened=\(opened ?? "nil") hover=\(hover)")
                linkOK = false
            }
            tv.onOpenLink = nil
            snap("link_after_click")
        } else {
            print("✗ 网格中未找到回显 URL")
            linkOK = false
        }

        // 场景 9(v1.2 #3):OSC 133 命令导航全链 —— 让 shell 亲手打出集成序列
        // (printf 输出到 tty → 终端解析,与真实 zsh 钩子同路径),断言书签/
        // 跳转/复制输出/失败标记四件套。
        var marksOK = true
        step += 1
        tv.send(txt: "clear; printf '\\e]133;A\\a'; echo PROMPT1; "
            + "printf '\\e]133;C\\a'; echo out-line-1; echo out-line-2; "
            + "printf '\\e]133;D;0\\a\\e]133;A\\a'; echo PROMPT2; "
            + "printf '\\e]133;C\\a'; echo boom; printf '\\e]133;D;1\\a\\e]133;A\\a'\n")
        pump(1.2)
        let marks = tv.commandMarks.marks
        if marks.count >= 3 {
            print("✓ OSC 133 书签解析(marks=\(marks.count))")
        } else {
            print("✗ OSC 133 书签不足 marks=\(marks.count)")
            marksOK = false
        }
        let copied = tv.copyLastCommandOutput()
        if copied == "boom" {
            print("✓ 复制上条命令输出 = boom")
        } else {
            print("✗ 复制上条输出异常: \(copied ?? "nil")")
            marksOK = false
        }
        let fails = tv.failedCommandViewportRows()
        // 行号强断言:标记必须正好落在 PROMPT2 那一行(网格逐行找它)
        var prompt2Row = -1
        for row in 0..<tv.getTerminal().rows {
            guard let line = tv.getTerminal().getLine(row: row) else { continue }
            var text = ""
            for c in 0..<tv.getTerminal().cols { text.append(tv.getTerminal().getCharacter(for: line[c])) }
            if text.contains("PROMPT2") { prompt2Row = row; break }
        }
        if fails.count == 1 && fails.first == prompt2Row && prompt2Row >= 0 {
            print("✓ 失败命令标记 1 处且落在 PROMPT2 行(row=\(prompt2Row))")
        } else {
            print("✗ 失败标记异常 fails=\(fails) PROMPT2行=\(prompt2Row)")
            marksOK = false
        }
        // 跳转:先回底,⌘↑ 两次应停在第一条 PROMPT 书签行,⌘↓ 回到更晚位置
        let beforeJump = tv.getTerminal().getTopVisibleRow()
        tv.jumpToPreviousCommand()
        pump(0.2)
        tv.jumpToPreviousCommand()
        pump(0.2)
        let afterUp = tv.getTerminal().getTopVisibleRow()
        tv.jumpToNextCommand()
        pump(0.2)
        let afterDown = tv.getTerminal().getTopVisibleRow()
        // clear 后书签都在视口内时滚动可能无空间;只要调用不崩且方向不倒挂即可
        if afterUp <= beforeJump && afterDown >= afterUp {
            print("✓ ⌘↑/⌘↓ 跳转方向正确(top \(beforeJump)→\(afterUp)→\(afterDown))")
        } else {
            print("✗ 跳转方向异常 top \(beforeJump)→\(afterUp)→\(afterDown)")
            marksOK = false
        }
        // 2026-08-06 回归(用户实测「⌃C 后每个空提示符长红条,clear 不消」):
        // ① ⌃C/空回车风暴 —— 无 C 的 D;130+A 连发(zsh 在提示符上 ⌃C 后
        //    $? 残留 130,每个空回车的 precmd 都这么发),失败标记必须一根不长。
        //    开头先发 D;0 把当前书签干净收尾:敲这条命令本身会触发真实集成的
        //    preexec C,不关掉的话首个合成 D;130 会把"有 C"的它关成失败误伤断言
        tv.send(txt: "printf '\\e]133;D;0\\a\\e]133;A\\a\\e]133;D;130\\a\\e]133;A\\a\\e]133;D;130\\a\\e]133;A\\a'\n")
        pump(0.8)
        let stormFails = tv.failedCommandViewportRows()
        if stormFails.count == 1 {
            print("✓ ⌃C/空回车风暴免疫(无 C 的 D;130 不长红条,仍只有 PROMPT2 一处)")
        } else {
            print("✗ 空回车风暴长出红条 fails=\(stormFails)")
            marksOK = false
        }
        // ② clear 后新提示符行号回落 → 旧书签(含 PROMPT2 失败标记)整体剪枝,
        //    红条不许残留在清空的屏幕上
        tv.send(txt: "clear; printf '\\e]133;D;0\\a\\e]133;A\\a'; echo P3\n")
        pump(0.8)
        let afterClear = tv.failedCommandViewportRows()
        if afterClear.isEmpty {
            print("✓ clear 剪枝:旧失败标记随被回收的行一并作废(fails=0)")
        } else {
            print("✗ clear 后红条残留 fails=\(afterClear)")
            marksOK = false
        }
        snap("command_marks")

        // 场景 10(v1.2 #5):Visual Bell + 命令完成回调 —— shell 打真 \a 断言闪屏
        // 触发;C..sleep..D 断言完成回调携带的耗时(通知本体走系统层,swift run
        // 无 bundle 环境 Notifier 自动降级,这里验证到回调链为止)
        var bellOK = true
        step += 1
        let flashBefore = wc.overlayForTesting?.bellFlashStart ?? -1
        tv.send(txt: "printf '\\a'\n")
        pump(0.8)
        let flashAfter = wc.overlayForTesting?.bellFlashStart ?? -1
        if flashAfter > flashBefore && flashAfter > 0 {
            print("✓ Visual Bell 闪屏触发(t=\(String(format: "%.2f", flashAfter)))")
        } else {
            print("✗ Visual Bell 未触发 before=\(flashBefore) after=\(flashAfter)")
            bellOK = false
        }
        step += 1
        var finished: (duration: TimeInterval, exit: Int?)?
        let oldFinished = tv.commandMarks.onCommandFinished
        tv.commandMarks.onCommandFinished = { m, d in
            finished = (d, m.exitCode)
            oldFinished?(m, d)
        }
        tv.send(txt: "printf '\\e]133;C\\a'; sleep 1; printf '\\e]133;D;0\\a\\e]133;A\\a'\n")
        pump(2.2)
        tv.commandMarks.onCommandFinished = oldFinished
        if let f = finished, f.duration >= 0.9, f.exit == 0 {
            print("✓ 命令完成回调(耗时 \(String(format: "%.1f", f.duration))s, exit=0)")
        } else {
            print("✗ 完成回调异常: \(String(describing: finished))")
            bellOK = false
        }

        // 场景 11(v1.2 #4):终端内图片 —— 生成 8×8 纯红 PNG,经 iTerm2 imgcat
        // 协议(OSC 1337 File inline)由 shell 打给终端,断言:①条带挂上
        // BufferLine.images(Mirror 反射,兼作上游属性改名哨兵);②合成帧里
        // 图片区域确实点亮(渲染链端到端)。
        var imageOK = true
        step += 1
        let redPNG: String = {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!.base64EncodedString()
        }()
        tv.send(txt: "clear; printf '\\e]1337;File=inline=1;width=20;height=6:\(redPNG)\\a'; echo END\n")
        pump(1.5)
        var stripeRowList: [Int] = []
        for row in 0..<tv.getTerminal().rows {
            guard let line = tv.getTerminal().getLine(row: row) else { continue }
            for child in Mirror(reflecting: line).children where child.label == "images" {
                if let arr = child.value as? [TerminalImage], !arr.isEmpty { stripeRowList.append(row) }
            }
        }
        if stripeRowList.count >= 3 {   // 6 行高的图 → 至少 3 条条带在视口
            print("✓ 图片条带挂上 BufferLine(rows=\(stripeRowList))")
        } else {
            print("✗ 图片条带不足(rows=\(stripeRowList))")
            imageOK = false
        }
        snap("imgcat")

        // 多段协议(imgcat 新版默认路径,用户实测修复):MultipartFile/FilePart/FileEnd
        // 按 200 字节切段手写序列 —— 与真实脚本同构、零外部依赖
        step += 1
        var multipartCmd = "clear; printf '\\e]1337;MultipartFile=inline=1;width=10;height=3\\a'; "
        var rest = Substring(redPNG)
        while !rest.isEmpty {
            let chunk = rest.prefix(200)
            rest = rest.dropFirst(200)
            multipartCmd += "printf '\\e]1337;FilePart=\(chunk)\\a'; "
        }
        multipartCmd += "printf '\\e]1337;FileEnd\\a'; echo MP-END\n"
        tv.send(txt: multipartCmd)
        pump(1.5)
        var mpRows = 0
        for row in 0..<tv.getTerminal().rows {
            guard let line = tv.getTerminal().getLine(row: row) else { continue }
            for child in Mirror(reflecting: line).children where child.label == "images" {
                if let arr = child.value as? [TerminalImage], !arr.isEmpty { mpRows += 1 }
            }
        }
        if mpRows >= 3 {
            print("✓ imgcat 多段协议出图(rows=\(mpRows))")
        } else {
            print("✗ 多段协议无条带 rows=\(mpRows)")
            imageOK = false
        }

        // 场景 12(v1.2 #6):粘贴保护 —— 多行剪贴板 ⌘V 应弹确认卡而非直接上屏;
        // 卡上回车 = 真粘贴;单行粘贴直通不弹。
        var pasteOK = true
        step += 1
        tv.send(txt: "clear\n")
        pump(0.5)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo PASTE-A\necho PASTE-B", forType: .string)
        tv.paste(self)
        pump(0.5)
        func gridText() -> String {
            var out = ""
            for row in 0..<tv.getTerminal().rows {
                guard let line = tv.getTerminal().getLine(row: row) else { continue }
                for c in 0..<tv.getTerminal().cols { out.append(tv.getTerminal().getCharacter(for: line[c])) }
            }
            return out
        }
        let guardView = window.contentView?.firstDescendant(ofType: PasteGuardView.self)
        let intercepted = !gridText().contains("PASTE-A") && guardView?.isHidden == false
        if intercepted {
            print("✓ 多行粘贴被确认卡拦截")
        } else {
            print("✗ 拦截失败 gridHasText=\(gridText().contains("PASTE-A")) guard=\(String(describing: guardView?.isHidden))")
            pasteOK = false
        }
        // v1.3 改版:确认面板 = OSD 同款画布,断言预览与操作提示如实上画
        let canvas = overlay.pasteGuardController?.canvasText() ?? ""
        if overlay.pasteGuardController?.visible == true,
           canvas.contains("echo PASTE-A"), canvas.contains("粘贴确认"), canvas.contains("ESC") {
            print("✓ OSD 风格画布装填(预览+标题+提示)")
        } else {
            print("✗ 画布装填异常 visible=\(String(describing: overlay.pasteGuardController?.visible))")
            pasteOK = false
        }
        snap("paste_guard_panel")   // 面板在场帧(OSD 风格目检用)
        // 卡上回车 → 真粘贴上屏
        if let g = guardView, !g.isHidden {
            let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36)!
            g.keyDown(with: ret)
            pump(0.6)
            if gridText().contains("PASTE-A") && gridText().contains("PASTE-B") {
                print("✓ 确认后两行如实粘贴上屏")
            } else {
                print("✗ 确认粘贴未上屏")
                pasteOK = false
            }
        }
        step += 1
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo SINGLE-LINE", forType: .string)
        tv.paste(self)
        pump(0.4)
        if gridText().contains("SINGLE-LINE") && (guardView?.isHidden ?? true) {
            print("✓ 单行粘贴直通(不弹卡)")
        } else {
            print("✗ 单行直通异常")
            pasteOK = false
        }
        tv.send(txt: "\u{15}")   // Ctrl-U 清行,不真执行 echo
        snap("paste_guard")

        // 场景 13(v1.2 #10):开机自检 —— 专开一个带自检的窗口,断言自检期
        // 接管合成、时间线走完自动切回真终端(状态机回归;画面目检走 render-demo)
        var bootOK = true
        step += 1
        let bootWC = TerminalWindowController(options: options, playBootScreen: true)
        bootWC.window?.orderFront(nil)
        pump(0.5)
        let activeDuring = bootWC.overlayForTesting?.bootScreenActive ?? false
        pump(2.2)
        let activeAfter = bootWC.overlayForTesting?.bootScreenActive ?? true
        if activeDuring && !activeAfter {
            print("✓ 开机自检:期中接管 + 期满自动切回")
        } else {
            print("✗ 自检状态机异常 during=\(activeDuring) after=\(activeAfter)")
            bootOK = false
        }
        bootWC.window?.close()
        pump(0.5)

        // 场景 14(v1.2 #12):换台效果 —— 稳态触发后 active,~0.32s 后自动结束;
        // 播放中段 powerOnProgress 会经过横线态(视觉走 --power-on 定格目检通道)
        var channelOK = true
        step += 1
        overlay.playChannelSwitch()
        pump(0.1)
        let chActive = overlay.channelSwitchActive
        pump(0.5)
        let chAfter = overlay.channelSwitchActive
        if chActive && !chAfter {
            print("✓ 换台:触发激活 + 期满自动结束")
        } else {
            print("✗ 换台状态机异常 active=\(chActive) after=\(chAfter)")
            channelOK = false
        }

        // 场景 15(v1.2 #13):消磁 —— 触发后激活,0.8s 包络走完自动结束;
        // 机壳点击路径合成真实 mouseDown 打在 margin 带上(彩蛋触发链端到端)
        var degaussOK = true
        step += 1
        wc.degaussAction(nil)
        pump(0.1)
        let dgActive = overlay.degaussActive
        pump(1.0)
        let dgAfter = overlay.degaussActive
        if dgActive && !dgAfter {
            print("✓ 消磁:触发激活 + 包络期满结束")
        } else {
            print("✗ 消磁状态机异常 active=\(dgActive) after=\(dgAfter)")
            degaussOK = false
        }
        // 机壳点击(窗口左上角 margin 带内;margin>0 的主题才有壳,探针 config 有)
        if let content = window.contentView {
            let casePoint = NSPoint(x: 4, y: content.bounds.height - 4)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: casePoint,
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            content.subviews.first?.mouseDown(with: down)   // root 是 contentView 首子视图
            pump(0.1)
            if overlay.degaussActive {
                print("✓ 点机壳触发消磁(彩蛋链)")
            } else {
                print("✗ 机壳点击未触发")
                degaussOK = false
            }
            pump(1.0)
        }

        // 场景 16(v1.2 #7):截图/录 GIF —— 截图落盘可解码;录 1 秒 GIF 断言
        // 多帧动图(帧数>5,CGImageSource 解码验证)
        var exportOK = true
        step += 1
        let shotURL = URL(fileURLWithPath: outPrefix + "_export_test.png")
        if let saved = wc.exportScreenshot(to: shotURL),
           let ds = CGImageSourceCreateWithURL(saved as CFURL, nil),
           CGImageSourceGetCount(ds) == 1 {
            print("✓ CRT 截图落盘可解码")
        } else {
            print("✗ 截图导出失败")
            exportOK = false
        }
        step += 1
        wc.startGIFRecording()
        pump(1.2)
        let gifURL = URL(fileURLWithPath: outPrefix + "_export_test.gif")
        if wc.gifRecordingForTesting, let saved = wc.finishGIFRecording(to: gifURL),
           let ds = CGImageSourceCreateWithURL(saved as CFURL, nil),
           CGImageSourceGetCount(ds) > 5 {
            print("✓ GIF 录制 \(CGImageSourceCreateWithURL(saved as CFURL, nil).map(CGImageSourceGetCount) ?? 0) 帧可解码")
        } else {
            print("✗ GIF 录制失败")
            exportOK = false
        }

        // 场景 17(v1.2 #8):小件三连 —— ①当前目录查询+新窗注入继承;
        // ②滚回行数缺省 1 万 + 运行时即改;③Option=Meta 默认开
        var trioOK = true
        step += 1
        tv.send(txt: "cd /tmp\n")
        pump(0.6)
        let cwdNow = wc.currentWorkingDirectory
        let inheritWC = TerminalWindowController(options: options, initialCwd: cwdNow)
        inheritWC.window?.orderFront(nil)
        pump(1.0)
        let inheritedCwd = inheritWC.currentWorkingDirectory
        if cwdNow?.hasSuffix("/tmp") == true, inheritedCwd == cwdNow {
            print("✓ 继承目录:查询 \(cwdNow!) → 新窗同目录")
        } else {
            print("✗ 继承目录异常 cur=\(cwdNow ?? "nil") new=\(inheritedCwd ?? "nil")")
            trioOK = false
        }
        inheritWC.window?.close()
        pump(0.4)
        tv.send(txt: "cd - >/dev/null\n")   // 回原目录,不干扰后续场景
        step += 1
        let sb0 = tv.getTerminal().options.scrollback
        tv.getTerminal().changeScrollback(5000)
        let sb1 = tv.getTerminal().options.scrollback
        tv.getTerminal().changeScrollback(sb0)
        if sb0 == 10000 && sb1 == 5000 {
            print("✓ 滚回行数:缺省 1 万 + 运行时即改")
        } else {
            print("✗ 滚回行数异常 sb0=\(sb0) sb1=\(sb1)")
            trioOK = false
        }
        if tv.optionAsMetaKey {
            print("✓ Option=Meta 默认开")
        } else {
            print("✗ Option=Meta 默认关(预期开)")
            trioOK = false
        }

        // 场景 18(v1.2 #9):⌘点击文件路径 —— 回显 `/private/tmp/文件:12` 编译报错
        // 格式,⌘点击断言:行号剥离、路径存在校验、钩子收到展开后的绝对路径
        var pathOK = true
        step += 1
        let probeFile = "/private/tmp/yeterm-path-probe.txt"
        FileManager.default.createFile(atPath: probeFile, contents: Data("x".utf8))
        tv.send(txt: "clear; echo \(probeFile):12\n")
        pump(0.8)
        var pathPos: (row: Int, col: Int)?
        for row in (0..<tv.getTerminal().rows).reversed() {
            guard let line = tv.getTerminal().getLine(row: row) else { continue }
            var text = ""
            for c in 0..<tv.getTerminal().cols { text.append(tv.getTerminal().getCharacter(for: line[c])) }
            if let r = text.range(of: probeFile + ":12"), !text.contains("echo") {
                pathPos = (row, text.distance(from: text.startIndex, to: r.lowerBound))
                break
            }
        }
        var openedPath: (path: String, line: Int?)?
        tv.onOpenFilePath = { openedPath = ($0, $1) }
        if let pos = pathPos {
            let optimal = tv.getOptimalFrameSize()
            let cellH = optimal.height / CGFloat(tv.getTerminal().rows)
            let cellW = optimal.width / CGFloat(tv.getTerminal().cols)
            let local = NSPoint(x: (CGFloat(pos.col) + 5.5) * cellW,
                                y: tv.frame.height - (CGFloat(pos.row) + 0.5) * cellH)
            let winPoint = tv.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(with: type, location: winPoint, modifierFlags: [.command],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1) {
                    type == .leftMouseDown ? tv.mouseDown(with: ev) : tv.mouseUp(with: ev)
                }
                pump(0.05)
            }
            pump(0.3)
        }
        tv.onOpenFilePath = nil
        if let o = openedPath, o.path == probeFile, o.line == 12 {
            print("✓ ⌘点击路径:\(o.path):\(o.line!) 解析打开")
        } else {
            print("✗ 路径点击异常 pos=\(String(describing: pathPos)) opened=\(String(describing: openedPath))")
            pathOK = false
        }
        try? FileManager.default.removeItem(atPath: probeFile)

        // 场景 19(v1.2 #14):OSD 面板 —— 开→键盘调值(↓ 选 CONTRAST、→ +0.05
        // 直连 model)→出图目检→Esc 关(焦点还终端)
        var osdOK = true
        step += 1
        let osdModel = SettingsModel(from: options.config)
        osdModel.persistenceEnabled = false
        let contrastBefore = osdModel.contrast
        wc.toggleOSD(model: osdModel)
        pump(0.4)
        func osdKey(_ code: UInt16) {
            if let kv = window.contentView?.firstDescendant(ofType: OSDKeyView.self),
               let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code) {
                kv.keyDown(with: ev)
            }
        }
        osdKey(125)   // ↓ 到 CONTRAST
        osdKey(124)   // → +0.05
        pump(0.3)
        snap("osd_panel")
        let adjusted = abs(osdModel.contrast - min(1, contrastBefore + 0.05)) < 0.001
        let visibleMid = wc.overlayForTesting?.osdController?.visible ?? false
        osdKey(53)    // Esc 关闭
        pump(0.3)
        let visibleAfter = wc.overlayForTesting?.osdController?.visible ?? true
        let focusBack2 = window.firstResponder === tv
        if visibleMid && adjusted && !visibleAfter && focusBack2 {
            print("✓ OSD:呼出 + 键盘调值直连 + Esc 关闭还焦")
        } else {
            print("✗ OSD 异常 vis=\(visibleMid) adj=\(adjusted) after=\(visibleAfter) focus=\(focusBack2)")
            osdOK = false
        }

        // 场景 20(CRT 总开关,用户裁决重定义):关 → **GPU 管线常驻**(overlay
        // 不藏/原生层保持抑制)+ uniforms 中性化直通(modern/零特效/无机壳);
        // 开 → 特效参数回归
        var plainOK = true
        step += 1
        var plainCfg = options.config ?? CRTConfig()
        plainCfg.crtEffectsEnabled = false
        wc.applySettings(plainCfg, fontSize: 14, cursorStyle: 0)
        pump(0.3)
        let offGPU = !overlay.userHidden && tv.suppressNativeDrawing   // 永远 GPU
        let u = overlay.uniforms
        let offNeutral = u.rasterMode == 4 && u.bloomAmount == 0 && u.frameOn == 0
            && u.screenCurvature == 0 && u.staticNoise == 0
            && u.colorPassthrough > 0.5   // 原色直出(染色公式绕过,p10k 串色勘差)
        snap("plain_mode")
        var crtCfg = plainCfg
        crtCfg.crtEffectsEnabled = true
        wc.applySettings(crtCfg, fontSize: 14, cursorStyle: 0)
        pump(0.3)
        let backOn = overlay.uniforms.frameOn > 0 || overlay.uniforms.bloomAmount > 0
            || overlay.uniforms.screenCurvature > 0
        // 调色板双轨断言:开 CRT 后 basic16 = 配置的 ansiColors(v1.2 预设大更新:
        // 经典配色携带专属表)或 crterm 专属调色板(无 ansiColors 时)
        let expectCrtAnsi = crtCfg.crtAnsiPalette()
        let crtPaletteBack = AnsiColor.plainOverride == nil
            && AnsiColor.basic16[14] == (expectCrtAnsi?[14] ?? AnsiColor.crtBasic16[14])
        if offGPU && offNeutral && backOn && crtPaletteBack {
            print("✓ CRT 总开关:关=GPU 常驻+参数直通 / 开=特效与调色板回归")
        } else {
            print("✗ 总开关异常 gpu=\(offGPU) neutral=\(offNeutral) back=\(backOn) palette=\(crtPaletteBack)")
            plainOK = false
        }
        // 关模式单独断言:普通模式 ANSI 红 = **配置自身 plainPalette** 的红。
        // (v1.2 预设大更新后不再硬编码 Terminal.app 色 —— 经典配色预设携带
        // 专属 plain ANSI 表,用户 config 快照里跟着最后所选主题走是正确行为)
        wc.applySettings(plainCfg, fontSize: 14, cursorStyle: 0)
        pump(0.2)
        let plainRed = AnsiColor.basic16[1]
        let expectRed = plainCfg.plainPalette().palette[1]
        let redDelta = abs(plainRed.x - expectRed.x) + abs(plainRed.y - expectRed.y)
            + abs(plainRed.z - expectRed.z)
        if AnsiColor.plainOverride != nil, redDelta < 0.02 {
            print("✓ 普通模式调色板 = 配置 plain 表(ANSI 红命中)")
        } else {
            print("✗ 普通调色板异常 red=\(plainRed) expect=\(expectRed)")
            plainOK = false
        }
        wc.applySettings(crtCfg, fontSize: 14, cursorStyle: 0)   // 收尾回 CRT
        pump(0.2)

        // 场景 21(v1.2 #16 普通模式背景图片):纯橙测试图(255,128,0)全链上屏,
        // 空白区像素直读断言 —— 无变化=橙、暗化=橙×0.35、黑白=r≈g≈b、清除=纯bg。
        // 取样点 (12, H/2):无论落在 margin 带还是内容空白区,默认底色都透出背景图
        var bgOK = true
        step += 1
        let bgImgPath = NSTemporaryDirectory() + "yeterm_bg_probe.png"
        if !makeSolidPNG(r: 255, g: 128, b: 0, size: 64, path: bgImgPath) {
            print("✗ 背景图测试图生成失败")
            bgOK = false
        }
        var bgCfg = plainCfg
        bgCfg.plainBackgroundImage = bgImgPath
        bgCfg.plainBackgroundImageMode = 0
        func bgSample(_ tag: String) -> (r: Int, g: Int, b: Int)? {
            let path = "\(outPrefix)_bg_\(tag).png"
            guard overlay.dumpFrame(to: path) else { return nil }
            print("frame: \(path)")
            guard let img = loadPNG(path) else { return nil }
            return pixelAt(img, x: 12, y: img.height / 2)
        }
        wc.applySettings(bgCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let pxNone = bgSample("none")
        let noneHit = pxNone.map { $0.r > 200 && $0.g > 80 && $0.g < 170 && $0.b < 60 } ?? false
        bgCfg.plainBackgroundImageMode = 3   // 暗化 ×0.35 → ≈(89,45,0)
        wc.applySettings(bgCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let pxDim = bgSample("dimmed")
        let dimHit = pxDim.map { $0.r > 60 && $0.r < 120 && $0.g > 24 && $0.g < 70 && $0.b < 30 } ?? false
        bgCfg.plainBackgroundImageMode = 4   // 黑白胶片:灰度×0.55 → r≈g≈b≈83
        wc.applySettings(bgCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let pxMono = bgSample("mono")
        let monoHit = pxMono.map {
            let mx = max($0.r, $0.g, $0.b), mn = min($0.r, $0.g, $0.b)
            return mx - mn < 14 && mx > 55 && mx < 115
        } ?? false
        bgCfg.plainBackgroundImage = nil     // 清除 → 回纯背景色(以配置实际值为准,
        wc.applySettings(bgCfg, fontSize: 14, cursorStyle: 0)    // 不能假设默认黑 —— 用户 config.json 可能调过)
        pump(0.4)
        let pxClear = bgSample("cleared")
        let expBg = bgCfg.plainPalette().bg
        let clearHit = pxClear.map {
            abs($0.r - Int(expBg.x * 255)) < 8 && abs($0.g - Int(expBg.y * 255)) < 8
                && abs($0.b - Int(expBg.z * 255)) < 8
        } ?? false
        if noneHit && dimHit && monoHit && clearHit {
            print("✓ 背景图片:原图/暗化/黑白像素命中 + 清除还原纯色")
        } else {
            print("✗ 背景图异常 none=\(String(describing: pxNone)) dim=\(String(describing: pxDim)) mono=\(String(describing: pxMono)) clear=\(String(describing: pxClear))")
            bgOK = false
        }
        try? FileManager.default.removeItem(atPath: bgImgPath)
        wc.applySettings(crtCfg, fontSize: 14, cursorStyle: 0)   // 收尾回 CRT
        pump(0.2)

        // 场景 22(2026-07-29 用户实测"选一行选中上面一行"勘差):真实鼠标事件
        // 拖选,断言选中行列与点击的**渲染网格位置**精确一致 —— 此前 SwiftTerm
        // hit-test 行高(逻辑 ceil)与我们渲染行高(物理 ceil)不一致,Menlo 24 行
        // 末累积 0.7 行;列宽同理(Zpix 80 列末 ~3 列)。度量对齐后必须逐点命中
        var hitOK = true
        step += 1
        window.makeKeyAndOrderFront(nil)   // 拖选走 sendEvent,非 key 窗口会吞 mouseDown
        window.makeFirstResponder(tv)
        pump(0.2)
        let hitTerm = tv.getTerminal()
        hitTerm.feed(text: "\u{1b}[2J\u{1b}[H" + (0...20).map { "LINE-\($0)" }.joined(separator: "\r\n"))
        pump(0.3)
        let hitScale = window.backingScaleFactor
        let hitCell = GlyphAtlas.cellSize(font: tv.font, scale: hitScale)
        let cellW = CGFloat(hitCell.w) / hitScale, cellH = CGFloat(hitCell.h) / hitScale
        let hitRow = 15, hitC1 = 2, hitC2 = 12
        func mousePoint(col: Int, row: Int) -> NSPoint {
            let p = NSPoint(x: (CGFloat(col) + 0.5) * cellW,
                            y: tv.bounds.height - (CGFloat(row) + 0.5) * cellH)
            return tv.convert(p, to: nil)
        }
        // 直接调 tv 的鼠标方法(绕开 window.sendEvent 的 key 窗/首击路由差异):
        // 场景要验证的是 calculateMouseHit 的度量换算,不是 AppKit 派发链
        func mouse(_ type: NSEvent.EventType, at p: NSPoint) {
            guard let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: tv.mouseDown(with: ev)
            case .leftMouseDragged: tv.mouseDragged(with: ev)
            default: tv.mouseUp(with: ev)
            }
        }
        mouse(.leftMouseDown, at: mousePoint(col: hitC1, row: hitRow))
        pump(0.05)
        // SwiftTerm 语义:选区起点 = 第一次 drag 的位置(softStart),先原地微动一次
        mouse(.leftMouseDragged, at: mousePoint(col: hitC1, row: hitRow))
        pump(0.05)
        mouse(.leftMouseDragged, at: mousePoint(col: hitC2, row: hitRow))
        pump(0.05)
        mouse(.leftMouseUp, at: mousePoint(col: hitC2, row: hitRow))
        pump(0.2)
        if let sel = tv.selectionSnapshot {
            let selRow = min(sel.start.row, sel.end.row) - hitTerm.buffer.yDisp
            let selCol = min(sel.start.col, sel.end.col)
            if selRow == hitRow && abs(selCol - hitC1) <= 1 {
                print("✓ 选区 hit 对齐:点第 \(hitRow) 行选中第 \(selRow) 行(列 \(selCol))")
            } else {
                print("✗ 选区错位 点(\(hitC1),\(hitRow)) 选中(\(selCol),\(selRow))")
                hitOK = false
            }
        } else {
            print("✗ 拖选未产生选区")
            hitOK = false
        }
        mouse(.leftMouseDown, at: mousePoint(col: 0, row: 0))   // 单击清选区收尾
        pump(0.05)
        mouse(.leftMouseUp, at: mousePoint(col: 0, row: 0))
        pump(0.1)

        // 场景 23(v1.3 提示符主题,端到端):真实 shell + 真信号 + 读屏验证。
        // 前提:run() 开头已 ShellIntegration.install() 刷新脚本;本场景开一个
        // **新窗口**(source 最新脚本、完成 OSC 7777 握手),对它做热切并读屏
        var promptOK = true
        step += 1
        func lastNonEmptyLine(_ t: SwiftTerm.Terminal) -> String {
            for row in stride(from: t.rows - 1, through: 0, by: -1) {
                guard let line = t.getLine(row: row) else { continue }
                var s = ""
                for col in 0..<t.cols {
                    let ch = t.getCharacter(for: line[col])
                    if ch != "\0" { s.append(ch) }
                }
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return ""
        }
        _ = ShellIntegration.install()   // 保证脚本最新版(与用户点「刷新脚本」等效)
        // 现场保护(2026-07-29:用户与探针同机并行测试,探针写状态文件会覆盖
        // 用户此刻的选择):记住真实文件当前值,场景结束按**原值**恢复 ——
        // 恢复 crtCfg(探针启动时的 config 快照)会把用户测试期间的切换回滚
        let promptFileBefore = try? String(contentsOfFile: ShellIntegration.promptFilePath,
                                           encoding: .utf8)
        // auto-drive 无 AppDelegate,直接自建第二窗(与 run 开头同方式,真 shell)
        let pwc: TerminalWindowController? = TerminalWindowController(options: options)
        pwc?.window?.orderFront(nil)
        pump(2.5)   // 等 zshrc(p10k/集成脚本)加载完、OSC 7777 握手到达
        if let pwc, let ptv = pwc.terminalViewForTesting {
            let ready = ptv.promptHotswapReady
            var promptCfg = crtCfg
            promptCfg.promptTheme = "retro:dos"   // DOS 特征最强(C:\...>),不与用户现状撞
            pwc.applySettings(promptCfg, fontSize: 14, cursorStyle: 0)
            pump(0.8)
            ptv.send(txt: "\r")   // 促发 precmd(空闲 shell 无 zle 活动,重载靠命令周期)
            pump(4.0)   // 深水切换 = exec 会话重载 + zshrc 完整加载(1~3s)
            let fileNow = (try? String(contentsOfFile: ShellIntegration.promptFilePath, encoding: .utf8)) ?? "?"
            let dosLine = lastNonEmptyLine(ptv.getTerminal())
            let dosHit = dosLine.hasPrefix("C:") && dosLine.hasSuffix(">")
            promptCfg.promptTheme = nil
            pwc.applySettings(promptCfg, fontSize: 14, cursorStyle: 0)
            pump(0.8)
            ptv.send(txt: "\r")
            pump(4.0)
            let backLine = lastNonEmptyLine(ptv.getTerminal())
            let backHit = !(backLine.hasPrefix("C:") && backLine.hasSuffix(">"))
            if ready && dosHit && backHit {
                print("✓ 提示符热切端到端:握手+切 DOS 上屏+切回还原")
            } else {
                print("✗ 提示符热切异常 ready=\(ready) file=\(fileNow) dos=「\(dosLine)」 back=「\(backLine)」")
                promptOK = false
            }
            pwc.window?.close()
            pump(0.3)
        } else {
            print("✗ 提示符热切:测试窗口创建失败")
            promptOK = false
        }
        wc.applySettings(crtCfg, fontSize: 14, cursorStyle: 0)   // 收尾还原
        // 状态文件按场景开始前的**真实原值**恢复(见 promptFileBefore 注释)
        if let orig = promptFileBefore {
            try? orig.write(toFile: ShellIntegration.promptFilePath, atomically: true, encoding: .utf8)
        }
        pump(0.2)

        // 场景 24(v1.3 SSH):服务器选单画布/翻页/数字选中/⇧回车分流 +
        // 自动登录哨兵(本地假脚本演 ssh 的指纹询问与密码提示,不出网)
        var sshOK = true
        step += 1
        let sshStore = SSHHostStore.shared
        let sshTmp = NSTemporaryDirectory() + "yeterm-ad-ssh.json"
        // 现场保护 + 装填隔离(2026-07-30 实测教训):用户真清单已有主机时,
        // 只设 pathOverride 不 load(),内存里还留着真主机 → 与固定装填混在一起,
        // "数字键选中第 N 台"的断言全偏位。先 load 空文件把清单清干净。
        try? FileManager.default.removeItem(atPath: sshTmp)
        let realHostsBefore = sshStore.hosts.map(\.id)
        sshStore.pathOverride = sshTmp
        sshStore.load()
        for i in 1...10 {   // 10 台凑两页,验证翻页
            var h = SSHHost()
            h.name = "机器\(i)"; h.host = "10.0.0.\(i)"; h.user = "op"
            if i == 3 { h.note = "备注三号" }
            sshStore.upsert(h)
        }
        let picker = overlay.ensureServerPicker()
        var picked: (host: SSHHost, split: Bool)?
        picker.onConnect = { picked = ($0, $1) }
        picker.show()
        func pickerKey(_ code: UInt16, shift: Bool = false, chars: String = " ") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                             modifierFlags: shift ? [.shift] : [],
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        let page1 = picker.canvasText()
        // 注意子串陷阱:「机器10」包含「机器1」—— 页判定用只在某页出现的名字
        let listOK = page1.contains("服务器选单") && page1.contains("op@10.0.0.1")
            && page1.contains("备注三号") && page1.contains("1/2") && !page1.contains("机器9")
        _ = picker.handleKey(pickerKey(124))            // → 翻到第 2 页
        let page2 = picker.canvasText()
        let pageOK = page2.contains("机器9") && page2.contains("机器10") && page2.contains("2/2")
        _ = picker.handleKey(pickerKey(19, chars: "2")) // 数字 2 = 本页第 2 台(全局第 10)
        overlay.scheduleCapture()
        pump(0.3)
        snap("ssh_picker")   // 选单在场帧(⇧回车前拍,不然面板已关)
        _ = picker.handleKey(pickerKey(36, shift: true, chars: "\r"))   // ⇧回车 = 分屏连
        let pickOK = picked?.host.name == "机器10" && picked?.split == true && !picker.visible
        if listOK && pageOK && pickOK {
            print("✓ 服务器选单:装填+翻页+数字选中+⇧回车分流")
        } else {
            print("✗ 服务器选单异常 list=\(listOK) page=\(pageOK) pick=\(String(describing: picked?.host.name))")
            sshOK = false
        }
        // 自动登录哨兵:假脚本按真 ssh 的问答顺序演一遍(指纹 yes → 密码)
        step += 1
        let fakeSSH = NSTemporaryDirectory() + "yeterm-fake-ssh.sh"
        try? """
        printf 'The authenticity of host cannot be established. Continue (yes/no/[fingerprint])? '
        read a
        printf 'op@fake password: '
        read pw
        printf '\\nRESULT-%s-%s\\n' "$a" "$pw"
        """.write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        tv.send(txt: "sh \(fakeSSH)\r")
        SSHAutoLogin.arm(on: tv, password: "sekrit99")
        var loginOK = false
        for _ in 0..<24 {   // 最多 6s:哨兵 0.25s 一拍,两问两答后出 RESULT
            pump(0.25)
            var all = ""
            let t = tv.getTerminal()
            for row in 0..<t.rows {
                guard let line = t.getLine(row: row) else { continue }
                for c in 0..<t.cols {
                    let ch = t.getCharacter(for: line[c])
                    if ch != "\u{0}" { all.append(ch) }
                }
            }
            if all.contains("RESULT-yes-sekrit99") { loginOK = true; break }
        }
        if loginOK {
            print("✓ 自动登录:指纹自动 yes + 密码自动代填")
        } else {
            print("✗ 自动登录未完成(lastAction=\(SSHAutoLogin.lastAction))")
            sshOK = false
        }
        // ⇧回车真分屏连:连向本机废端口(瞬时 refused,不出网),断言分屏+命令上屏
        step += 1
        var refused = SSHHost()
        refused.name = "废端口"; refused.host = "127.0.0.1"; refused.port = 65535; refused.user = "op"
        let panesBefore = wc.panes.count
        wc.connectSSH(refused, inSplit: true)
        var splitOK = false
        for _ in 0..<40 {   // 新 pane 的 shell 启动最长等 10s(gitstatusd 教训)
            pump(0.25)
            if wc.panes.count == panesBefore + 1,
               let newTV = wc.panes.last?.terminalView {
                var all = ""
                let t = newTV.getTerminal()
                for row in 0..<t.rows {
                    guard let line = t.getLine(row: row) else { continue }
                    for c in 0..<t.cols {
                        let ch = t.getCharacter(for: line[c])
                        if ch != "\u{0}" { all.append(ch) }
                    }
                }
                if all.contains("op@127.0.0.1") { splitOK = true; break }
            }
        }
        if splitOK {
            print("✓ 分屏连:新 pane 上屏 ssh 命令(端口拒绝不出网)")
        } else {
            print("✗ 分屏连异常 panes=\(wc.panes.count)(before=\(panesBefore))")
            sshOK = false
        }
        snap("ssh_split_connect")
        // 焦点归属(用户实测:焦点在右分屏呼出选单回车,命令发进了左分屏)——
        // 选单捕手抢走 firstResponder 后 focusedPane 会回落 panes.first,
        // 必须用"呼出瞬间锁定的目标 pane"。此刻已有 ≥2 个 pane,把焦点放右屏验证。
        step += 1
        if wc.panes.count >= 2, let rightPane = wc.panes.last, let leftPane = wc.panes.first {
            window.makeFirstResponder(rightPane.terminalView)
            pump(0.3)
            var focusHost = SSHHost()
            focusHost.name = "焦点验证"; focusHost.host = "127.0.0.1"
            focusHost.port = 65534; focusHost.user = "focuscheck"
            sshStore.upsert(focusHost)
            wc.toggleServerPicker()
            pump(0.3)
            let picker2 = overlay.ensureServerPicker()
            // 选单在场时 focusedPane 必然回落 panes.first(捕手抢了 firstResponder)
            // —— 这正是 bug 的前置条件,顺手断言它成立,否则本场景等于没测
            let fellBack = wc.focusedPane !== rightPane
            // ① Esc 关闭 → 焦点必须回到呼出时那个 pane(而不是 panes.first)
            _ = picker2.handleKey(pickerKey(53, chars: "\u{1b}"))
            pump(0.3)
            let escBack = window.firstResponder === rightPane.terminalView
            if !escBack {
                print("✗ Esc 关闭后焦点没还给原 pane(串到别的分屏了)")
                sshOK = false
            }
            // ② 重开选单走连接路径
            wc.toggleServerPicker()
            pump(0.3)
            // 定位到"焦点验证"那台(清单末位)再回车 = 当前屏连接
            while picker2.selected < picker2.hosts.count - 1 {
                _ = picker2.handleKey(pickerKey(125))   // ↓
            }
            _ = picker2.handleKey(pickerKey(36, chars: "\r"))
            pump(1.2)
            func paneText(_ p: TerminalPane) -> String {
                var out = ""
                let t = p.terminalView.getTerminal()
                for row in 0..<t.rows {
                    guard let line = t.getLine(row: row) else { continue }
                    for c in 0..<t.cols {
                        let ch = t.getCharacter(for: line[c])
                        if ch != "\u{0}" { out.append(ch) }
                    }
                }
                return out
            }
            let inRight = paneText(rightPane).contains("focuscheck@127.0.0.1")
            let inLeft = paneText(leftPane).contains("focuscheck@127.0.0.1")
            if inRight && !inLeft && fellBack && escBack {
                print("✓ 选单回车落在焦点分屏(右屏)+ Esc 还焦正确(选单在场时 focusedPane 确实回落=前置条件成立)")
            } else {
                print("✗ 落点/还焦错了 right=\(inRight) left=\(inLeft) escBack=\(escBack) fellBack=\(fellBack) panes=\(wc.panes.count)")
                sshOK = false
            }
            snap("ssh_focus_pane")
        } else {
            print("✗ 焦点归属:分屏数不足(panes=\(wc.panes.count))")
            sshOK = false
        }
        // 算法自动降级重连(2026-07-30 用户追加,通用不依赖 ~/.ssh/config):
        // 直接把真实协商报错喂进屏幕 → 哨兵应抓对方 offer、补 -o 参数原地重连,
        // 并把兼容参数记到这台主机上。重连目标用 127.0.0.1 废端口(瞬时拒绝,不出网)
        step += 1
        var dgHost = SSHHost()
        dgHost.name = "降级验证"; dgHost.host = "127.0.0.1"
        dgHost.port = 65533; dgHost.user = "dg"
        sshStore.upsert(dgHost)
        tv.send(txt: "clear\n")
        pump(0.5)
        SSHAutoLogin.arm(on: tv, host: dgHost, password: nil)
        // 伪造报错原文(与用户实测的一字不差),直接喂进终端画面
        tv.getTerminal().feed(text: "Unable to negotiate with 127.0.0.1 port 65533: "
            + "no matching host key type found. Their offer: ssh-rsa,ssh-dss\r\n")
        // 断言盯「发出去的命令」而不是「屏幕上的回显」——
        // 伪造报错是直接 feed 进模拟器的,shell 不知情,它重画输入行时会和注入的
        // 文字互相覆盖,回显落点不确定(实测:命令前半截被盖掉,只剩后半截可见)。
        // 屏幕回显是 shell 的行为;YeTerm 的契约是「把带对参数的命令发出去」。
        var dgOK = false
        for _ in 0..<24 {
            pump(0.25)
            if SSHAutoLogin.lastSentCommand.contains("HostKeyAlgorithms=+ssh-rsa") { dgOK = true; break }
        }
        let sent = SSHAutoLogin.lastSentCommand
        let dgAction = SSHAutoLogin.lastAction.hasPrefix("downgrade:")
        let remembered = sshStore.hosts.first { $0.id == dgHost.id }?.extraOptions ?? ""
        // 命令必须:①带主机密钥算法兼容参数;②带公钥算法兼容参数;
        //          ③**滤掉 dss**(本机 ssh 已不支持,带上去会以另一个错失败);
        //          ④打到正确的主机端口上
        let cmdOK = sent.contains("-o HostKeyAlgorithms=+ssh-rsa")
                 && sent.contains("-o PubkeyAcceptedAlgorithms=+ssh-rsa")
                 && !sent.contains("dss")
                 && sent.contains("dg@127.0.0.1")
                 && sent.contains("-p 65533")
        if dgOK, dgAction, cmdOK,
           remembered.contains("HostKeyAlgorithms=+ssh-rsa"), !remembered.contains("dss") {
            print("✓ 算法自动降级:抓 offer 补参数重连 + 记住这台主机(滤掉 dss)")
        } else {
            print("✗ 自动降级异常 触发=\(dgOK) action=\(SSHAutoLogin.lastAction) 命令合规=\(cmdOK)")
            print("    实发命令:「\(sent)」")
            print("    记住参数:「\(remembered)」")
            sshOK = false
        }
        snap("ssh_downgrade")
        tv.send(txt: "\u{15}")   // 清行,别把重连命令留在提示符上

        sshStore.pathOverride = nil
        sshStore.load()
        try? FileManager.default.removeItem(atPath: sshTmp)
        try? FileManager.default.removeItem(atPath: fakeSSH)
        // 用户真清单必须分毫未动(测试写的全在临时文件里)
        if sshStore.hosts.map(\.id) == realHostsBefore {
            print("✓ 真实主机清单未被测试污染(\(realHostsBefore.count) 台原样)")
        } else {
            print("✗ 真清单被动过! before=\(realHostsBefore.count) after=\(sshStore.hosts.count)")
            sshOK = false
        }

        // 场景 25(v1.3,用户实测「CRT 下字体有锯齿、同样两行一清一糊」):
        // 像素 1:1 不变量 —— 窗口尺寸带小数(拖拽缩放/恢复旧 frame 常见)时,
        // 合成画面必须仍等于 drawable 尺寸,pane 落点必须在整数物理像素上。
        // 破了就是 CRT 采样在做非整数重采样 = 行与行清晰度不一致。
        var sharpOK = true
        step += 1
        let frames: [NSRect] = [
            NSRect(x: 120, y: 120, width: 900.5, height: 620.3),   // 双向小数
            NSRect(x: 120.25, y: 120, width: 901, height: 621),    // 原点小数
            NSRect(x: 120, y: 120, width: 903.75, height: 617.5),
        ]
        for f in frames {
            window.setFrame(f, display: true)
            pump(0.6)
            overlay.syncCompositeForTesting()   // GUI 里这一步由 renderTick 每帧兜底
            let exact = overlay.pixelMappingExactForTesting
            let origin = overlay.focusedPaneOriginForTesting
            let intOrigin = origin.x == origin.x.rounded() && origin.y == origin.y.rounded()
            if !exact || !intOrigin {
                print("✗ 像素 1:1 破了 frame=\(f.size) exact=\(exact) paneOrigin=\(origin) sizes=\(overlay.mappingSizesForTesting) bounds=\(overlay.bounds.size) scale=\(window.backingScaleFactor)")
                sharpOK = false
            }
        }
        if sharpOK {
            print("✓ 像素 1:1 不变量(分数窗口尺寸下合成=drawable、pane 落点整数)")
        }
        snap("sharp_mapping")

        // 场景 26(v1.4,波特率限速):
        // 不经真 PTY,直接把合成字节喂给 dataReceived(限速器的入口),断言
        //   ①限速开:字节**分批**到屏,配额随时间线性放行,误差在容差内;
        //   ②⌃C 立刻吐完积压(send 钩子);
        //   ③限速关(0):完全直通,一次 pump 后全部到屏;
        //   ④跨 feed 边界拆开的中文不乱码(逐字节喂 UTF-8 三字节序列)。
        // ④ 是最要紧的一条:限速把字节流切得极碎,SwiftTerm 的 putbackBuffer
        //    机制必须接住半个字符 —— 我们 fork 改过多字节解码路径,这里是哨兵。
        var rateOK = true
        step += 1
        func visibleCount(of ch: Character) -> Int {
            let t = tv.getTerminal()
            var n = 0
            for row in 0..<t.rows {
                guard let line = t.getLine(row: row) else { continue }
                for col in 0..<t.cols where t.getCharacter(for: line[col]) == ch {
                    n += 1
                }
            }
            return n
        }
        let rateSaved = tv.outputBitRate
        // 前三条一律以**限速器自己的积压**为量,而不是数屏上字符 ——
        // 屏上计数会被滚屏和 shell 自己的输出(p10k 提示符里就有 % 和 #)干扰,
        // 第一版这么写的确翻车了。积压是我们的内部账,只受喂进去的字节影响。
        let PAY = 1200                             // 9600bps ÷ 8 = 1200 字节/秒 → 满速恰好 1 秒
        tv.outputBitRate = 9600
        let payload = [UInt8](repeating: UInt8(ascii: "%"), count: PAY)
        tv.dataReceived(slice: payload[...])
        let base = tv.pendingOutputBytes           // 应 ≈ PAY(shell 静默时恰好 PAY)
        pump(0.05)
        let rel005 = base - tv.pendingOutputBytes
        pump(0.45)
        let rel050 = base - tv.pendingOutputBytes
        // 理论值:0.05s 放 60 字节、0.5s 放 600。容差给到 ±50% 吸收 60Hz 定时器抖动
        if base < PAY || base > PAY * 2 {
            print("✗ 入队异常:积压 \(base)(预期 ≈\(PAY);过大说明 shell 也在输出,测量被污染)")
            rateOK = false
        } else if rel005 > 200 || rel050 <= rel005 || rel050 < 300 || rel050 > 900 {
            print("✗ 放行速率不对:0.05s 放行 \(rel005)(预期 ~60)、0.5s 放行 \(rel050)(预期 ~600)")
            rateOK = false
        } else {
            print("✓ 波特率限速按配额分批放行(9600bps:0.05s=\(rel005) 0.5s=\(rel050) 字节)")
        }
        // ── ② ⌃C 立刻吐完:**不 pump**,不给 shell 回话的机会 ──
        //    (flush 在 send 内同步执行;一 pump,zsh 对 ⌃C 打的新提示符就会重新排队,
        //     积压看着反而变大 —— 第一版就是这么误判的)
        let backlogBefore = tv.pendingOutputBytes
        tv.send(source: tv, data: [0x03][...])     // ⌃C
        let backlogAfter = tv.pendingOutputBytes
        if backlogBefore > 0 && backlogAfter == 0 {
            print("✓ ⌃C 同步吐完积压(\(backlogBefore) → 0)")
        } else {
            print("✗ ⌃C 未吐完:积压 \(backlogBefore) → \(backlogAfter)")
            rateOK = false
        }
        // ── ③ 限速关 = 直通(入队即到,零积压)──
        tv.outputBitRate = 0
        pump(0.2)                                  // 放掉 shell 对 ⌃C 的回应
        let plain = [UInt8](repeating: UInt8(ascii: "@"), count: 900)
        tv.dataReceived(slice: plain[...])
        let passthroughBacklog = tv.pendingOutputBytes   // 直通路径根本不入队
        if passthroughBacklog == 0 {
            print("✓ 限速关 = 完全直通(900 字节零积压,与限速前同一条代码路径)")
        } else {
            print("✗ 直通失败:仍有积压 \(passthroughBacklog)")
            rateOK = false
        }
        // ── ④ 逐字节喂中文:跨 feed 边界的 UTF-8 必须不乱码 ──
        //    这条用屏上计数(要验的就是"字有没有正确成形"),选生僻字避开 shell 噪声
        tv.dataReceived(slice: Array("\u{1b}[2J\u{1b}[H".utf8)[...])   // 清屏归位
        pump(0.1)
        let cjk = Array("镕黼罍鼗".utf8)            // 4 个生僻汉字 = 12 字节,提示符里绝不会有
        for b in cjk { tv.dataReceived(slice: [b][...]) }   // **每次只喂 1 字节**
        pump(0.1)
        let missing = ["镕", "黼", "罍", "鼗"].filter { visibleCount(of: Character($0)) == 0 }
        if missing.isEmpty {
            print("✓ 逐字节喂 UTF-8 中文不乱码(SwiftTerm putbackBuffer 接住了半个字符)")
        } else {
            print("✗ 逐字节中文丢字:缺 \(missing)")
            rateOK = false
        }
        tv.outputBitRate = rateSaved
        snap("byte_rate")

        // 场景 27(v1.4,用户实测 bug:外接屏全屏 + 锁屏过夜,早上解锁后
        // 「文字全没了、只剩扫描线 + 最下方 2~3 像素行的字符残骸」):
        // 复现锁屏前后那一串状态变化,逐步打印「合成画面尺寸 / drawable / contentScale /
        // pane 落点 / 终端行列」,定位是哪个量坏掉、以及能不能自愈。
        var wakeOK = true
        step += 1
        @discardableResult
        func snapshotGeom(_ tag: String) -> Double {
            let m = overlay.mappingSizesForTesting
            let cw: Int = m.comp.0, ch: Int = m.comp.1
            let dwv: Int = m.drawable.0, dhv: Int = m.drawable.1
            let sx: Double = cw > 0 ? Double(dwv) / Double(cw) : -1
            let t = tv.getTerminal()
            var s = "  [\(tag)] 合成=\(cw)x\(ch) drawable=\(dwv)x\(dhv)"
            s += " contentScale.x=" + String(format: "%.3f", sx)
            s += " pane落点=\(overlay.focusedPaneOriginForTesting)"
            s += " 终端=\(t.cols)x\(t.rows)"
            s += " 1:1=\(overlay.pixelMappingExactForTesting)"
            s += String(format: " 距上次绘制回调=%.2fs", overlay.secondsSinceLastTickForTesting)
            s += " isPaused=\(overlay.isPaused)"
            print(s)
            return sx
        }
        snapshotGeom("锁屏前")
        // ① 锁屏:窗口被完全遮挡(occlusionState 失去 .visible)+ app 失活。
        //    renderTick 的 occlusion guard 会挡住渲染 —— 这是设计如此。
        window.orderOut(nil)
        pump(0.3)
        // ② 过夜:期间外接屏可能休眠/断开 → 窗口被系统挪动缩放。
        //    这里用「窗口缩到很小再放回全尺寸」模拟这次几何突变。
        let savedFrame = window.frame
        window.setFrame(NSRect(x: 0, y: 0, width: 120, height: 80), display: false)
        pump(0.3)
        snapshotGeom("过夜缩小")
        // ③ 解锁:窗口回到原尺寸并重新可见
        window.setFrame(savedFrame, display: true)
        window.orderFront(nil)
        pump(0.8)
        overlay.syncCompositeForTesting()   // GUI 里这一步由 renderTick 每帧驱动
        pump(0.5)
        snapshotGeom("解锁后")
        // 判据一:合成画面必须重新等于 drawable(1:1),否则 CRT 会拿旧图非整数缩放,
        //        contentScale 一旦远大于 1,屏幕上就只剩一条窄带 = 用户看到的现象
        if !overlay.pixelMappingExactForTesting {
            let mm = overlay.mappingSizesForTesting
            print("✗ 解锁后合成画面与 drawable 不一致(\(mm.comp) vs \(mm.drawable))")
            wakeOK = false
        }
        // 判据二:画面必须真的有内容(不能只剩扫描线)。直接读屏统计非背景像素
        let wakePNG = "\(outPrefix)_wake.png"
        if overlay.dumpFrame(to: wakePNG), let img = loadPNG(wakePNG) {
            print("frame: \(wakePNG)")
            var lit = 0
            var litRows = Set<Int>()
            for y in stride(from: 0, to: img.height, by: 2) {
                for x in stride(from: 0, to: img.width, by: 4) {
                    if let p = pixelAt(img, x: x, y: y), p.r + p.g + p.b > 150 {
                        lit += 1
                        litRows.insert(y)
                    }
                }
            }
            // 文字若还在,亮像素会散布在很多行上;只剩底部残骸的话 litRows 会极少
            let rowSpan = litRows.isEmpty ? 0 : (litRows.max()! - litRows.min()!)
            print("  解锁后画面:亮像素 \(lit) 个,分布跨 \(rowSpan)px / \(img.height)px 高")
            if lit < 50 || rowSpan < img.height / 4 {
                print("✗ 解锁后文字丢失(亮像素太少或只集中在一条窄带)")
                wakeOK = false
            }
        } else {
            print("✗ 解锁后截帧失败")
            wakeOK = false
        }
        if wakeOK {
            print("✓ 锁屏/尺寸突变/解锁后画面自愈(1:1 恢复 + 文字仍在)")
        }
        // ④ 看门狗策略(纯函数,直接断言判定边界):
        //    真实的「display link 死了」在活着的循环里没法伪造 —— 一帧就把心跳刷新了,
        //    所以把判定抽成纯函数来测,并如实承认「macOS 会不会重建 display link」不可单测。
        let wd = MetalOverlayView.watchdogShouldRecover
        let policyOK = wd(true, false, 3.0)        // 可见 + 未暂停 + 久无回调 → 救
            && !wd(true, false, 0.5)               // 刚画过 → 不救
            && !wd(true, true, 10.0)               // 主动暂停(⌘E/后台省电)→ 不抢救
            && !wd(false, false, 10.0)             // 不可见(遮挡/最小化)→ 不救
        if policyOK {
            print("✓ 看门狗判定边界正确(久无回调才救;主动暂停/不可见一律不碰)")
        } else {
            print("✗ 看门狗判定边界错误")
            wakeOK = false
        }
        // ⑤ 恢复动作的实际效果:必须作废并重建合成画面,且重建后画面仍有文字
        let rebuildsBefore = overlay.compositeRebuilds
        overlay.forceRecoveryForTesting()
        pump(0.6)
        overlay.syncCompositeForTesting()
        pump(0.4)
        let rebuiltPNG = "\(outPrefix)_recovered.png"
        var stillHasText = false
        if overlay.dumpFrame(to: rebuiltPNG), let img = loadPNG(rebuiltPNG) {
            print("frame: \(rebuiltPNG)")
            var lit = 0
            for y in stride(from: 0, to: img.height, by: 2) {
                for x in stride(from: 0, to: img.width, by: 4) where
                    (pixelAt(img, x: x, y: y).map { $0.r + $0.g + $0.b > 150 } ?? false) { lit += 1 }
            }
            stillHasText = lit > 50
        }
        if overlay.compositeRebuilds > rebuildsBefore && stillHasText && overlay.pixelMappingExactForTesting {
            print("✓ 恢复动作:合成画面被作废重建(\(rebuildsBefore)→\(overlay.compositeRebuilds))、1:1 保持、文字仍在")
        } else {
            print("✗ 恢复动作失效:重建 \(rebuildsBefore)→\(overlay.compositeRebuilds) 有文字=\(stillHasText) 1:1=\(overlay.pixelMappingExactForTesting)")
            wakeOK = false
        }
        snap("wake_recover")

        // 场景 28(v1.5.1,用户需求「让背景图片在 CRT 模式也能生效,但经典 CRT 下不生效」):
        // 同一张纯橙测试图(255,128,0),三种情形各取屏幕中心偏下的一个像素 ——
        //   ① CRT + 普通主题(不属于内置「经典 CRT」组)→ 屏幕底图铺上,该处呈橙色系;
        //   ② 打开荧光染色 → 同一处被染成磷光绿。基线特意配 fontColor 纯绿 + 色彩浓度 0,
        //      好让"染没染"是个非黑即白的判定,而不是靠色差阈值猜;
        //   ③ 切到内置「经典 CRT」组的 DEC VT220(图和开关一个字没动,**唯一变量是预设
        //      身份**)→ 不铺图,该处回到该主题自己的暗背景。
        // 判定用**整屏统计**而不是取单个像素点(第一版就是栽在这:跑到这一步时屏幕上
        // 早堆满了前面场景的输出,随便挑的那个点正落在文字上,三档全测的是文字颜色)。
        // 测试色选天蓝 (0,128,255):跟任何一款磷光色都不撞 —— 琥珀/绿/白的 b 都低,
        // 于是"画面里有没有大片蓝"就等价于"图铺没铺上",不必跟文字的颜色打架。
        var crtBGOK = true
        step += 1
        let crtBGPath = NSTemporaryDirectory() + "yeterm_crtbg_probe.png"
        if !makeSolidPNG(r: 0, g: 128, b: 255, size: 64, path: crtBGPath) {
            print("✗ CRT 背景图测试图生成失败")
            crtBGOK = false
        }
        /// 返回 (蓝像素占比, 绿像素占比)。蓝 = 天蓝测试图原样上屏;
        /// 绿 = 被磷光染成单色绿(基线 fontColor 特意配 #00ff00)。
        /// 判定留足余量:扫描线暗带会把亮度压到 50%,所以阈值按暗带那一档算。
        func crtBGRatios(_ tag: String) -> (blue: Double, green: Double)? {
            let path = "\(outPrefix)_crtbg_\(tag).png"
            guard overlay.dumpFrame(to: path), let img = loadPNG(path) else { return nil }
            print("frame: \(path)")
            var blue = 0, green = 0, total = 0
            for y in stride(from: 0, to: img.height, by: 3) {
                for x in stride(from: 0, to: img.width, by: 3) {
                    guard let p = pixelAt(img, x: x, y: y) else { continue }
                    total += 1
                    if p.b > 100 && p.b > p.g + 40 && p.b > p.r + 40 { blue += 1 }
                    if p.g > 40 && p.g > p.r + 30 && p.g > p.b + 30 { green += 1 }
                }
            }
            guard total > 0 else { return nil }
            return (Double(blue) / Double(total), Double(green) / Double(total))
        }
        var themeCfg = crtCfg
        themeCfg.name = "我的配置"            // 用户配置区的名字,不属于内置「经典 CRT」组
        themeCfg.fontColor = "#00ff00"        // 纯绿磷光 + 零色彩浓度 → 染色档必然把橙变绿
        themeCfg.chromaColor = 0
        themeCfg.plainBackgroundImage = crtBGPath
        themeCfg.plainBackgroundImageMode = 0
        themeCfg.crtBackgroundImageChroma = false
        wc.applySettings(themeCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let rRaw = crtBGRatios("raw")
        // 铺上了 = 大片蓝(文字只占屏幕一小块,所以 30% 这条线足以把"铺满"和"没铺"分开)
        let rawHit = rRaw.map { $0.blue > 0.3 } ?? false
        themeCfg.crtBackgroundImageChroma = true
        wc.applySettings(themeCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let rChroma = crtBGRatios("chroma")
        // 染色档 = 蓝彻底消失、换成大片磷光绿
        let chromaHit = rChroma.map { $0.blue < 0.05 && $0.green > 0.3 } ?? false
        var classicCfg = Presets.byName("DEC VT220") ?? themeCfg
        classicCfg.plainBackgroundImage = crtBGPath
        classicCfg.plainBackgroundImageMode = 0
        wc.applySettings(classicCfg, fontSize: 14, cursorStyle: 0)
        pump(0.4)
        let rClassic = crtBGRatios("classic_device")
        // 没铺 = 蓝绿都没有大片(VT220 的琥珀文字 r 最高,两个判定都不会误命中)
        let classicHit = rClassic.map { $0.blue < 0.05 && $0.green < 0.05 } ?? false
        func fmt(_ r: (blue: Double, green: Double)?) -> String {
            r.map { String(format: "蓝%.2f/绿%.2f", $0.blue, $0.green) } ?? "nil"
        }
        if rawHit && chromaHit && classicHit {
            print("✓ CRT 背景图:原色档铺上(\(fmt(rRaw))) / 染色档染成磷光绿(\(fmt(rChroma))) / 经典 CRT 设备主题不铺(\(fmt(rClassic)))")
        } else {
            print("✗ CRT 背景图异常 raw=\(fmt(rRaw)) chroma=\(fmt(rChroma)) classic=\(fmt(rClassic))")
            crtBGOK = false
        }
        try? FileManager.default.removeItem(atPath: crtBGPath)
        wc.applySettings(crtCfg, fontSize: 14, cursorStyle: 0)   // 收尾回基线
        pump(0.2)
        snap("crt_bg_image")

        print("AUTO-DRIVE-DONE steps=\(step)")
        return (searchOK && linkOK && marksOK && bellOK && imageOK && pasteOK && bootOK && channelOK && degaussOK && exportOK && trioOK && pathOK && osdOK && plainOK && bgOK && hitOK && promptOK && sshOK && sharpOK && rateOK && wakeOK && crtBGOK) ? 0 : 1
    }

    // ---- 场景 21 的小工具:纯色 PNG 生成 / PNG 像素直读 ----

    /// 纯色测试图(背景图探针用;CGContext 填色 → PNGWriter)
    private static func makeSolidPNG(r: Int, g: Int, b: Int, size: Int, path: String) -> Bool {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info) else { return false }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                 blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let img = ctx.makeImage() else { return false }
        return (try? PNGWriter.write(img, to: path)) != nil
    }

    private static func loadPNG(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 单点像素直读(BGRA 归一化上下文,与 PixelCompare 同构)
    private static func pixelAt(_ img: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < img.width, y < img.height else { return nil }
        var buf = [UInt8](repeating: 0, count: 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: info)) else { return nil }
        // 【学】只画 1×1 的窗口:把大图平移,让目标像素恰好落在画布原点
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(buf[2]), Int(buf[1]), Int(buf[0]))
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 合成**真实键盘事件**并走完整分发链(keyDown → 输入上下文 → TerminalView):
    /// PTY 直注(send)复现不了的问题只能靠它 —— 用户实测『测试软件不复现、真键盘复现』的教训。
    static func pressKey(window: NSWindow, keyCode: UInt16, character: String,
                         modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: modifiers, timestamp: t,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: isRepeat, keyCode: keyCode) else { return }
        window.sendEvent(down)
        if !isRepeat {
            if let up = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                         modifierFlags: modifiers, timestamp: t,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: keyCode) {
                window.sendEvent(up)
            }
        }
    }
}

extension NSView {
    /// 深度优先找第一个指定类型的子孙视图(探针定位浮层用)
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstDescendant(ofType: type) { return hit }
        }
        return nil
    }
}
