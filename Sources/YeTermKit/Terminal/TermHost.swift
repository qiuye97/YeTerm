// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 终端视图的"组装工厂"
//
// 这个文件:集中做三件初始化脏活 —— ①启动 /bin/zsh 并接上 PTY(伪终端:
//   操作系统提供的"假键盘假屏幕"管道,shell 以为自己连着真终端;
//   类比一条双向 socket:我们写入=敲键盘,读出=屏幕输出);
//   ②准备环境变量(TERM/LANG,否则 Finder 双击启动时环境近乎为空,中文变问号);
//   ③解析字体(含 fontWidth 字宽:给字体挂横向缩放矩阵)。
// 类比 Spring:一个 @Configuration 工厂类,new 对象+注入配置集中在一处。
//
// 语法看点:
//   `enum TermHost { static func ... }` —— 又是"枚举当命名空间"(见 YeTermCLI)。
//   `CTFontCreateWithName(... &m)` —— 调 C 风格 API:`&m` 是取地址传指针
//     (Swift 里叫 inout 传参),CoreText/CoreGraphics 这类底层框架常见。
//   `as NSFont` 的 toll-free 桥接 —— CTFont 和 NSFont 是同一块内存的两张脸,
//     免拷贝互转(Apple 底层 C 框架与上层对象框架的历史设计)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import CoreText
import SwiftTerm

/// TerminalView 装配:字体、环境变量、shell 启动。
/// 集中在一处,S6(overlay)与 M1a(隐形输入宿主)都复用。
enum TermHost {
    /// 实际 spawn 的 shell 可执行文件。**`SHELL` 环境变量必须与它一致** ——
    /// 二者是同一件事实的两个出口,分头写死迟早对不上(见 shellEnvironment)。
    static let shellPath = "/bin/zsh"
    /// argv[0] 带横杠 = login shell 惯例(zsh 据此去读 ~/.zprofile、
    /// /etc/zprofile 里的 path_helper —— YeTerm 的 $PATH 全靠这条重建,
    /// 因为 SwiftTerm 的白名单**故意不透传 PATH**)
    static let shellExecName = "-zsh"

    /// 版本号:打包后从 Info.plist 读(唯一真源在 scripts/make_app.sh,
    /// 不在 Swift 侧再抄一份,免得两处对不上);`swift run` 直跑无 bundle → "dev"。
    /// 【学】Bundle.main.infoDictionary 就是读 app 包里的 Info.plist(一张
    ///   key-value 表,类比 Java 的 MANIFEST.MF / Spring 的 application.yml);
    ///   `as? String` 是可失败类型转换,转不动给 nil,再由 `??` 兜底。
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// PTY 环境变量装配 —— **唯一出口**(makeShellView 与 DrawOffProbe 共用,
    /// 探针也可不 spawn 直接断言)。此前两处各拼一份,正是 SHELL 漏传的温床。
    ///
    /// SwiftTerm 的 `getEnvironmentVariables` 只给 TERM/COLORTERM/LANG,
    /// 外加透传白名单 LOGNAME/USER/DISPLAY/LC_TYPE/HOME —— 缺的都得我们自己补。
    static func shellEnvironment(promptTheme: String? = nil) -> [String] {
        // 环境:xterm-256color + UTF-8 LANG 兜底
        // (从 Finder 双击启动时环境近乎为空,没有 LANG 中文会变问号)
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !env.contains(where: { $0.hasPrefix("LANG=") }) {
            env.append("LANG=zh_CN.UTF-8")
        }
        // ── SHELL(2026-07-30 micro 实测暴露的漏传)──────────────────────────
        // 病因:**zsh 自己不设 SHELL**,平时是 login/Terminal.app 在 spawn 时
        // 塞进去的;SwiftTerm 白名单里又没有它 → YeTerm 里 $SHELL 恒为空。
        // 后果不是"shell 起不来"(zsh 跑得好好的),而是**凡是靠 $SHELL 去
        // 「再开一个子 shell」的程序全部失灵**:micro 的 :term 直接报
        // "Shell environment not found",fzf/lazygit/ranger 等同类。
        // 取值必须是 shellPath(我们真正跑的那个),不是用户数据库里的登录 shell:
        // 这张便签描述的是"当前会话在跑什么",与事实不符比空着更坏。
        env.removeAll { $0.hasPrefix("SHELL=") }
        env.append("SHELL=\(shellPath)")
        // shell 集成脚本靠它识别"跑在 YeTerm 里"(iTerm2/Terminal.app 同款惯例);
        // 配套的 VERSION 供程序做版本门槛判断(neovim 等会读)
        env.removeAll { $0.hasPrefix("TERM_PROGRAM=") || $0.hasPrefix("TERM_PROGRAM_VERSION=") }
        env.append("TERM_PROGRAM=YeTerm")
        env.append("TERM_PROGRAM_VERSION=\(appVersion)")
        if let prompt = promptTheme, !prompt.isEmpty {
            env.append("YETERM_PROMPT=\(prompt)")
        }
        return env
    }

    /// 创建并启动跑真实 shell 的事件驱动终端视图。
    /// `cwd`(v1.2 #2 会话恢复):shell 的起始工作目录 —— 子进程继承父进程 cwd,
    /// 所以在 spawn 前短暂切换本进程目录、spawn 后立刻切回(主线程串行,无竞态)。
    static func makeShellView(frame: CGRect, options: LaunchOptions,
                              cwd: String? = nil) -> EventTerminalView {
        let tv = EventTerminalView(frame: frame)
        tv.notifyUpdateChanges = true   // 开启 rangeChanged 事件(事件驱动渲染的信号源)
        tv.installCommandMarks()   // OSC 133 命令书签(v1.2 #3;shell 集成装了才有数据)
        tv.installITerm2ImageHandler()   // OSC 1337 接管:补 imgcat 多段协议(v1.2 #4)
        tv.installPromptReadyHandler()   // OSC 7777 握手:提示符热切换(v1.3)
        tv.font = resolveFont(name: options.fontName, size: options.fontSize,
                              width: CGFloat(options.config?.fontWidth ?? 1))
        // 字符网格右/下侧「余量条」默认用系统浅色背景 —— 必须与终端底色一致,
        // 否则弧度特效会把它拉成亮带(M0-S5 实测教训)
        tv.nativeBackgroundColor = .black
        hideNativeScroller(tv)

        // 提示符主题(v1.3):当前主题的 promptTheme 经环境变量传给集成脚本。
        // 只在 shell 启动时注入 = "仅新会话生效"的机制根据;currentPromptTheme
        // 由 applySettings 广播刷新(切主题后 ⌘T 的新 shell 即拿到新值),
        // 启动路径回落 options.config(首窗在任何广播之前创建)
        let promptTheme = currentPromptTheme ?? options.config?.promptTheme
        let env = shellEnvironment(promptTheme: promptTheme)
        // 状态文件先行(热切换机制的读取源;env 只是兜底)—— shell 起跑前保证最新
        ShellIntegration.writePromptTheme(promptTheme)

        // 会话恢复的 cwd 注入:目录已消失(U 盘拔了/被删)则跳过,shell 从默认目录起
        var restoreDir: String?
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            restoreDir = FileManager.default.currentDirectoryPath
            FileManager.default.changeCurrentDirectoryPath(cwd)
        }
        // execName "-zsh":argv[0] 带横杠 = login shell 惯例(读 ~/.zprofile 等)
        tv.startProcess(executable: shellPath,
                        environment: env,
                        execName: shellExecName)
        if let back = restoreDir {
            FileManager.default.changeCurrentDirectoryPath(back)
        }
        // 小件三连(v1.2 #8):滚回行数(上游默认才 500,长日志翻不回去)+ Option=Meta
        tv.getTerminal().changeScrollback(options.config?.scrollbackLines ?? 10000)
        tv.optionAsMetaKey = options.config?.optionAsMeta ?? true
        // 波特率限速(v1.4):这条也必须在 **建 pane 时**就设 —— 只靠设置广播的话,
        // 启动首窗在首次广播前是不限速的,shell 的欢迎信息会"啪"一下全出来(v1.2
        // 的 margin 就踩过同一个坑,见 TerminalWindowController init 路径注释)
        tv.outputBitRate = options.config?.bitRate ?? 0
        return tv
    }

    /// 隐藏 SwiftTerm 内嵌的 NSScroller(私有子视图,无公开开关):
    /// overlay 滚动条收起后仍在最右缘留 ~1px 灰痕,会被捕获并被弧度特效拉成亮线。
    /// 复古 CRT 终端不要原生滚动条;滚动回看后续自绘。
    static func hideNativeScroller(_ tv: TerminalView) {
        for sub in tv.subviews where sub is NSScroller {
            sub.isHidden = true
        }
    }

    /// `width`(crterm fontWidth 语义,0.5~1.5):横向缩放字体矩阵。
    /// 关键:SwiftTerm 的列宽(advancement)与图集栅格化(CTFontGetMatrix)都从
    /// 这同一个矩阵字体取值 —— 输入宿主几何与渲染几何天然同源一致。
    /// 注意不能用 NSFont(descriptor:textTransform:):它会整个替换字体矩阵、
    /// 连字号缩放一起丢(实测字号退化成 1pt);走 CTFont toll-free 桥才正确。
    /// 当前生效的提示符主题(v1.3;主线程读写)。设置广播刷新,新 shell 启动时读
    static var currentPromptTheme: String?

    static func resolveFont(name: String, size: CGFloat, width: CGFloat = 1) -> NSFont {
        let base: NSFont
        if let f = NSFont(name: name, size: size) {
            base = f
        } else if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            // PostScript 名未命中 → 按 family 名再试(crterm 配置存的是显示名,如 "Zpix Mono")
            base = f
        } else {
            FileHandle.standardError.write(Data("字体 '\(name)' 未找到,回退 Menlo\n".utf8))
            base = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // 用户 fontWidth 矩阵(crterm 语义)
        let widthApplied: NSFont
        if abs(width - 1) > 0.001 {
            var m = CGAffineTransform(scaleX: width, y: 1)
            widthApplied = CTFontCreateWithName(base.fontName as CFString, size, &m) as NSFont
        } else {
            widthApplied = base
        }
        // 列宽对齐补偿(2026-07-29 选区错位勘差):SwiftTerm 鼠标列换算用原始
        // advance(浮点),我们的网格渲染用整像素 cell —— 两者每列差零点几像素,
        // Zpix 80 列末累积 ~3 列。把 advance 用矩阵微缩放对齐到**半逻辑点**
        // (round(adv×2)/2,Retina 下恰为整物理像素;Menlo +0.8%、Zpix −2%,
        // 视觉无感),hit-test 与渲染共用此字体 → 列位逐点一致。
        // ⚠️ 测量必须走 CTFontGetGlyphsForCharacters(2026-08-26 选区列漂移勘差):
        // glyph(withName:"W") 依赖字体 post 表的字形名,像素字体(Ark Pixel 等)
        // 常整个省略 → 静默返回 .notdef(advance 是全宽 em,真实列宽的两倍),
        // 补偿会按错误目标缩放真实字形。与 GlyphAtlas.cellSize 同一查法,天然同源。
        var wChar: [UniChar] = [0x57]   // 'W'
        var wGlyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(widthApplied as CTFont, &wChar, &wGlyph, 1)
        var wAdvance = CGSize.zero
        CTFontGetAdvancesForGlyphs(widthApplied as CTFont, .horizontal, &wGlyph, &wAdvance, 1)
        let adv = wAdvance.width
        guard adv > 0.5 else { return widthApplied }
        let target = max(round(adv * 2) / 2, 1)
        let comp = target / adv
        guard abs(comp - 1) > 0.0005 else { return widthApplied }
        var m2 = CGAffineTransform(scaleX: width * comp, y: 1)
        return CTFontCreateWithName(base.fontName as CFString, size, &m2) as NSFont
    }
}
