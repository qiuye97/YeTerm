// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 43 套内置主题的"出厂参数表"+ 每套一段出处简介
//
// 这个文件:纯数据,分两组(v1.2 预设大更新,用户裁决的三分法:
//   经典 CRT / 经典配色 / 我的配置 —— 前两组在这里,"我的配置"是用户
//   自己保存的配置文件,设置页单独一区展示):
//   ① 经典 CRT(21 套):对真实复古设备的还原主题 —— crterm 官方预设里的
//      设备主题 + YeTerm 补充的历史机器,磷光颜色/弧度/余辉都按设备特性调;
//      v1.2 逐套打磨:抖动全部 ≤0.08、闪烁/噪点收敛到实用水平(还原味道
//      保留,长时间使用不晃眼 —— 用户裁决"兼容还原和实用性")。
//   ② 经典配色(22 套):配色方案与风格创作 —— 程序员圈现代名配色
//      (Solarized/Dracula/Catppuccin…)+ crterm 里的非设备风格创作
//      (Neon Cyan/Plasma/E-Ink…)。现代配色**携带官方 ANSI 16 色表**
//      (ansi 参数):vim/htop 的彩色输出也是该主题的原汁色板。
//   经典 CRT 主题一律**不带** ansi(nil = crterm 专属调色板)—— 用户裁决:
//   荧光染色考据观感靠专属调色板,不给内置经典 CRT 配 ANSI 定制。
//   每套预设配**匹配的字体**(font 参数):复古机型配本机年代的点阵字体,
//   现代配色配现代等宽 —— 切主题即换整套观感。
//   blurbs 字典 = 每套预设一段中文简介(设备年代/出处/风格),
//   只在设置页展示,**不进 JSON**(不污染配置文件、不破坏导入导出兼容)。
//
// 类比 Java:一个静态常量表 List<Config> + Map<String,String>,
//   make(...) ≈ builder 的紧凑版,少写 40 遍重复字段名。
// 语法看点:`(title: String, names: [String])` —— 带标签元组,轻量级
//   "临时小结构体"(类比 record/Pair),做分组这种小事不必专门定义类型。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

/// 内置预设。crterm 系参数以 cool-retro-term 的 `settings/AppSettings.qml`
/// 为底(2026-07 侦察),v1.2 大更新后按用户裁决打磨偏离原值处见各行注释;
/// 全部标 version 3(弧度 ×0.6 语义)。
///
/// 字体引用 = 注册后的 family 名(裸名,resolvedFontName 原样返回):
/// 内置 13 款复古字体 family 见 FontLibrary.retroFonts 注册结果;
/// Menlo/Monaco 为 macOS 系统必带。改字体文件名/版本后 family 名可能变,
/// 探针有"预设字体可解析"断言兜底。
///
/// 组②「经典配色」的色准约定:contrast=1.0 + saturation=0 + brightness=0.5 ——
/// 按预混色公式(见 CRTConfig 的「颜色数学」一节)此时 fontColor/backgroundColor 不掺混、增益 1.0,
/// 十六进制色值**精确上屏**;chroma=1 保留 ANSI 彩色(官方 ANSI 表原样呈现)。
/// 改这三个值会跑色。
public enum Presets {
    public static func byName(_ name: String) -> CRTConfig? {
        all.first { $0.name?.lowercased() == name.lowercased() }
    }

    public static var names: [String] {
        all.compactMap { $0.name }
    }

    /// 预设简介(设置页展示;返回 nil = 用户自定义配置,无出处可讲)
    ///
    /// 【i18n】下面 `blurbs` 表里的**键是预设名 = 标识符**(存进 config.json、
    /// 菜单打勾比对都靠它),一个字都不能动;只有取出来的**值**过翻译层。
    public static func blurb(_ name: String) -> String? {
        blurbs[name].map { L($0) }
    }

    /// 预设名的**显示**用名。预设名本身是标识符(见 blurb 的说明),
    /// 只在往界面上摆的时候过一层翻译 —— 43 套里只有「MS-DOS 蓝」带中文。
    public static func displayName(_ name: String) -> String { L(name) }

    /// 分组(设置页按组分区展示;"我的配置"= 用户配置区,不在此表)
    /// ⚠️ 必须是计算属性:`static let` 只算一次,组名会被冻在初始化时的语言上
    public static var groups: [(title: String, names: [String])] { [
        (L("经典 CRT"), classicCRT.compactMap { $0.name }),
        (L("经典配色"), classicSchemes.compactMap { $0.name }),
    ] }

    /// 是否系统内置「经典 CRT」预设(v1.2 补丁用户裁决:设备还原主题
    /// 不可关闭 CRT 特效 —— 关掉特效它就不是那台机器了)
    public static func isClassicCRT(_ name: String) -> Bool {
        classicCRT.contains { $0.name == name }
    }

    static func make(name: String, bg: String, fg: String,
                     ambient: Double, bloom: Double, brightness: Double, burnIn: Double,
                     chroma: Double, contrast: Double, flickering: Double,
                     glowing: Double, hsync: Double, jitter: Double,
                     raster: Int, rgbShift: Double, saturation: Double,
                     curvature: Double, noise: Double, opacity: Double,
                     margin: Double, frameSize: Double, fontWidth: Double = 1,
                     font: String? = nil, ansi: [String]? = nil) -> CRTConfig {
        var c = CRTConfig()
        c.name = name
        c.version = 3
        // CRT 开关随预设走(用户裁决 2026-07-28:开关不凌驾于预设):内置全部
        // 是 CRT 主题,显式记"开"——普通模式下点任何系统预设即切回 CRT;
        // 用户自定义配置由 toConfig 记录保存时的开关状态(关着存=普通终端预设)
        c.crtEffectsEnabled = true
        c.backgroundColor = bg
        c.fontColor = fg
        c.ambientLight = ambient
        c.bloom = bloom
        c.brightness = brightness
        c.burnIn = burnIn
        c.chromaColor = chroma
        c.contrast = contrast
        c.flickering = flickering
        c.glowingLine = glowing
        c.horizontalSync = hsync
        c.jitter = jitter
        c.rasterization = raster
        c.rgbShift = rgbShift
        c.saturationColor = saturation
        c.screenCurvature = curvature
        c.staticNoise = noise
        c.windowOpacity = opacity
        c.margin = margin
        c.frameMargin = frameSize
        c.fontWidth = fontWidth
        c.fontName = font
        c.ansiColors = ansi
        return c
    }

    // ── 组①:经典 CRT(真实复古设备还原;v1.2 打磨约定:jitter ≤0.08、
    //          flickering ≤0.12、noise ≤0.15 —— 还原味道保留、久用不晃眼)──
    // 提示符主题(v1.3):设备主题成套感的最后一环 —— 点阵字体下 p10k 图标
    // 全是豆腐块(用户提此功能的动机),逐台配内置复古提示符:
    // DOS/VGA 系 = C:\> ;Commodore 系 = READY. ;其余 = 经典 user@host ASCII
    /// v1.4「文字发光」逐机型定标(白热化强度, 发白起点)。
    ///
    /// **基准是实测的**:用户提供的真 DEC VT220 照片,量出饱和度-亮度曲线呈倒 U ——
    /// 中等亮度达峰 0.647、最亮处只剩 0.108(RGB≈(227,255,255) 基本发白)。
    /// 以该曲线为靶扫参数,`(0.85, 0.20)` 的均方差 0.035(关闭时 0.376,好 10.7 倍)。
    /// 所以**单色数据终端一类直接用这组定标值**。
    ///
    /// ⚠️ **其余机型是按物理类别推的判断,不是逐台实测**(手上只有 VT220 一张参考照片)。
    /// 分三类,依据都是真实的器件差异:
    ///   ① 单色数据终端 —— 电子束驱得狠、单一磷光体、字最亮 ⇒ 过曝发白最明显(0.75~0.85);
    ///   ② 家用机接电视 —— 复合视频带宽受限 + **彩色荫罩管**:三色磷光点各自发光,
    ///      不像单色管那样整体过曝到白,且束流低 ⇒ 白热化中等、起点更高(0.50~0.55 / 0.32~0.35);
    ///   ③ 存储管(Tektronix 4014)—— 图像是**存住**的,不靠持续高束流刷新,
    ///      芯部根本不过曝 ⇒ 最弱(0.25 / 0.45)。这条是真实的原理差别,值得体现。
    /// 后期 PC 显示器(VGA/MS-DOS)聚焦好、辉光本就少,取②③之间(0.45 / 0.38)。
    private static let crtGlowTuning: [String: (od: Double, knee: Double)] = [
        // ① 单色数据终端(VT220 = 参考照片本尊,直接用定标值)
        "DEC VT220": (0.85, 0.20), "DEC VT100": (0.85, 0.20),
        "IBM 5151": (0.85, 0.20), "IBM 3278": (0.80, 0.22),
        "Default Amber": (0.85, 0.20), "Monochrome Green": (0.85, 0.20),
        "Commodore PET": (0.80, 0.20), "Macintosh 128K": (0.80, 0.25),
        "Osborne 1": (0.75, 0.22), "TRS-80 Model III": (0.75, 0.22),
        "Sharp MZ-80K": (0.75, 0.22),
        // ② 家用机接电视(彩色荫罩 + 复合视频)
        "Commodore 64": (0.50, 0.35), "Atari 400": (0.50, 0.35),
        "ZX Spectrum": (0.50, 0.35), "Amiga 500": (0.50, 0.35),
        "Apple ][": (0.55, 0.32), "Amstrad CPC 464": (0.55, 0.32),
        "BBC Micro": (0.55, 0.32),
        // 后期 PC 显示器
        "IBM VGA": (0.45, 0.38), "MS-DOS 蓝": (0.45, 0.38),
        // ③ 存储管
        "Tektronix 4014": (0.25, 0.45),
    ]

    static let classicCRT: [CRTConfig] = crtRaw.map { raw in
        var c = raw
        switch c.name {
        case "MS-DOS 蓝", "IBM VGA": c.promptTheme = "retro:dos"
        case "Commodore 64", "Commodore PET": c.promptTheme = "retro:c64"
        default: c.promptTheme = "retro:ascii"
        }
        // v1.4:逐机型白热化 + 全部换成「紧核+长尾」光晕。
        // 光晕形状对**所有**机型都设 1 —— 这是实测支持的普适改进(真 halation 的衰减
        // 比指数快、比高斯慢,单层高斯的裙边太胖);且幅度已定标到与单层等平均亮度,
        // 切过去不是"变亮了"而是"光更贴笔画、远处更干净"。
        // **刻意不动各机型原有的 bloom 值** —— 白热化接管了"亮"的观感、形状补偿保住了
        // 平均亮度,原有观感的其余部分应当保持,免得一次改太多说不清是哪一项的功劳。
        if let t = crtGlowTuning[c.name ?? ""] {
            c.overdrive = t.od
            c.overdriveKnee = t.knee
        }
        c.bloomShape = 1
        return c
    }

    private static let crtRaw: [CRTConfig] = [
        // 单色磷光屏两原型(crterm 官方参数,jitter 0.2→0.08 打磨)
        make(name: "Default Amber", bg: "#000000", fg: "#ff8100",
             ambient: 0.3, bloom: 0.6, brightness: 0.5, burnIn: 0.3, chroma: 0.2, contrast: 0.8,
             flickering: 0.1, glowing: 0.2, hsync: 0.1, jitter: 0.08, raster: 0, rgbShift: 0,
             saturation: 0.2, curvature: 0.2, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.1,
             font: "Terminus (TTF)"),
        make(name: "Monochrome Green", bg: "#000000", fg: "#0ccc68",
             ambient: 0.3, bloom: 0.5, brightness: 0.5, burnIn: 0.3, chroma: 0, contrast: 0.8,
             flickering: 0.1, glowing: 0.2, hsync: 0.1, jitter: 0.08, raster: 0, rgbShift: 0,
             saturation: 0, curvature: 0.3, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.1,
             font: "Fixedsys Excelsior 3.01-L2"),
        // 家用机(crterm 官方系,打磨见各行)
        make(name: "Commodore 64", bg: "#3b3b8f", fg: "#a9a7ff",
             ambient: 0.4, bloom: 0.4, brightness: 0.6, burnIn: 0.1, chroma: 0, contrast: 0.7,
             flickering: 0.1, glowing: 0.1, hsync: 0, jitter: 0, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.5, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.5,
             font: "C64 Pro Mono"),
        make(name: "Commodore PET", bg: "#000000", fg: "#ffffff",
             ambient: 0, bloom: 0.4, brightness: 0.5, burnIn: 0.4, chroma: 0, contrast: 0.8,
             flickering: 0.12, glowing: 0.3, hsync: 0.08, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.7, noise: 0.12, opacity: 1, margin: 0.2, frameSize: 0.5,
             fontWidth: 1.25, font: "Pet Me"),   // flicker/noise/hsync/jitter 全收敛(原 0.2/0.2/0.2/0.15)
        make(name: "Apple ][", bg: "#001100", fg: "#4dff6b",
             ambient: 0.6, bloom: 0.3, brightness: 0.5, burnIn: 0.3, chroma: 0, contrast: 0.8,
             flickering: 0.12, glowing: 0.3, hsync: 0.08, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.5, noise: 0.12, opacity: 1, margin: 0, frameSize: 0.2,
             fontWidth: 1.25, font: "Print Char 21"),   // ambient 1.0→0.6(原值机壳亮到发白),动效收敛
        make(name: "Atari 400", bg: "#0f1f5a", fg: "#8ed6ff",
             ambient: 0.1, bloom: 0.1, brightness: 0.6, burnIn: 0.2, chroma: 0, contrast: 0.9,
             flickering: 0.1, glowing: 0.1, hsync: 0, jitter: 0, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.4, noise: 0.1, opacity: 1, margin: 0.2, frameSize: 0.4,
             font: "Atari Classic"),
        // IBM 系
        make(name: "IBM VGA", bg: "#000000", fg: "#c0c0c0",
             ambient: 0.2, bloom: 0.2, brightness: 0.6, burnIn: 0.1, chroma: 0.5, contrast: 1.0,
             flickering: 0.1, glowing: 0.1, hsync: 0, jitter: 0, raster: 1, rgbShift: 0.1,
             saturation: 0, curvature: 0.3, noise: 0, opacity: 1, margin: 0.2, frameSize: 0.1,
             font: "PxPlus IBM VGA8"),
        make(name: "IBM 3278", bg: "#000000", fg: "#3cff7a",
             ambient: 0.2, bloom: 0.2, brightness: 0.5, burnIn: 0.5, chroma: 0, contrast: 0.8,
             flickering: 0, glowing: 0, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.1, frameSize: 0,
             font: "PxPlus IBM BIOS"),
        make(name: "IBM 5151", bg: "#001500", fg: "#33ff33",
             ambient: 0.25, bloom: 0.35, brightness: 0.5, burnIn: 0.6, chroma: 0, contrast: 0.85,
             flickering: 0.1, glowing: 0.25, hsync: 0.05, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.35, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.3,
             font: "PxPlus IBM BIOS"),
        // DEC 终端双雄
        make(name: "DEC VT100", bg: "#000000", fg: "#e8e8e8",
             ambient: 0.25, bloom: 0.4, brightness: 0.5, burnIn: 0.25, chroma: 0, contrast: 0.85,
             flickering: 0.1, glowing: 0.2, hsync: 0.05, jitter: 0.08, raster: 0, rgbShift: 0,
             saturation: 0, curvature: 0.3, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.3,
             font: "ProFontWindows"),
        make(name: "DEC VT220", bg: "#100800", fg: "#ffb452",
             ambient: 0.2, bloom: 0.45, brightness: 0.55, burnIn: 0.2, chroma: 0, contrast: 0.9,
             flickering: 0.05, glowing: 0.15, hsync: 0, jitter: 0.05, raster: 0, rgbShift: 0,
             saturation: 0, curvature: 0.15, noise: 0.05, opacity: 1, margin: 0.25, frameSize: 0.15,
             font: "Terminus (TTF)"),
        // 便携与欧系
        make(name: "Macintosh 128K", bg: "#e8e8e0", fg: "#1a1a1a",
             ambient: 0.5, bloom: 0.1, brightness: 0.9, burnIn: 0.15, chroma: 0, contrast: 0.6,
             flickering: 0.05, glowing: 0.05, hsync: 0, jitter: 0, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.4, noise: 0, opacity: 1, margin: 0.3, frameSize: 0.4,
             font: "Monaco"),
        make(name: "Osborne 1", bg: "#001400", fg: "#52ff52",
             ambient: 0.3, bloom: 0.35, brightness: 0.55, burnIn: 0.3, chroma: 0, contrast: 0.8,
             flickering: 0.1, glowing: 0.25, hsync: 0.1, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.7, noise: 0.15, opacity: 1, margin: 0.45, frameSize: 0.5,
             font: "ProggyTinyTT"),   // flicker 0.15→0.1, jitter 0.15→0.08
        make(name: "Amstrad CPC 464", bg: "#001a0d", fg: "#1aff8c",
             ambient: 0.3, bloom: 0.4, brightness: 0.55, burnIn: 0.25, chroma: 0, contrast: 0.8,
             flickering: 0.1, glowing: 0.3, hsync: 0.1, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.45, noise: 0.15, opacity: 1, margin: 0.3, frameSize: 0.4,
             font: "Pet Me"),
        make(name: "ZX Spectrum", bg: "#c8c8c8", fg: "#101010",
             ambient: 0.4, bloom: 0.2, brightness: 0.6, burnIn: 0.1, chroma: 1, contrast: 0.7,
             flickering: 0.12, glowing: 0.1, hsync: 0.1, jitter: 0.08, raster: 1, rgbShift: 0.25,
             saturation: 0, curvature: 0.5, noise: 0.15, opacity: 1, margin: 0.3, frameSize: 0.4,
             font: "Atari Classic"),   // RF 线味道保留(rgbShift 0.35→0.25),抖动/噪点/失步大收敛
        make(name: "MS-DOS 蓝", bg: "#0000a8", fg: "#f8f8f8",
             ambient: 0.2, bloom: 0.2, brightness: 0.55, burnIn: 0.1, chroma: 0.5, contrast: 0.95,
             flickering: 0.05, glowing: 0.1, hsync: 0, jitter: 0, raster: 1, rgbShift: 0.05,
             saturation: 0, curvature: 0.25, noise: 0, opacity: 1, margin: 0.2, frameSize: 0.1,
             font: "PxPlus IBM VGA8"),
        make(name: "Tektronix 4014", bg: "#041008", fg: "#7dffb0",
             ambient: 0.2, bloom: 0.3, brightness: 0.5, burnIn: 0.85, chroma: 0, contrast: 0.85,
             flickering: 0, glowing: 0.15, hsync: 0, jitter: 0, raster: 0, rgbShift: 0,
             saturation: 0, curvature: 0.3, noise: 0, opacity: 1, margin: 0.3, frameSize: 0.3,
             font: "Hermit"),
        make(name: "TRS-80 Model III", bg: "#000308", fg: "#dce8ff",
             ambient: 0.25, bloom: 0.3, brightness: 0.5, burnIn: 0.2, chroma: 0, contrast: 0.8,
             flickering: 0.1, glowing: 0.2, hsync: 0.05, jitter: 0.08, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.4, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.35,
             font: "Fixedsys Excelsior 3.01-L2"),
        // v1.2 大更新新增三台
        make(name: "Amiga 500", bg: "#0055aa", fg: "#ffffff",
             ambient: 0.25, bloom: 0.25, brightness: 0.55, burnIn: 0.1, chroma: 0.6, contrast: 0.9,
             flickering: 0.05, glowing: 0.1, hsync: 0, jitter: 0, raster: 1, rgbShift: 0.08,
             saturation: 0, curvature: 0.35, noise: 0.05, opacity: 1, margin: 0.25, frameSize: 0.3,
             font: "PxPlus IBM VGA8"),
        make(name: "BBC Micro", bg: "#000000", fg: "#f0f0f0",
             ambient: 0.25, bloom: 0.35, brightness: 0.55, burnIn: 0.2, chroma: 0, contrast: 0.85,
             flickering: 0.1, glowing: 0.2, hsync: 0.08, jitter: 0.06, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.45, noise: 0.12, opacity: 1, margin: 0.3, frameSize: 0.4,
             font: "Fixedsys Excelsior 3.01-L2"),
        make(name: "Sharp MZ-80K", bg: "#001200", fg: "#3aff9c",
             ambient: 0.3, bloom: 0.35, brightness: 0.5, burnIn: 0.3, chroma: 0, contrast: 0.85,
             flickering: 0.1, glowing: 0.25, hsync: 0.05, jitter: 0.06, raster: 1, rgbShift: 0,
             saturation: 0, curvature: 0.5, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.45,
             fontWidth: 1.25, font: "Pet Me"),
    ]

    // ── 组②:经典配色(配色方案与风格创作;现代配色带官方 ANSI 表,
    //          色准约定 contrast=1/sat=0/brightness=0.5)────────────────────────
    // 经典配色的本体是配色(v1.2 补丁用户裁决:CRT 开=加特效层强化,关=同套
    // 配色的素净版):普通模式三件套自动取主题自身 fg/bg/ANSI —— 关掉特效
    // 后各主题依旧各是各的配色,不再统一落到全局普通配色"全都一样"
    /// v1.4 用户裁决:经典配色统一成「CRT 模式只开辉光 + 文字发光」的干净观感。
    ///
    /// 理由:这一组是**配色方案**(Dracula / Nord / Solarized…),不是设备还原 ——
    /// 扫描线、屏幕弧度、机壳、噪点、抖动这些设备特征会干扰配色本身,
    /// 而配色方案的全部价值就在于颜色准确好看。只留「发光」这一层复古味道即可。
    ///
    /// 两套例外(用户点名保留):**Deep Blue** 与 **Matrix** —— 它们本就是按 CRT 设备气质
    /// 创作的(全套弧度/机壳/扫描线/噪点),统一掉就没了性格。
    private static let schemeUnifyExempt: Set<String> = ["Deep Blue", "Matrix"]

    /// 统一后的发光参数(全部 20 套同值)。
    /// · `bloom 0.3` —— 配色方案要的是"字在发光"而不是"糊成一片";辉光一大彩色就互相串染。
    /// · `overdrive 0.4 / knee 0.55` —— 比经典 CRT 那组(0.85/0.20)克制得多:
    ///   那组是**单色**磷光屏,芯部发白不损失信息;这组是**彩色**配色方案,
    ///   白热化过头会把精心设计的紫/青/橙一起洗成白,反而毁了配色身份。
    ///   实测彩色文字(亮度≥110 且有色相)的平均饱和度损失:
    ///     0.50/0.45 → 掉 20% ;**0.40/0.55 → 掉 16%** ;0.35/0.60 → 掉 13%。
    ///   取中档:发光感还在,颜色保住 ~84%。再往上 256 色那行的红会明显发浅。
    /// · `bloomShape 1`(紧核+长尾)—— 光更贴笔画、远处更干净,彩色文字尤其不该被弥散光糊到。
    private enum SchemeGlow {
        static let bloom = 0.3
        static let overdrive = 0.4
        static let overdriveKnee = 0.55
    }

    static let classicSchemes: [CRTConfig] = schemesRaw.map { raw in
        var c = raw
        if !schemeUnifyExempt.contains(c.name ?? "") {
            // ── 留下的两项:辉光 + 文字发光 ──
            c.bloom = SchemeGlow.bloom
            c.overdrive = SchemeGlow.overdrive
            c.overdriveKnee = SchemeGlow.overdriveKnee
            c.bloomStyle = 0            // 柔雾(实测更接近真实 CRT)
            c.bloomShape = 1            // 紧核 + 长尾
            // ── 其余设备特征一律关 ──
            c.rasterization = 4         // 4 = 无光栅(直通),不要扫描线/像素网格
            c.screenCurvature = 0       // 屏幕弧度关
            c.frameMargin = 0           // 机壳关(frameOn 还要 frameEnabled,一并按死)
            c.frameEnabled = false
            c.burnIn = 0
            c.staticNoise = 0
            c.flickering = 0
            c.glowingLine = 0
            c.horizontalSync = 0
            c.jitter = 0
            c.rgbShift = 0
            // ⚠️ 历史拼写字段也必须清:apply() 里是 `rgbShift ?? rbgShift ?? 0`,
            //    只清前者的话旧值会从后者捡回来(容错解析留下的坑)
            c.rbgShift = 0
            c.ambientLight = 0
        }
        c.plainTextColor = c.fontColor
        c.plainBackgroundColor = c.backgroundColor
        if let a = c.ansiColors { c.plainAnsiColors = a }
        return c
    }

    private static let schemesRaw: [CRTConfig] = [
        // crterm 系风格创作(自组①挪入 —— 非具体设备,按用户三分法归配色)
        // 风格创作七套的配套 ANSI 表(v1.2 补丁用户追加"都要有专属配色"):
        // 非官方移植 —— 按各主题气质原创设计,普通/CRT 两模式同表
        make(name: "Deep Blue", bg: "#000000", fg: "#7fb4ff",
             ambient: 0, bloom: 0.6, brightness: 0.5, burnIn: 0.3, chroma: 1, contrast: 0.8,
             flickering: 0.1, glowing: 0.2, hsync: 0.1, jitter: 0.08, raster: 0, rgbShift: 0,
             saturation: 0.2, curvature: 0.4, noise: 0.1, opacity: 1, margin: 0.3, frameSize: 0.1,
             font: "ProFontWindows",
             ansi: ["#0a0f1e", "#ff6b6b", "#4dd0a5", "#ffd166",
                    "#5c9dff", "#b48cff", "#4dc8e8", "#c8d6e8",
                    "#3a4a66", "#ff8f8f", "#7de8c4", "#ffe08a",
                    "#8ab8ff", "#cbaaff", "#7fdcf2", "#eaf2ff"]),
        make(name: "Neon Cyan", bg: "#001018", fg: "#52f7ff",
             ambient: 0.1, bloom: 0.6, brightness: 0.6, burnIn: 0.1, chroma: 1, contrast: 0.9,
             flickering: 0.1, glowing: 0.2, hsync: 0, jitter: 0.08, raster: 4, rgbShift: 0,
             saturation: 0.6, curvature: 0, noise: 0.1, opacity: 0.8, margin: 0.1, frameSize: 0,
             font: "Hermit",
             ansi: ["#0a2530", "#ff5d7a", "#3cf5a8", "#ffe14d",
                    "#3fa9ff", "#d96bff", "#52f7ff", "#b8e6f0",
                    "#2a5a6a", "#ff85a0", "#6fffc4", "#fff08a",
                    "#6fc0ff", "#e698ff", "#8afaff", "#eafcff"]),
        make(name: "Ghost Terminal", bg: "#0b1014", fg: "#a6b3c0",
             ambient: 0.3, bloom: 0.3, brightness: 0.6, burnIn: 0.2, chroma: 0, contrast: 0.5,
             flickering: 0, glowing: 0.1, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0.1, opacity: 0.7, margin: 0.1, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#1a222a", "#c48a8a", "#8fb08f", "#c4b08a",
                    "#8aa3c4", "#ab93b8", "#8ab5b8", "#a6b3c0",
                    "#4a5866", "#d8a0a0", "#a8c8a8", "#d8c8a0",
                    "#a0bce0", "#c4aad4", "#a0d0d4", "#d5dde5"]),
        make(name: "Plasma", bg: "#070014", fg: "#ff9bd6",
             ambient: 0.1, bloom: 0.7, brightness: 0.6, burnIn: 0.1, chroma: 1, contrast: 0.8,
             flickering: 0.1, glowing: 0.2, hsync: 0, jitter: 0.08, raster: 4, rgbShift: 0.1,
             saturation: 0.8, curvature: 0, noise: 0.1, opacity: 1, margin: 0.1, frameSize: 0,
             font: "Hermit",
             ansi: ["#1f1030", "#ff4f9e", "#4fffb8", "#ffcf5e",
                    "#7a6bff", "#ff6bff", "#5ee8ff", "#e8c8e8",
                    "#4a3070", "#ff85bd", "#85ffd0", "#ffe08a",
                    "#a191ff", "#ff9bff", "#93f2ff", "#ffeaff"]),
        make(name: "Boring", bg: "#000000", fg: "#ffffff",
             ambient: 0.1, bloom: 0.5, brightness: 0.5, burnIn: 0.05, chroma: 1, contrast: 0.8,
             flickering: 0, glowing: 0.1, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0, frameSize: 0,
             font: "Menlo",
             ansi: ["#000000", "#cd3131", "#0dbc79", "#e5e510",
                    "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
                    "#666666", "#f14c4c", "#23d18b", "#f5f543",
                    "#3b8eea", "#d670d6", "#29b8db", "#ffffff"]),
        make(name: "E-Ink", bg: "#f2f2ec", fg: "#101010",
             ambient: 0.6, bloom: 0, brightness: 1.0, burnIn: 0.6, chroma: 0, contrast: 0.5,
             flickering: 0, glowing: 0, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.1, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#101010", "#a03030", "#3a6e3a", "#8a6d1f",
                    "#2f5d8a", "#7a4a7a", "#2f7a7a", "#78786f",
                    "#4a4a45", "#c04545", "#4f8a4f", "#a5852f",
                    "#4578a5", "#955f95", "#459595", "#9a9a90"]),
        make(name: "Matrix", bg: "#000000", fg: "#00ff41",
             ambient: 0.15, bloom: 0.55, brightness: 0.5, burnIn: 0.35, chroma: 0, contrast: 1.0,
             flickering: 0.1, glowing: 0.3, hsync: 0.05, jitter: 0.08, raster: 0, rgbShift: 0,
             saturation: 0, curvature: 0.2, noise: 0.05, opacity: 1, margin: 0.2, frameSize: 0.1,
             font: "Terminus (TTF)",
             ansi: ["#002200", "#00c236", "#00ff41", "#7dff6b",
                    "#00a82e", "#52ff8a", "#2effb2", "#b8ffc4",
                    "#1a5c2a", "#2eff5c", "#6bff8a", "#a8ff7d",
                    "#2ec250", "#8affb2", "#6bffd0", "#eafff0"]),
        // 程序员名配色(全部带官方 ANSI 16 色表;色准约定见文件头)
        make(name: "Solarized Dark", bg: "#002b36", fg: "#839496",
             ambient: 0.1, bloom: 0.15, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#073642", "#dc322f", "#859900", "#b58900",
                    "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                    "#002b36", "#cb4b16", "#586e75", "#657b83",
                    "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        make(name: "Solarized Light", bg: "#fdf6e3", fg: "#657b83",
             ambient: 0.5, bloom: 0.05, brightness: 0.5, burnIn: 0.05, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#073642", "#dc322f", "#859900", "#b58900",
                    "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                    "#002b36", "#cb4b16", "#586e75", "#657b83",
                    "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        make(name: "Dracula", bg: "#282a36", fg: "#f8f8f2",
             ambient: 0.1, bloom: 0.25, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.1, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Menlo",
             ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                    "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                    "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        make(name: "Nord", bg: "#2e3440", fg: "#d8dee9",
             ambient: 0.1, bloom: 0.15, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Menlo",
             ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                    "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                    "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                    "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        make(name: "Gruvbox", bg: "#282828", fg: "#ebdbb2",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Fixedsys Excelsior 3.01-L2",
             ansi: ["#282828", "#cc241d", "#98971a", "#d79921",
                    "#458588", "#b16286", "#689d6a", "#a89984",
                    "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                    "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        make(name: "Tokyo Night", bg: "#1a1b26", fg: "#a9b1d6",
             ambient: 0.1, bloom: 0.3, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.15, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Hermit",
             ansi: ["#15161e", "#f7768e", "#9ece6a", "#e0af68",
                    "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                    "#414868", "#f7768e", "#9ece6a", "#e0af68",
                    "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),
        make(name: "Ubuntu", bg: "#300a24", fg: "#eeeeec",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Hermit",
             ansi: ["#2e3436", "#cc0000", "#4e9a06", "#c4a000",
                    "#3465a4", "#75507b", "#06989a", "#d3d7cf",
                    "#555753", "#ef2929", "#8ae234", "#fce94f",
                    "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]),
        // v1.2 大更新新增八套(近年人气配色,官方 ANSI 表)
        make(name: "Catppuccin Mocha", bg: "#1e1e2e", fg: "#cdd6f4",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Hermit",
             ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
                    "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                    "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
                    "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]),
        make(name: "One Dark", bg: "#282c34", fg: "#abb2bf",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Menlo",
             ansi: ["#282c34", "#e06c75", "#98c379", "#e5c07b",
                    "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                    "#5c6370", "#e06c75", "#98c379", "#e5c07b",
                    "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
        make(name: "Monokai", bg: "#272822", fg: "#f8f8f2",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#272822", "#f92672", "#a6e22e", "#f4bf75",
                    "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                    "#75715e", "#f92672", "#a6e22e", "#f4bf75",
                    "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"]),
        make(name: "GitHub Dark", bg: "#0d1117", fg: "#c9d1d9",
             ambient: 0.1, bloom: 0.15, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Menlo",
             ansi: ["#484f58", "#ff7b72", "#3fb950", "#d29922",
                    "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                    "#6e7681", "#ffa198", "#56d364", "#e3b341",
                    "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc"]),
        make(name: "Rosé Pine", bg: "#191724", fg: "#e0def4",
             ambient: 0.1, bloom: 0.25, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.1, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Hermit",
             ansi: ["#26233a", "#eb6f92", "#31748f", "#f6c177",
                    "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
                    "#6e6a86", "#eb6f92", "#31748f", "#f6c177",
                    "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"]),
        make(name: "Everforest", bg: "#2d353b", fg: "#d3c6aa",
             ambient: 0.1, bloom: 0.15, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Inconsolata",
             ansi: ["#475258", "#e67e80", "#a7c080", "#dbbc7f",
                    "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
                    "#475258", "#e67e80", "#a7c080", "#dbbc7f",
                    "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa"]),
        make(name: "Kanagawa", bg: "#1f1f28", fg: "#dcd7ba",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Hermit",
             ansi: ["#090618", "#c34043", "#76946a", "#c0a36e",
                    "#7e9cd8", "#957fb8", "#6a9589", "#c8c093",
                    "#727169", "#e82424", "#98bb6c", "#e6c384",
                    "#7fb4ca", "#938aa9", "#7aa89f", "#dcd7ba"]),
        make(name: "Ayu Dark", bg: "#0a0e14", fg: "#b3b1ad",
             ambient: 0.1, bloom: 0.2, brightness: 0.5, burnIn: 0.1, chroma: 1, contrast: 1.0,
             flickering: 0, glowing: 0.05, hsync: 0, jitter: 0, raster: 4, rgbShift: 0,
             saturation: 0, curvature: 0, noise: 0, opacity: 1, margin: 0.15, frameSize: 0,
             font: "Menlo",
             ansi: ["#01060e", "#ea6c73", "#91b362", "#f9af4f",
                    "#53bdfa", "#fae994", "#90e1c6", "#c7c7c7",
                    "#686868", "#f07178", "#c2d94c", "#ffb454",
                    "#59c2ff", "#ffee99", "#95e6cb", "#ffffff"]),
    ]

    public static let all: [CRTConfig] = classicCRT + classicSchemes

    // ── 预设简介(设置页展示;纯 UI 数据,不进 JSON)────────────────────────
    private static let blurbs: [String: String] = [
        // 组① 经典 CRT
        "Default Amber": "琥珀磷光(P3)单色屏,80 年代文字终端最常见的暖色,据说比绿屏更护眼——当年的\"深色模式之争\"。",
        "Monochrome Green": "绿磷光(P1)单色屏,大众印象里\"终端\"的原型。黑底绿字加上轻微闪烁与噪点,是机房与黑客电影的共同记忆。",
        "Commodore 64": "1982 年,史上最畅销的家用电脑(约 1700 万台)。VIC-II 显示芯片标志性的蓝底淡紫字,配原机字库字体,开机画面 READY. 是一代人的起点。",
        "Commodore PET": "1977 年\"三位一体\"(与 Apple ][、TRS-80 同年)之一,金属一体机+内置绿屏。原机字库+宽字符(fontWidth 1.25)还原。",
        "Apple ][": "1977 年个人电脑革命的起点,乔布斯车库传奇的主角。绿磷光+原机点阵字体。",
        "Atari 400": "1979 年 Atari 8-bit 家族入门机,薄膜键盘+电视输出。蓝底浅蓝的柔和感来自家用电视的低通滤波,配原机字库。",
        "IBM VGA": "1987 年 IBM PS/2 带来的 VGA 文本模式:80×25、9×16 点阵、灰白字。DOS 时代装机自带的\"素颜\",配原版 VGA 字模。",
        "IBM 3278": "1972 年起服役的 IBM 3270 系大型机终端。无弧度无噪点——机房级硬件的冷静绿,和家用机的花哨是两个世界。",
        "IBM 5151": "1981 年 IBM PC 原配单色显示器,P39 长余辉绿磷光——字符移动会拖出绿色残影,burn-in 调高正是还原这条尾巴。配 IBM PC 原版字模。",
        "DEC VT100": "1978 年 DEC 出品,史上影响力最大的终端——今天所有终端软件(包括本 app)都在模拟它的转义序列。P4 白磷光,航母级机壳。",
        "DEC VT220": "1983 年 VT100 继任者:屏更平、字更锐、闪烁更少。琥珀磷光是当年办公室的\"护眼款\"选配。",
        "Macintosh 128K": "1984 年初代 Mac 的 9 英寸屏:黑字白底模拟纸张,和当年清一色黑底终端唱反调。配 Monaco——初代 Mac 的原装等宽字体。",
        "Osborne 1": "1981 年史上第一台\"便携\"电脑:11 公斤手提箱,5 英寸小绿屏挤在两个软驱中间。超高弧度+小点阵字体还原贴脸看小屏的感觉。",
        "Amstrad CPC 464": "1984 年欧洲国民学习机,标配 GT65 绿屏——比接电视清楚,比彩显便宜,课桌上的绿色方块字。",
        "ZX Spectrum": "1982 年英国 8-bit 国民机,靠射频线接家用电视——色散与雪花是那根 RF 线的\"味道\"(v1.2 打磨:保留味道、收敛晃动)。浅底黑字还原 BASIC 屏。",
        "MS-DOS 蓝": "DOS 时代的\"工作蓝\":QBasic、EDIT、Norton Commander 的经典蓝底白字,一代人的编程启蒙背景色。配原版 VGA 字模。",
        "Tektronix 4014": "1974 年存储管图形终端:图形画上去就\"存\"在荧光屏上、不需刷新。burn-in 拉到最满,致敬这块不会忘记的屏。",
        "TRS-80 Model III": "1980 年 RadioShack 百万销量神机(Model I 改进型),自带微微偏蓝的白磷光屏,平价电脑的第一缕冷光。",
        "Amiga 500": "1987 年多媒体霸主 Amiga 家族的国民机型,Workbench 系统标志性的蓝底白字橙点缀。轻微色散还原 RGB 彩显的观感。",
        "BBC Micro": "1981 年英国 BBC 电脑扫盲计划的官方机器,一代英国程序员的启蒙。电视输出的白字黑底 + Mode 7 图文电视的味道。",
        "Sharp MZ-80K": "1978 年日本\"御三家\"之一(与 NEC、日立并称),一体机内置 10 英寸绿屏。日系早期个人电脑的方正绿字。",
        // 组② 经典配色
        "Deep Blue": "冷调蓝白荧光,保留 ANSI 彩色(chroma 全开)。不对应具体设备的冷色氛围创作。",
        "Neon Cyan": "现代霓虹风创作:高辉光青色荧光+半透明窗口,赛博都市夜景的配色。",
        "Ghost Terminal": "低对比灰+高透明度,\"幽灵\"一样安静地叠在桌面上——适合当常驻的监控窗。",
        "Plasma": "等离子粉紫+高辉光+色散,合成器浪潮(Synthwave)审美的终端演绎。",
        "Boring": "名字即注释:全部特效关到最低的纯白字+系统字体。对照组,也是排查\"这是特效问题还是内容问题\"的基准。",
        "E-Ink": "电子墨水风:米白纸底+深灰字,高余辉模拟墨水屏的残影。类纸阅读感,白天最舒服的一档。",
        "Matrix": "《黑客帝国》数字雨绿(#00ff41)。配轻扫描线与余辉,ANSI 16 色也是全绿单色阶(层次靠亮度,连报错都是绿的)——Wake up, Neo.",
        "Solarized Dark": "2011 年 Ethan Schoonover 用色彩学精密设计的低对比配色,十几年长盛不衰的程序员护眼圣经。暗色版,带官方 ANSI 表。",
        "Solarized Light": "Solarized 的浅色版:米黄纸底,长时间白天工作的经典选择。带官方 ANSI 表。",
        "Dracula": "2013 年诞生的暗色顶流,吸血鬼紫底+柔和高亮,官网口号\"Dark theme for everyone\"。带官方 ANSI 表。",
        "Nord": "北极风配色:蓝灰基调冷静克制,源自\"北极、冰雪、极光\"的意象,近年极简派最爱。带官方 ANSI 表。",
        "Gruvbox": "复古暖色系:低饱和奶油黄配深棕底,故意做旧的\"复古显示器\"质感——配位图字体加倍做旧,Vim 圈经典。带官方 ANSI 表。",
        "Tokyo Night": "东京夜景配色:深蓝夜空底+霓虹柔光字,VS Code 上的现代人气王。带官方 ANSI 表。",
        "Ubuntu": "2004 年起 Linux 桌面的第一印象:紫红 aubergine(茄皮紫)终端底色,开源世界的官方色。带官方 ANSI 表。",
        "Catppuccin Mocha": "2021 年爆红的\"猫布奇诺\"奶咖配色,柔和低饱和的粉彩系,GitHub 星数最高的主题项目之一。Mocha 是四口味中最深的一档。",
        "One Dark": "Atom 编辑器的遗产:GitHub 出品的经典暗色,红绿黄蓝紫五色平衡,被移植到几乎所有编辑器与终端。",
        "Monokai": "2006 年 Wimer Hazenberg 的传奇配色,Sublime Text 默认主题让它家喻户晓——荧光粉+青柠绿的高对比,写代码像打霓虹灯。",
        "GitHub Dark": "GitHub 官方暗色模式同款:网页上看代码什么样,终端里就什么样。冷静克制的工程师灰蓝。",
        "Rosé Pine": "玫瑰松林:低饱和玫瑰粉+松绿+暮紫的\"晚霞森林\"意象,近年小众精品,适合夜晚安静写代码。",
        "Everforest": "常青森林:绿色基调的护眼配色,低蓝光暖色温,像在森林里写代码。Vim 圈 Gruvbox 之后的新宠。",
        "Kanagawa": "灵感来自葛饰北斋《神奈川冲浪里》:墨蓝底色配浮世绘的靛蓝与土黄,日式沉静。",
        "Ayu Dark": "Ayu 三兄弟中的暗色版:极简高对比,橙色点缀像夜里的一盏灯,亚洲开发者圈的人气选择。",
    ]
}
