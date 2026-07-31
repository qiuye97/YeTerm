// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 选区功能哨兵(自测体系 4/5)
//
// 这个文件:两层验证 —— ①反射链:我们靠 Mirror 反射读 SwiftTerm 的私有
//   选区坐标,库一升级布局变了这里立刻报警(所以叫"哨兵");
//   ②端到端:全选前后对比渲染帧的亮像素数,证明高亮真的画上屏了。
//   "依赖私有实现的地方必须配哨兵测试" —— 这是一条值得记住的工程纪律。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit

/// 选区高亮自测(--probe-selection):
/// ① 反射链验证 —— selectAll 后 selectionSnapshot 坐标必须正确
///    (SwiftTerm 的选区坐标是 internal,靠 Mirror 读取,升级依赖时此探针是哨兵);
/// ② 端到端像素验证 —— 高亮开/关时同源出帧的亮像素数必须显著变化。
public enum SelectionProbe {
    public static func run(options: LaunchOptions) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // 探针强制黑底预设:亮像素判据(反选后翻倍)隐含深色底假设,
        // 用户切浅/彩底主题会假红(2026-07-28 Tokyo Night 蓝底实测)——
        // 本探针测的是选区高亮机制,不该对用户主题敏感
        var options = options
        options.config = Presets.byName("Monochrome Green")
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        // 探针隔离(v1.2 #10 实测教训):首窗自检屏会接管合成 —— 基线帧全是
        // BIOS 亮字,选区反色断言必假红;会话恢复/写盘同 WindowProbe 一并关
        delegate.settingsModel.persistenceEnabled = false
        delegate.settingsModel.restoreSession = false
        delegate.settingsModel.bootSelfTest = false
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        pump(1.5)   // 等 shell 提示符

        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        guard let wc = (NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }).first,
              let tv = wc.terminalViewForTesting,
              let ov = wc.overlayForTesting else {
            print("✗ 未找到终端窗口/overlay")
            print("SELECTION-PROBE-FAIL")
            return 1
        }
        let terminal = tv.getTerminal()

        // 强制中性观感 + 关掉全部时变特效:出帧必须与用户当前配置解耦
        // (曾因用户配置亮度拉满,预混背景色越过亮像素阈值 → 整屏皆「亮」误报)
        ov.uniforms.staticNoise = 0
        ov.uniforms.flickering = 0
        ov.uniforms.jitter = 0
        ov.uniforms.glowingLine = 0
        ov.uniforms.horizontalSyncStrength = 0
        ov.uniforms.burnIn = 0
        ov.uniforms.bloomAmount = 0
        ov.uniforms.fontColor = .init(1, 1, 1, 1)
        ov.uniforms.backgroundColor = .init(0, 0, 0, 1)
        ov.uniforms.brightness = 1
        ov.uniforms.chromaColor = 1
        ov.uniforms.screenCurvature = 0
        ov.uniforms.frameOn = 0
        ov.uniforms.ambientLight = 0

        let dir = NSTemporaryDirectory() + "yeterm-selection-probe/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let frameA = dir + "no-selection.png"
        let frameB = dir + "select-all.png"

        check("初始无选区", !tv.selectionActive)
        check("初始快照为 nil", tv.selectionSnapshot == nil)
        _ = ov.dumpFrame(to: frameA)

        tv.selectAll()
        pump(0.3)
        check("selectAll 后 selectionActive", tv.selectionActive)
        if let snap = tv.selectionSnapshot {
            check("快照起点 (0,0)", snap.start.col == 0 && snap.start.row == 0,
                  detail: "start=(\(snap.start.col),\(snap.start.row))")
            check("快照终点列 = cols-1", snap.end.col == terminal.cols - 1,
                  detail: "end=(\(snap.end.col),\(snap.end.row)) cols=\(terminal.cols)")
        } else {
            check("反射拿到选区快照", false, detail: "Mirror 未命中 selection/start/end(上游布局变了?)")
        }
        _ = ov.dumpFrame(to: frameB)

        // 高亮铺满全屏(含空行)→ 亮像素数应显著上升;阈值取 8% 荧光底之下、噪底之上
        let litA = litPixels(frameA)
        let litB = litPixels(frameB)
        check("选区高亮改变了画面亮像素数", litB > litA * 2 && litB > 10_000,
              detail: "lit \(litA) → \(litB)")

        tv.selectNone()
        pump(0.3)
        check("selectNone 后快照回 nil", tv.selectionSnapshot == nil)

        // 取消选区的像素级回归(2026-07-28 用户实测 bug):取消帧必须重算辉光,
        // 否则大亮块的 bloom 光晕留在屏上成"阴影"。亮像素须回落到基线水位。
        let frameC = NSTemporaryDirectory() + "yeterm-selection-probe-c.png"
        _ = ov.dumpFrame(to: frameC)
        let litC = litPixels(frameC)
        check("取消选区后亮度回落(无辉光残影)", litC < litB / 4 && litC < litA * 3,
              detail: "lit \(litB) → \(litC)(基线 \(litA))")

        print(pass ? "SELECTION-PROBE-PASS" : "SELECTION-PROBE-FAIL")
        // 结束全部 shell,避免残留进程
        NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }
            .forEach { $0.panes.forEach { $0.shutdown() } }
        return pass ? 0 : 1
    }

    /// 亮像素计数(任一通道 > 20/255)
    private static func litPixels(_ path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data),
              let px = rep.bitmapData else { return -1 }
        let count = rep.pixelsWide * rep.pixelsHigh
        let stride = rep.bitsPerPixel / 8
        var lit = 0
        for i in 0..<count {
            let o = i * stride
            if px[o] > 20 || px[o + 1] > 20 || px[o + 2] > 20 { lit += 1 }
        }
        return lit
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
