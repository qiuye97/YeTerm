// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 命令行分发器(阅读顺序第 2 站,上一站 main.swift)
//
// 这个文件:看命令行参数决定程序干什么 —— 不带参数就打开图形界面(GUI),
//   带 --smoke-term / --render-demo / --probe-xxx 就跑对应的自测命令。
// 类比 Web:相当于一个"路由器/Controller 分发",URL(这里是参数)→ 处理器。
//   这些自测命令是本项目的特色:Claude 没长眼睛看屏幕,靠它们离屏截图、
//   断言行为,自己验证自己写的代码(相当于把"手工点点点"做成了自动化测试)。
//
// 语法看点:
//   `enum YeTermCLI { static func ... }` —— Swift 惯用"无成员枚举当命名空间",
//     类比 Java 里只有静态方法的工具类(enum 不能被实例化,比 class 更严谨)。
//   `if let x = ... { }` —— "可选值解包":Swift 的变量默认不允许为 nil,
//     可能没有值的类型写作 `String?`(类比 Java 的 Optional<String>);
//     if let 表示"如果里面真有值,取出来用",没值就跳过,从根上消灭 NPE。
//   `args.firstIndex(of:)` —— 数组查找,返回的也是可选值(找不到 = nil)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Foundation

/// CLI 分发入口:main.swift 薄壳直接调这里。
/// 模式:
///   --smoke-term            无界面内核冒烟(CJK 宽字符/filler/SGR 属性解码断言)
///   (默认)                  GUI 跑真实 shell
/// 通用参数:
///   --font <name>           终端字体(默认 Menlo)
///   --font-size <n>         字号(默认 14)
public enum YeTermCLI {
    public static func main(_ args: [String]) -> Int32 {
        if args.contains("--smoke-term") {
            return TermProbe.runSmoke()
        }

        if args.contains("--list-presets") {
            Presets.names.forEach { print($0) }
            return 0
        }

        if args.contains("--probe-draw-off") {
            return DrawOffProbe.run()
        }

        // 本地网络权限自检(2026-07-30 事故工具):必须用 **app 包内的二进制** 跑,
        // 才是以 YeTerm 身份向系统申请;裸 .build 二进制不是 app,系统不认。
        //   YeTerm.app/Contents/MacOS/YeTerm --probe-localnet 192.168.1.200
        if let i = args.firstIndex(of: "--probe-localnet") {
            // 必须是 **前台正规 app**(.regular + activate):后台/accessory 身份
            // 拿不到隐私授权弹窗(2026-07-30 实测:accessory launch 全程静默)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            let host = i + 1 < args.count ? args[i + 1] : nil
            var done = false
            var result = ""
            LocalNetworkPermission.runDiagnostic(probeHost: host) { msg in
                result = msg
                done = true
            }
            let deadline = Date().addingTimeInterval(12)
            while !done, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            print(result.isEmpty ? "LOCALNET-PROBE 超时(未收到结果)" : "LOCALNET-PROBE \(result)")
            return 0
        }

        // 连通测试自检(v1.3):--probe-ssh user@host[:port] —— 与设置页「测试连通」
        // 同一条逻辑(含算法自动降级),便于我在命令行端到端验真机
        if let i = args.firstIndex(of: "--probe-ssh"), i + 1 < args.count {
            let spec = args[i + 1]
            var host = SSHHost()
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                print("用法:--probe-ssh user@host[:port]")
                return 2
            }
            host.user = parts[0]
            var hp = parts[1]
            if let c = hp.lastIndex(of: ":"), let p = Int(hp[hp.index(after: c)...]) {
                host.port = p
                hp = String(hp[..<c])
            }
            host.host = hp
            var done = false
            SSHConnectivity.test(host: host) { r in
                print("SSH-PROBE ok=\(r.ok) \(r.summary)"
                      + (r.legacyOptions.isEmpty ? "" : " | 兼容参数: \(r.legacyOptions)"))
                done = true
            }
            let deadline = Date().addingTimeInterval(30)
            while !done, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if !done { print("SSH-PROBE 超时") }
            return 0
        }

        if let i = args.firstIndex(of: "--probe-settings"), i + 1 < args.count {
            return SettingsProbe.run(outPrefix: args[i + 1])
        }

        // 分层性能探针:把「VT 解析」与「实例构建」分开计时,定位慢在哪一层
        // (横向跑分 scripts/bench.sh 只能测端到端,说不出是哪一层)
        if args.contains("--perf-probe") {
            let mb = value(after: "--perf-mb", in: args).flatMap(Double.init) ?? 6.0
            return PerfProbe.run(mb: mb)
        }

        if args.contains("--probe-selection") {
            var options = LaunchOptions()
            if let cfg = resolveConfig(args) {
                options.config = cfg
                if let f = cfg.resolvedFontName { options.fontName = f }
            }
            return SelectionProbe.run(options: options)
        }

        if args.contains("--probe-windows") {
            var options = LaunchOptions()
            if let cfg = resolveConfig(args) {
                options.config = cfg
                if let f = cfg.resolvedFontName { options.fontName = f }
            }
            return WindowProbe.run(options: options)
        }

        if let i = args.firstIndex(of: "--auto-drive"), i + 1 < args.count {
            var options = LaunchOptions()
            if let cfg = resolveConfig(args) {
                options.config = cfg
                if let f = cfg.resolvedFontName { options.fontName = f }
            }
            if let v = value(after: "--font", in: args) { options.fontName = v }
            if let v = value(after: "--font-size", in: args), let n = Double(v) { options.fontSize = CGFloat(n) }
            return AutoDrive.run(outPrefix: args[i + 1], options: options)
        }

        if let i = args.firstIndex(of: "--render-demo"), i + 1 < args.count {
            var opt = RenderDemoOptions(outPath: args[i + 1])
            if let v = value(after: "--cols", in: args), let n = Int(v) { opt.cols = n }
            if let v = value(after: "--rows", in: args), let n = Int(v) { opt.rows = n }
            if let v = value(after: "--font", in: args) { opt.fontName = v }
            if let v = value(after: "--font-size", in: args), let n = Double(v) { opt.fontSize = CGFloat(n) }
            if let v = value(after: "--frames", in: args), let n = Int(v) { opt.frames = n }
            if args.contains("--no-effects") { opt.effects = "off" }
            if let v = value(after: "--effects", in: args) { opt.effects = v }
            if let v = value(after: "--compare-with", in: args) { opt.compareWith = v }
            if let v = value(after: "--tolerance", in: args), let n = Int(v) { opt.tolerance = n }
            if let v = value(after: "--time", in: args), let n = Double(v) { opt.time = n }
            if let v = value(after: "--shader-dir", in: args) { opt.shaderDir = v }
            if let v = value(after: "--tint", in: args) { opt.tint = v }
            if let v = value(after: "--raster", in: args), let n = Int(v) { opt.rasterMode = n }
            if let v = value(after: "--vres-y", in: args), let n = Double(v) { opt.vresY = n }
            if args.contains("--debug-cursor") { opt.debugCursor = true }
            if let v = value(after: "--fixture", in: args) { opt.fixturePath = v }
            if let v = value(after: "--config", in: args) { opt.configPath = v }
            if let v = value(after: "--preset", in: args) { opt.presetName = v }
            if let v = value(after: "--preedit", in: args) { opt.preeditText = v }
            if let v = value(after: "--power-on", in: args), let n = Double(v) { opt.powerOn = n }
            if let v = value(after: "--boot-time", in: args), let n = Double(v) { opt.bootTime = n }
            if let v = value(after: "--degauss", in: args), let n = Double(v) { opt.degauss = n }
            if let v = value(after: "--plain-bg", in: args) { opt.plainBGPath = v }
            if let v = value(after: "--plain-bg-mode", in: args), let n = Int(v) { opt.plainBGMode = n }
            if let v = value(after: "--plain-bg-blur", in: args), let n = Double(v) { opt.plainBGBlur = n }
            if let v = value(after: "--plain-bg-palette", in: args), let n = Int(v) { opt.plainBGPalette = n }
            // 字体跟预设(v1.2 #15):未显式 --font 时用预设/配置里的匹配字体,
            // 与 GUI 启动路径同语义(显式 flag 永远赢)
            if value(after: "--font", in: args) == nil,
               let cfg = opt.presetName.flatMap({ Presets.byName($0) })
                   ?? opt.configPath.flatMap({ CRTConfig.load(path: $0) }),
               let f = cfg.resolvedFontName {
                opt.fontName = f
            }
            return RenderDemo.run(opt)
        }

        // 【学】走到这里 = 没匹配任何自测命令 → 正常打开 GUI。
        //      LaunchOptions 是个"启动参数包"结构体,一路传给窗口/终端用
        var options = LaunchOptions()
        // 配置来源:--preset > --config > ~/Library/Application Support/YeTerm/config.json
        if let cfg = resolveConfig(args) {
            options.config = cfg
            if let f = cfg.resolvedFontName { options.fontName = f }
            if let fs = cfg.fontSize { options.fontSize = CGFloat(fs) }
        }
        if let name = value(after: "--font", in: args) {
            options.fontName = name
        }
        if let sizeStr = value(after: "--font-size", in: args), let size = Double(sizeStr) {
            options.fontSize = CGFloat(size)
        }
        if let style = value(after: "--cursor-style", in: args) {
            switch style {
            case "underline": options.cursorStyle = 1
            case "bar": options.cursorStyle = 2
            default: options.cursorStyle = 0
            }
        }
        return AppRunner.runGUI(options: options)
    }

    /// 取 `--flag value` 形式的值
    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 配置解析:--preset 内置预设名 > --config 文件 > 默认路径
    static func resolveConfig(_ args: [String]) -> CRTConfig? {
        if let name = value(after: "--preset", in: args) {
            if let p = Presets.byName(name) { return p }
            FileHandle.standardError.write(Data("未知预设 '\(name)',可用: \(Presets.names.joined(separator: ", "))\n".utf8))
            return nil
        }
        if let path = value(after: "--config", in: args) {
            return CRTConfig.load(path: path)
        }
        let def = NSHomeDirectory() + "/Library/Application Support/YeTerm/config.json"
        if FileManager.default.fileExists(atPath: def) {
            return CRTConfig.load(path: def)
        }
        // 无任何配置 → 默认主题 = Default Amber(crterm 正统默认;
        // 「我的 CRT 配置」已随私人收藏组删除,v1.2 预设大更新用户裁决)
        return Presets.byName("Default Amber")
    }
}
