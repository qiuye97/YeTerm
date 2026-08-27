// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 机壳切换 × 全屏 TUI 回归探针(--probe-caseband)
//
// 起因(2026-08-27 用户实测):无机壳主题切到有机壳主题时,正在跑 claude code
//   的标签内容全消失,切标签再切回才恢复。机制:主题切换连环触发
//   布局→pane resize→SIGWINCH→TUI 整屏重画,resize 是行缓存追踪的"换血时刻"
//   (缓冲行对象整批换新,generation 计数从头来,与旧缓存可能撞车),撞上的行
//   永远不重建 —— 切标签能救是因为 mountActiveTab 会整幅置脏。
// 修法:①网格 resize 即整幅置脏(TerminalPane.onGridResized);②设置广播改了
//   文字区几何(机壳带/留白)就地做 mountActiveTab 三件套。本探针即其回归:
//   真实 shell 里跑一个「只有 SIGWINCH 才重画」的备用屏 TUI(claude code 同款
//   习性,重画裹同步输出 ?2026),多标签 + 生产链路 loadPreset 切主题,断言
//   **活路径**画面(dumpCompositeAsIs,不强制重捕获 —— dumpFrame 会重捕获,
//   把这类 bug 当场修好藏掉)切换后仍有内容。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import SwiftTerm

/// --probe-caseband:机壳出没 × 全屏 TUI 的活路径回归
public enum CaseBandProbe {
    public static func run(options: LaunchOptions) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        delegate.settingsModel.persistenceEnabled = false
        delegate.settingsModel.restoreSession = false
        delegate.settingsModel.bootSelfTest = false
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        pump(1.0)

        guard let wc = NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }).first,
              let tv = wc.terminalViewForTesting, let overlay = wc.overlayForTesting else {
            print("caseband: 组件不可用")
            return 1
        }
        // 起点:无机壳主题(VaporWave 出厂即 frameEnabled=false、零弧度);
        // loadPreset 走 storedConfig,与用户点预设完全同一条路
        delegate.settingsModel.loadPreset("VaporWave")
        pump(2.0)

        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        func bufferText() -> String {
            let t = tv.getTerminal()
            var s = ""
            for row in 0..<t.rows {
                guard let line = t.getLine(row: row) else { continue }
                for col in 0..<t.cols {
                    let ch = t.getCharacter(for: line[col])
                    if ch != "\0" { s.append(ch) }
                }
            }
            return s
        }
        /// **活路径**合成纹理亮像素统计(dumpCompositeAsIs 不强制重捕获;
        /// 合成纹理没有机壳,全图统计即内容)
        func liveLit(_ tag: String) -> Int {
            let path = NSTemporaryDirectory() + "yeterm-caseband-\(tag).png"
            guard overlay.dumpCompositeAsIs(to: path),
                  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return -1 }
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let info = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info) else { return -1 }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            var n = 0, i = 0
            while i < buf.count {
                if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 350 { n += 1 }
                i += 4
            }
            print("  [\(tag)] liveLit=\(n) 帧=\(path)")
            return n
        }
        /// 模拟 display link:踩心跳 + 泵事件交替(探针窗口常被遮挡,真实
        /// display link 的 occlusion guard 会早退,手动踩才有活路径可测)
        func tick(_ seconds: Double) {
            var t = 0.0
            while t < seconds {
                overlay.debugRenderTick(skipOcclusionCheck: true)
                pump(0.05)
                t += 0.05
            }
        }

        // 多标签(用户实况:TUI 在当前标签,后台还有别的标签 —— 有标签栏时
        // 机壳出现会连带 液态玻璃↔盒绘 标签条切换重排布局)
        wc.newTab()
        pump(1.0)
        wc.selectTab(0)
        pump(0.5)

        let t = tv.getTerminal()
        let rowsBefore = t.rows, colsBefore = t.cols

        // 假 TUI:进备用屏铺 ALT 行,**只有 WINCH 才重画**、重画裹同步输出
        // (claude code 同款习性)。走临时脚本文件,不在命令行里搏引号转义
        let tuiScript = """
        printf '\\e[?1049h\\e[2J\\e[H'
        for i in {1..15}; do echo "ALT-LINE-$i"; done
        TRAPWINCH() { printf '\\e[?2026h\\e[2J\\e[H'; for i in {1..15}; do echo "REDRAWN-$i"; done; printf '\\e[?2026l' }
        while true; do sleep 0.2; done
        """
        let tuiPath = NSTemporaryDirectory() + "yeterm-caseband-tui.zsh"
        try? tuiScript.write(toFile: tuiPath, atomically: true, encoding: .utf8)
        tv.send(txt: "zsh \(tuiPath)\n")
        tick(1.5)
        let before = bufferText()
        check("备用屏 TUI 已上屏", before.contains("ALT-LINE-9"))
        let litBefore = liveLit("before")
        check("切换前活画面有文字", litBefore > 800, detail: "lit=\(litBefore)")

        // 生产链路切主题:无机壳 → 有机壳(经典 CRT),含换台/字体/广播
        delegate.settingsModel.loadPreset("DEC VT220")
        tick(3.0)   // 换台 + 布局 + SIGWINCH → TUI 重画留足时间

        let rowsAfter = t.rows, colsAfter = t.cols
        let after = bufferText()
        let litAfter = liveLit("after")
        print("  终端网格 \(colsBefore)x\(rowsBefore) → \(colsAfter)x\(rowsAfter)")
        check("缓冲区有内容(REDRAWN 或 ALT)",
              after.contains("REDRAWN-9") || after.contains("ALT-LINE-9"))
        check("机壳出现后活画面仍有文字", litAfter > 800,
              detail: "liveLit \(litBefore) → \(litAfter)")

        // 反向再切一次(有机壳 → 无机壳,同一条几何兜底的另一半)
        delegate.settingsModel.loadPreset("VaporWave")
        tick(3.0)
        let litBack = liveLit("back")
        check("切回无机壳主题活画面仍有文字", litBack > 800, detail: "lit=\(litBack)")

        // 收尾:退出假 TUI
        tv.send(txt: "\u{03}")
        pump(0.3)
        tv.send(txt: "printf '\\e[?1049l'\n")
        pump(0.3)
        print(pass ? "CASEBAND-PROBE-PASS" : "CASEBAND-PROBE-FAIL")
        return pass ? 0 : 1
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
