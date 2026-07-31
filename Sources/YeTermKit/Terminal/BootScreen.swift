// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 开机自检画面(v1.2 #10,复古组头牌)
//
// 这个文件:显像管亮起后、shell 出场前,滚一段仿 BIOS 自检 —— 老机器
//   开机时那几行"检测内存/硬盘"的仪式感,信息全是**真的**(芯片型号、
//   内存逐段计数、磁盘容量,都是现场从系统查的)。
//
// 实现思路(架构上的巧):不往真终端里打字(会和 shell 输出打架),
//   而是开一个**不连 shell 的假想终端**(headless Terminal),把自检文本
//   按时间线 feed 给它,再用同一个 ContentRenderer 渲染成纹理 ——
//   overlay 在自检期间"换台"显示这张纹理,结束切回真终端。
//   全程复用现有渲染管线,自检文字自动获得扫描线/辉光/余辉,零新着色器。
//
// 语法看点:`sysctlbyname` —— 直接调 C 的系统查询接口(两段式:先问长度
//   再取值,C API 的经典舞步);`\r` 回车不换行 = 反复覆盖同一行,
//   内存计数动画就靠它(和进度条原理相同)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Darwin
import Foundation
import SwiftTerm

/// BIOS 自检屏:headless 终端 + 时间线 feed + ContentRenderer 渲染。
/// 时钟由调用方注入(渲染时钟/harness 假时钟通吃);总时长 ~2.2s。
final class BootScreen {
    private let terminal: Terminal
    private let delegate = HarnessTermDelegate()
    private let content: ContentRenderer
    private var start: CFTimeInterval?
    private(set) var finished = false

    private var linesFed = 0
    private var memStepsFed = 0
    private let memTotalMB: Int
    private let lines: [(t: Double, text: String)]
    private let memStart = 0.35, memEnd = 0.95   // 内存计数动画时段
    private let totalDuration = 2.2

    var cellPx: (w: Int, h: Int) { content.cellPx }

    init(ctx: MetalContext, cols: Int, rows: Int) {
        terminal = Terminal(delegate: delegate,
                            options: TerminalOptions(cols: max(cols, 40), rows: max(rows, 12)))
        content = ContentRenderer(ctx: ctx)

        // ---- 现场采集真实硬件信息 ----
        let chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let ncpu = Self.sysctlInt("hw.ncpu") ?? 0
        memTotalMB = Int((Self.sysctlInt("hw.memsize") ?? 0) / 1_048_576)
        var diskLine = "detected"
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = attrs[.systemSize] as? Int64, let free = attrs[.systemFreeSize] as? Int64 {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            diskLine = "APFS \(fmt.string(fromByteCount: total)) (\(fmt.string(fromByteCount: free)) free)"
        }
        var displayLine = "Metal 3"
        if let screen = NSScreen.main {
            let px = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
            displayLine = "\(Int(px.width))x\(Int(px.height)) Retina / Metal 3"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString

        // ---- 时间线(t 秒时逐行滚出;内存行由计数动画单独驱动)----
        lines = [
            (0.00, "YETERM BIOS v1.2\r\n"),
            (0.05, "(c) 2026 YeTerm Retro Systems, all phosphors reserved\r\n\r\n"),
            (0.20, "Main Processor : \(chip) (\(ncpu) cores)\r\n"),
            (0.35, "Memory Test    : "),          // 计数动画接管本行
            (1.00, "\r\nStorage        : \(diskLine)\r\n"),
            (1.15, "Display        : \(displayLine)\r\n"),
            (1.30, "System         : macOS \(os)\r\n\r\n"),
            (1.50, "Keyboard ..... detected\r\n"),
            (1.62, "Pointing device ..... detected\r\n\r\n"),
            (1.80, "Booting YeTerm OS (/bin/zsh) ...\r\n"),
        ]
    }

    /// 推进时间线;返回"有新内容"(调用方据此重绘)
    @discardableResult
    func tick(now: CFTimeInterval) -> Bool {
        if start == nil { start = now }
        let t = now - start!
        var changed = false
        while linesFed < lines.count, lines[linesFed].t <= t {
            terminal.feed(text: lines[linesFed].text)
            linesFed += 1
            changed = true
        }
        // 内存计数:memStart..memEnd 均分 12 步,\r 覆盖行首反复重写
        if t >= memStart, memStepsFed < 12 {
            let target = min(12, Int((t - memStart) / (memEnd - memStart) * 12) + 1)
            while memStepsFed < target {
                memStepsFed += 1
                let mb = memTotalMB * memStepsFed / 12
                let suffix = memStepsFed == 12 ? " MB OK" : " MB"
                terminal.feed(text: "\rMemory Test    : \(mb)\(suffix)")
                changed = true
            }
        }
        if t >= totalDuration { finished = true }
        return changed
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }

    // MARK: - sysctl 小工具

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
