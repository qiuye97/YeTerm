// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 演示 GIF 录制器(自测体系的"外销版")
//
// 这个文件:把 README / Release 里那张动图**用脚本录出来**,而不是手工开着 app
//   按 ⇧⌘R 碰运气。跑一次得到同一段演示 —— 换个主题、改条命令、重录一版,
//   一条命令的事(手工录制的老 GIF 只有 1.7 秒,就是因为手工太难重来)。
//
// 它复用的全是既有零件,自己没造任何轮子:
//   · TerminalWindowController —— 真实窗口 + 真实 PTY shell(和 auto-drive 同款);
//   · wc.startGIFRecording()/finishGIFRecording() —— v1.2 的录制功能本体;
//   · cfg.bitRate —— v1.4 的波特率限速,让输出**一个字一个字吐**(演示主角);
//   · overlay.playChannelSwitch()/playDegauss() —— 换台闪断与消磁彩蛋。
//
// ⚠️ 隐私:录出来的东西是要发到公开仓库的。所以录制**开始前**先把提示符换成
//   固定的 `yeterm@crt ~ $`(并清掉 p10k 之类的 precmd hook),再 clear 一次 ——
//   真实的 用户名@主机名、家目录路径一律不会进画面。
//
// 用法:
//   YeTerm --demo-gif out.gif [--preset NAME] [--demo-rate 2400] [--demo-cols 100]
//
// 语法看点:
//   `typeOut(_:)` 用逐字符 send + 小延时模拟**人在打字**;命令输出那一侧的
//     "逐字吐"则完全交给限速器,两者是不同的机制,凑在一起才像老终端。
//   `defer` 在这里做收尾:无论中途哪一步 return,录制状态都能停干净。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import SwiftTerm

/// 演示 GIF 录制:真实窗口 + 真实 shell,按脚本演一遍再落盘。
public enum DemoGIF {
    /// 演示脚本的一步。命令与其后的等待时间分开写,方便按录制总长调节奏。
    private struct Beat {
        let command: String
        /// 敲完回车后等多久(秒)—— 要略大于该命令在限速下吐完所需的时间
        let settle: TimeInterval
    }

    public static func run(outPath: String, options: LaunchOptions,
                           bitRate: Int, cols: Int, rows: Int) -> Int32 {
        let app = NSApplication.shared
        // ⚠️ 这里**必须**是 .regular + 真正激活,不能像别的 harness 那样用 .accessory:
        // renderTick 开头有一道 `occlusionState.contains(.visible)` 的早退 ——
        // 窗口不算"可见"时整个渲染循环不跑,于是①内容纹理永远不更新(画面全黑)、
        // ②开机动画的 powerOnPending 永远挂着(只剩通电前那个中心亮点)。
        // 第一版就是栽在这:录出 331 帧全是黑屏加一个白点。
        // 录演示动图本来就该看得见画面,所以这里跟自测探针的取舍正好相反。
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        // 内置的 13 款复古点阵字体是进程级注册的(不装进系统),GUI 走 AppDelegate
        // 那条路会注册,harness 不会 —— 漏了这一句,预设指定的 Terminus / IBM VGA8
        // 全部回退 Menlo,录出来的"复古终端"用的是 macOS 自带等宽字体。
        FontLibrary.registerBundledFonts()

        // 波特率限速:演示的主角。跟着配置走(v1.4 语义),所以直接写进 cfg 再建窗。
        var cfg = options.config ?? CRTConfig()
        cfg.bitRate = bitRate
        // ⚠️ 开机动画必须关掉,否则录出来是**整段黑屏**。原因值得记一笔:
        // 动画起播标志 `powerOnPending` 只在 renderTick(MTKView 的 draw 回调)里清,
        // 而 harness 环境下那个回调一路早退(窗口不算"可见");取帧走的 frameImage
        // 自己调 performCapture,所以**内容是新的、动画进度却永远是 0** ——
        // 画面于是停在"通电前"那一帧:全黑加中心一个小白点。
        // 别的动态特效(换台/消磁/噪点/闪烁/光标)都在 buildUniforms 里现算,不受影响。
        cfg.powerOnEffect = false
        var opts = options
        opts.config = cfg

        let wc = TerminalWindowController(options: opts)
        guard let window = wc.window,
              let tv = wc.terminalViewForTesting,
              let overlay = wc.overlayForTesting else {
            FileHandle.standardError.write(Data("demo-gif: 组件不可用\n".utf8))
            return 1
        }
        window.orderFront(nil)
        window.makeKeyAndOrderFront(nil)

        // ---- 等 shell 就绪(同 auto-drive:轮询到提示符稳定,不用固定睡眠)----
        func screenLine() -> String {
            let t = tv.getTerminal()
            for row in stride(from: t.rows - 1, through: 0, by: 0 - 1) {
                guard let line = t.getLine(row: row) else { continue }
                var s = ""
                for col in 0..<t.cols {
                    let ch = line[col].getCharacter()
                    if ch != "\0" { s.append(ch) }
                }
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            return ""
        }
        var waited = 0.0
        var lastSeen = ""
        while waited < 15 {
            pump(0.5)
            waited += 0.5
            let now = screenLine()
            if !now.isEmpty && now == lastSeen && waited >= 1.5 { break }
            lastSeen = now
        }

        // 画面尺寸:按字符网格反推窗口大小,让演示画面比默认窗口宽敞些。
        // **必须先渲一帧**才知道一格多大(字形图集建好、focusedCellPx 才有值)——
        // frameImage 内部会调 performCapture,拿它当预热正好,返回值丢掉不用。
        _ = overlay.frameImage()
        let cell = overlay.focusedCellPxForTesting
        if cell.w > 0, cell.h > 0 {
            let scale = window.backingScaleFactor
            window.setContentSize(NSSize(width: CGFloat(cols * cell.w) / scale + 24,
                                         height: CGFloat(rows * cell.h) / scale + 24))
            pump(0.8)   // 等 resize 与重排落地
        }

        // ---- 录制前的布景(这些都不进画面)----
        // ① 固定提示符 + 清掉 p10k/omz 的 precmd hook(否则下一次回车就被它改回去);
        // ② 演示素材写到**短路径**的临时文件 —— 命令行里那串真实临时目录
        //    (/var/folders/5d/rv7…)又长又难看,还会把本机路径录进公开动图;
        // ③ cd 过去,这样画面上只剩 `cat banner.txt`;④ clear,从干净一屏开始。
        let demoDir = "/tmp/yeterm-demo"
        try? FileManager.default.createDirectory(atPath: demoDir, withIntermediateDirectories: true)
        try? demoBanner.write(toFile: demoDir + "/banner.txt", atomically: true, encoding: .utf8)
        try? ansiPalette.write(toFile: demoDir + "/colors.txt", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: demoDir) }

        // 固定提示符 + 关掉一切"会自己往命令行上写字"的插件。zsh-autosuggestions
        // 尤其要关:它按历史给灰字补全,第一版录出来的画面上,`cat b` 后面直接
        // 拖着上一条命令的完整临时路径 —— 既难看又把本机路径录进公开动图。
        tv.send(txt: "precmd_functions=(); PROMPT='yeterm@crt ~ $ '; unset RPROMPT\n")
        pump(0.5)
        tv.send(txt: "(( $+functions[_zsh_autosuggest_disable] )) && _zsh_autosuggest_disable; HISTFILE=/dev/null; unsetopt correct correct_all 2>/dev/null\n")
        pump(0.6)
        tv.send(txt: "cd \(demoDir)\n")
        pump(0.5)
        tv.send(txt: "clear\n")
        pump(0.8)

        // ---- 演示脚本 ----
        // settle 按「输出字节数 ÷ 限速」估,再留一点余量。限速 2400 bps = 300 B/s。
        // 命令一律挑**短而好认**的:观众要看的是画面,不是一行 shell 语法
        // (第一版写了个 for 循环打印色块,80 多个字符光打字就占掉四秒,直接砍掉 ——
        //  色块改成 cat 一个预先存好 ANSI 转义的文件,一样的输出,命令只剩 15 个字符)。
        let beats: [Beat] = [
            .init(command: "uname -srm", settle: 0.7),
            .init(command: "echo '你好，世界 — CJK × 扫描线,列宽照样对齐 テスト 한글'", settle: 0.9),
            .init(command: "cat banner.txt", settle: 2.6),
            .init(command: "ls -G /usr", settle: 1.0),
        ]
        // ⚠️ ANSI 色块**不能**放在这里演示。前四条跑在单色磷光主题(IBM 5151 绿 /
        // VT220 琥珀)下,那种屏幕物理上就只有一种颜色 —— 16 色块会被荧光染色
        // 压成一条白棒,看着像 bug 其实是对的。所以色块留到最后切了彩色主题
        // (「经典配色」组,色彩浓度 1 = 原色保真)再放,顺带把两种屏幕的差别演出来。

        wc.startGIFRecording()
        defer { if wc.gifRecordingForTesting { _ = wc.finishGIFRecording(to: URL(fileURLWithPath: outPath)) } }
        pump(0.5)

        for beat in beats {
            typeOut(tv, beat.command)
            tv.send(txt: "\n")
            pump(beat.settle)
        }

        // ---- 复古特效秀:换主题(换台闪断)→ 消磁彩蛋 → 再换一台 ----
        // 这三样是静态截图永远拍不出来的,GIF 的意义正在于此。
        // 画面上的说明一律用英文:这张图挂在英文 README 和 Release 页上,
        // 中日韩那条命令是**用来展示字体渲染**的,不需要读懂,说明则要。
        func switchTheme(_ name: String) {
            guard var next = Presets.byName(name) else { return }
            next.bitRate = bitRate
            next.powerOnEffect = false          // 同上:harness 里播不动,别让它把画面掐黑
            // ⚠️ 必须清掉预设自带的提示符主题。IBM VGA 这类 DOS 系预设带 `C:\>` 提示符,
            // 而提示符热切换的深水路径会 `exec zsh` **重载整个会话** —— 录制中途撞上它,
            // 正在敲的命令连同回车一起被吞,画面就永远停在"打了一半"的那行
            // (查了半天:帧数一直在涨、录制状态也正常,只有屏幕内容不动了)。
            // 顺带也保住了录制前设好的干净提示符与关掉的 autosuggestions。
            next.promptTheme = nil
            wc.applySettings(next, fontSize: options.fontSize, cursorStyle: options.cursorStyle)
            overlay.playChannelSwitch(force: true)
            pump(1.0)
        }

        switchTheme("DEC VT220")
        typeOut(tv, "echo amber phosphor")
        tv.send(txt: "\n")
        pump(0.9)

        typeOut(tv, "echo degauss")
        tv.send(txt: "\n")
        pump(0.6)
        wc.degaussAction(nil)
        pump(1.5)

        // 收尾:切到 IBM VGA —— 仍是「经典 CRT」组(扫描线/弧度/机壳/色差全在),
        // 但它的色彩浓度是 0.5,即**彩色显像管**,于是同一份色块在这里显得出颜色。
        // 特意不用「经典配色」组的现代主题收尾:那组把设备特征全关了,画面会
        // 突然"变现代",跟这张图要讲的复古特效唱反调。
        switchTheme("IBM VGA")
        typeOut(tv, "cat colors.txt")
        tv.send(txt: "\n")
        pump(1.5)
        typeOut(tv, "echo 43 presets")
        tv.send(txt: "\n")
        pump(1.5)
        let url = URL(fileURLWithPath: outPath)
        guard let saved = wc.finishGIFRecording(to: url) else {
            FileHandle.standardError.write(Data("demo-gif: 录制失败(没有帧?)\n".utf8))
            return 1
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: saved.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        print("demo-gif: \(saved.path) (\(String(format: "%.1f", Double(bytes) / 1_048_576.0)) MB)")
        return 0
    }

    /// 模拟人在打字:逐字符注入 + 小抖动的间隔。
    /// 匀速打字看着像机器人,所以按字符类型给一点变化(空格后稍顿,像在想)。
    private static func typeOut(_ tv: EventTerminalView, _ text: String) {
        for ch in text {
            tv.send(txt: String(ch))
            pump(ch == " " ? 0.055 : 0.035)
        }
        pump(0.18)   // 敲完停一拍再回车,像真人
    }

    /// 演示用 ASCII art。限速吐字的效果在这种整块图形上最直观 ——
    /// 一行一行扫出来,正是老终端接调制解调器的样子。
    private static let demoBanner = """
    ██  ██ ███████ ████████ ███████ ██████  ███    ███
     ████  ██         ██    ██      ██   ██ ████  ████
      ██   █████      ██    █████   ██████  ██ ████ ██
      ██   ██         ██    ██      ██   ██ ██  ██  ██
      ██   ███████    ██    ███████ ██   ██ ██      ██

        arm64 native  ·  any font × CJK  ·  43 presets

    """

    /// ANSI 16 色块。存成**带转义序列的文件**再 cat,是为了让画面上的命令保持
    /// 短小(`cat colors.txt`)——观众要看的是色块被荧光染色后的样子,不是 shell 语法。
    private static let ansiPalette: String = {
        let esc = "\u{1B}"
        let names = ["red", "green", "yellow", "blue", "magenta", "cyan"]
        // 用「小方块 + 色名」而不是一长条实心块:大片实心块会把辉光和白热化
        // 一起喂饱,几个颜色糊成一根发白的棒子(第一版就是这样);带间隔的短块
        // 加上同色文字,既看得出颜色又看得出笔画被磷光染色的样子。
        var s = "\n  ANSI colors on a color CRT\n\n"
        for (i, name) in names.enumerated() {
            s += "  \(esc)[3\(i + 1)m██ \(name)\(esc)[0m"
        }
        s += "\n"
        return s
    }()

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
