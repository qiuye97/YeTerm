// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 历史文物:全计划最险假设的定点验证
//
// 这个文件:项目最早期(M0)的"探针"——当时最大的技术不确定性是:
//   "把 SwiftTerm 的自绘关掉后,键盘/输入法/光标几何还正常吗?"
//   整个渲染架构都押在这个假设上,所以先写探针定点爆破,PASS 了才敢继续。
//   「先验证最险假设再动工」是这个项目自始至终的方法论,留档供回看。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import MetalKit
import SwiftTerm

/// M0-S7 探针:验证「抑制 TerminalView 自绘后,输入/caret 几何是否照常工作」。
/// 这是全项目最险假设(M1a 字形图集渲染器 + 隐形输入宿主的前提)。
///
/// ⚠️ 探针已排除的方案:子类空 draw —— SwiftTerm 的 draw(_:) 是 `public` 非 `open`,
/// **模块外禁止覆写**(编译期报错)。改用第一方路径:
///   `setUseMetal(true)` → 官方让 draw(_:) 早退(CoreText 不再画),
///   再把其内部 MTKView 子视图隐藏 —— 我们不要它的画面,只要它的输入机器。
///
/// 自动部分(--probe-draw-off,无头):
///   1. setUseMetal(true) + 隐藏内部 MTKView 跑真实 zsh
///   2. send(txt:) 注入命令 → 泵 → 读 buffer 验证「输入→PTY→回显→网格」全链完好
///   3. firstRect(forCharacterRange:) 在光标移动前后的取值 → IME 候选框定位依据是否仍更新
///   4. cell 度量: TerminalView 实测(frame/cols) vs 自算 CTFont 度量 → M1a atlas 必须对齐的数
/// 手动部分(用户 M0 验收): 可见窗口下真实打字 + 中文 IME 试候选框。

public enum DrawOffProbe {
    public static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var options = LaunchOptions()
        options.fontName = "Menlo"
        let rect = NSRect(x: 0, y: 0, width: 960, height: 600)

        let tv = LocalProcessTerminalView(frame: rect)
        tv.font = TermHost.resolveFont(name: options.fontName, size: options.fontSize)
        tv.nativeBackgroundColor = .black
        TermHost.hideNativeScroller(tv)

        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(tv)
        window.makeFirstResponder(tv)

        // 形态 4:官方抑制 CoreText 自绘 + 隐藏其 Metal 输出
        var metalOn = false
        do {
            try tv.setUseMetal(true)
            metalOn = tv.isUsingMetalRenderer
        } catch {
            print("setUseMetal 失败: \(error)")
        }
        var hiddenMetalViews = 0
        for sub in tv.subviews where sub is MTKView {
            sub.isHidden = true
            hiddenMetalViews += 1
        }
        print("setUseMetal=\(metalOn) 隐藏内部 MTKView 数=\(hiddenMetalViews)")

        // 环境变量走 TermHost 的唯一出口 —— 探针必须跑在与真实窗口**同一份**
        // 环境上,否则漏传类 bug(如 2026-07-30 的 SHELL)探针永远测不出来
        let env = TermHost.shellEnvironment()
        tv.startProcess(executable: TermHost.shellPath, environment: env,
                        execName: TermHost.shellExecName)

        pump(2.0)   // 等提示符

        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        // ---- 断言 0: PTY 环境变量装配(静态,不依赖 shell 行为) ----
        // 光断言"数组里有 SHELL"不够,必须**等于真正 spawn 的那个可执行文件** ——
        // 这条便签与事实不符,比空着更坏(程序会去开一个根本没在跑的 shell)
        check("环境含 SHELL 且与 spawn 的 executable 一致",
              env.contains("SHELL=\(TermHost.shellPath)"),
              detail: env.first { $0.hasPrefix("SHELL=") } ?? "(缺失)")
        check("环境含 TERM_PROGRAM 身份标识",
              env.contains("TERM_PROGRAM=YeTerm")
              && env.contains { $0.hasPrefix("TERM_PROGRAM_VERSION=") && $0.count > "TERM_PROGRAM_VERSION=".count },
              detail: env.filter { $0.hasPrefix("TERM_PROGRAM") }.joined(separator: " "))

        // ---- 基线记录 ----
        let t = tv.getTerminal()
        let rect0 = tv.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let cursor0 = t.getCursorLocation()

        // ---- 注入命令(绕过键盘事件层,直测「输入通道→PTY→回显→buffer」) ----
        tv.send(txt: "echo PROBE-你好-OK\n")
        pump(1.5)

        // ---- 断言 1: draw 抑制下回显进网格 ----
        var found = false
        for row in 0..<t.rows {
            guard let line = t.getLine(row: row) else { continue }
            let s = line.translateToString(trimRight: true, startCol: 0, endCol: -1, skipNullCellsFollowingWide: true)
            if s.contains("PROBE-你好-OK") { found = true; break }
        }
        check("draw 抑制下 输入→PTY→回显→网格 完好", found)

        // ---- 断言 1b: SHELL 端到端(真让 zsh 自己把 $SHELL 打出来) ----
        // 静态断言只能证明"我们传了",这条证明"**它真的活着到了 shell 里**" ——
        // 中间任何一环(白名单过滤/execve 丢失/启动脚本 unset)出问题都会红。
        // 用双引号包住免得 zsh 把值里的字符当 glob(NOMATCH 会直接报错)
        tv.send(txt: "echo \"YETERM-SHELL=$SHELL\"\n")
        pump(1.5)
        var shellEcho: String?
        for row in 0..<t.rows {
            guard let line = t.getLine(row: row) else { continue }
            let s = line.translateToString(trimRight: true, startCol: 0, endCol: -1, skipNullCellsFollowingWide: true)
            // 跳过命令行本身的回显(那行还带着 echo 三个字母)
            if let r = s.range(of: "YETERM-SHELL="), !s.contains("echo") {
                shellEcho = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        check("shell 进程内 $SHELL 非空且正确", shellEcho == TermHost.shellPath,
              detail: "实测 $SHELL=\(shellEcho.map { $0.isEmpty ? "(空)" : $0 } ?? "(没读到回显)")")

        // ---- 断言 2: caret 几何(IME 候选框定位依据)仍随光标更新 ----
        let rect1 = tv.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let cursor1 = t.getCursorLocation()
        let cursorMoved = cursor1 != cursor0
        let rectMoved = rect1 != rect0
        check("光标位置在网格中更新", cursorMoved,
              detail: "cursor \(cursor0) → \(cursor1)")
        check("firstRect(IME 候选框锚点)随之更新", rectMoved,
              detail: "\(rect0.origin) → \(rect1.origin)")

        // ---- 断言 3: cell 度量对比(M1a atlas 依据) ----
        let cellW = tv.frame.width / CGFloat(t.cols)
        let cellH = tv.frame.height / CGFloat(t.rows)
        let font = tv.font
        let ctFont = font as CTFont
        var glyph = CGGlyph(0)
        var ch: [UniChar] = [0x57] // 'W'
        CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let calcW = advance.width
        let calcH = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        print("  cell 实测: \(String(format: "%.3f", cellW)) x \(String(format: "%.3f", cellH)) pt")
        print("  CTFont 自算: advance(W)=\(String(format: "%.3f", calcW)) ascent+descent+leading=\(String(format: "%.3f", calcH)) pt")
        print("  差值: dW=\(String(format: "%+.3f", cellW - calcW)) dH=\(String(format: "%+.3f", cellH - calcH))(SwiftTerm 会按像素网格取整,#606)")

        print(pass ? "PROBE-PASS" : "PROBE-FAIL")
        return pass ? 0 : 1
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
