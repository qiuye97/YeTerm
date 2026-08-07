// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 设置页的"大脑":响应式数据模型
//
// 这个文件:设置窗所有滑杆/开关背后的**单一数据源**。核心是响应式编程:
//   ▸ `@Published var brightness` —— 属性一变就自动发广播;
//   ▸ SwiftUI 的滑杆用 `$model.brightness` 双向绑定它(拖滑杆=改属性=界面刷新);
//   ▸ init 里订阅了 objectWillChange:任何字段变化 → 防抖 50ms →
//     applyAndSave():广播到所有终端窗口实时预览 + 写盘持久化。
//   类比前端:一个 Vue 的响应式 store(Pinia),watch(deep) + debounce 落库。
//   防抖(debounce)你肯定熟:拖滑杆每秒变几十次,只在停顿 50ms 后处理一次。
//
// 下半部分是"配置库":系统预设(不可删,可改可还原)/ 用户配置(增删复制),
//   每份配置一个 JSON 文件,目录结构见注释 —— 类比一张按文件存的配置表。
//
// 语法看点:
//   `final class ... : ObservableObject` —— SwiftUI 的可观察对象协议;
//     class 而非 struct,因为要被多处共享同一份(引用语义)。
//   `Set<AnyCancellable>` —— Combine 订阅的"生命线",释放即退订
//     (类比 RxJava 的 CompositeDisposable)。
//   `@discardableResult` —— 允许调用方忽略返回值不警告。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Combine

/// 设置页数据模型(M3 提前):双向绑定 CRTConfig ←→ UI,变更实时应用 + 写盘。
/// 持久化位置:~/Library/Application Support/YeTerm/config.json(crterm 兼容格式)。
final class SettingsModel: ObservableObject {
    // 预设(v1.2 预设大更新:「我的 CRT 配置」随私人收藏组删除,锚点改 crterm 正统默认)
    @Published var presetName: String = "Default Amber"

    // 颜色与字体
    @Published var fontColorHex: String = "#00d56d"
    @Published var backgroundColorHex: String = "#000000"
    // CRT 模式 ANSI 16 色(nil = crterm 专属调色板;经典配色预设带官方表)
    @Published var ansiColorsHex: [String]?
    // CRT 模式文字颜色(2026-08-03:默认前景覆盖;nil = 纯白 = 历史行为)
    @Published var crtTextColorHex: String?
    // 提示符主题(v1.3;nil=不干预,"retro:*"=内置复古,"omz:*"=oh-my-zsh 主题)
    @Published var promptTheme: String?
    @Published var fontName: String = "Ark Pixel 12px Mono zh_cn"
    @Published var fontSize: Double = 14
    @Published var fontWidth: Double = 1   // crterm 语义 0.5~1.5,横向缩放字形与列宽

    // 特效(0~1,语义与 cool-retro-term 一致)
    @Published var brightness: Double = 0.5
    @Published var contrast: Double = 0.85
    @Published var saturation: Double = 0.25
    @Published var chroma: Double = 1.0
    @Published var curvature: Double = 0.5
    @Published var rasterization: Int = 0
    @Published var staticNoise: Double = 0.1
    @Published var bloom: Double = 0.5
    @Published var burnIn: Double = 0.5
    @Published var flickering: Double = 0.2
    @Published var horizontalSync: Double = 0.16
    @Published var jitter: Double = 0.1
    @Published var glowingLine: Double = 0.22
    @Published var rgbShift: Double = 0
    @Published var ambientLight: Double = 0.3
    @Published var frameEnabled: Bool = true   // 机壳边框(暗角/边缘阴影/反射带)总开关
    @Published var crtTabBarStyle: Int = 0     // 盒绘标签条样式(0 直角框/1 圆角框/2 极简块/3 胶囊块/4 下划线/5 翻页卡)
    @Published var margin: Double = 0.5
    @Published var windowOpacity: Double = 1
    @Published var dividerStyle: Int = 0   // 分屏荧光线:0 实线/1 虚线段/2 点线
    // v1.4「文字发光」三项(缺省全 = 现有行为,详见 CRTConfig 同名字段注释)
    @Published var bloomStyle: Int = 0     // 辉光风格:0 高斯(能量守恒)/1 光晕 halation(加权 max)
    @Published var emissiveModel: Int = 0  // 发光模型:0 颜料(convertWithChroma)/1 自发光
    @Published var bloomShape: Int = 0     // 光晕形状:0 单层/1 紧核+长尾
    // 白热化(v1.4 用户提的拆分:「文字自身发光」)—— 与 bloom(照亮周围)正交
    @Published var overdrive: Double = 0        // 强度;0 = 关
    @Published var overdriveKnee: Double = 0.20 // 起点(束驱动量阈值;0.20 = 照片定标值)
    @Published var bitRate: Int = 0        // 波特率限速(bps);0 = 不限速
    @Published var powerOnEffect: Bool = true   // 开机动画(v1.1):新窗口播显像管开机特效
    @Published var powerOnSpeed: Int = 1        // 开机动画速度档(v1.2 补丁:0 慢/1 标准/2 快/3 极速)
    @Published var refreshRate: Int = 60        // 刷新率挡(v1.1):30/60;低电量自动压 30
    @Published var animateInBackground: Bool = true   // 后台动画(v1.1.2):失活时特效继续
    @Published var restoreSession: Bool = true   // 会话恢复(v1.2 #2):启动还原窗口/分屏/目录
    // 通知 + Visual Bell(v1.2 #5,纯本机)
    @Published var visualBell: Bool = true
    @Published var notifyOnBell: Bool = true
    @Published var notifyLongCommand: Bool = true
    @Published var notifyThresholdSeconds: Double = 10
    @Published var pasteProtection: Bool = true   // 粘贴保护(v1.2 #6)
    @Published var bootSelfTest: Bool = true   // 开机自检(v1.2 #10):首窗 BIOS 滚屏
    @Published var channelSwitchFX: Bool = true   // 换台效果(v1.2 #12):切主题闪断
    @Published var crtEffectsEnabled: Bool = true   // CRT 总开关:关=普通终端模式
    // 普通终端模式独立颜色(v1.2:仿 Terminal.app)
    @Published var plainTextColorHex: String = "#ffffff"
    @Published var plainBackgroundColorHex: String = "#000000"
    @Published var plainAnsiHex: [String] = AnsiColor.terminalAppAnsiHex
    // 背景图片(v1.2 #16;v1.5.1 起 CRT 模式也生效,两种模式共用这一份设置)。
    // 空 = 未设置;mode 0-4 = 无/毛玻璃/像素风/暗化/黑白
    @Published var plainBackgroundImagePath: String = ""
    @Published var plainBackgroundImageMode: Int = 0
    @Published var plainBackgroundBlur: Double = 0.5   // 毛玻璃模糊强度(仅 mode=1)
    @Published var plainBackgroundPixelPalette: Int = 0   // 像素风调色板(仅 mode=2)
    @Published var crtBackgroundImageChroma: Bool = false   // 背景图荧光染色(仅 CRT 模式)
    // 小件三连(v1.2 #8)
    @Published var inheritCwd: Bool = true
    @Published var scrollbackLines: Int = 10000
    @Published var optionAsMeta: Bool = true

    // 光标
    @Published var cursorBlinks: Bool = true
    @Published var cursorStyle: Int = 0     // 0 块/1 下划线/2 竖线

    /// 应用回调(AppDelegate 接线,广播到全部窗口 —— 全局单一 profile)
    var applyHandler: ((CRTConfig, CGFloat, Float) -> Void)?

    /// 特效开关的「上次非零值」记忆:关闭存值、重开恢复(设置页 Toggle 用)
    var effectStash: [String: Double] = [:]

    /// 探针/测试关掉写盘(否则离屏实例化会覆盖用户真实 config.json)
    var persistenceEnabled = true

    private var cancellables: Set<AnyCancellable> = []

    init(from cfg: CRTConfig?) {
        if let c = cfg { load(config: c) }
        refreshUserProfiles()
        // 任意字段变更 → 合并应用 + 写盘(50ms 防抖)
        objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAndSave() }
            .store(in: &cancellables)
    }

    func load(config c: CRTConfig) {
        presetName = c.name ?? presetName
        fontColorHex = c.fontColor ?? fontColorHex
        backgroundColorHex = c.backgroundColor ?? backgroundColorHex
        // 直赋不用 ??(切预设必须正确重置:经典 CRT 预设 nil = 回 crterm 调色板,
        // 否则上一套经典配色的 ANSI 表会残留串台)
        ansiColorsHex = c.ansiColors
        // 同为身份字段直赋:切到没配文字颜色的预设就该回纯白,不残留上一套的颜色
        crtTextColorHex = c.crtTextColor
        // 同为身份字段直赋:经典配色 nil = 不干预提示符,不残留上一主题的复古提示符
        promptTheme = c.promptTheme
        if let f = c.resolvedFontName { fontName = f }
        fontWidth = c.fontWidth ?? fontWidth
        fontSize = c.fontSize ?? fontSize
        brightness = c.brightness ?? brightness
        contrast = c.contrast ?? contrast
        saturation = c.saturationColor ?? saturation
        chroma = c.chromaColor ?? chroma
        curvature = c.screenCurvature ?? curvature
        rasterization = c.rasterization ?? rasterization
        staticNoise = c.staticNoise ?? staticNoise
        bloom = c.bloom ?? bloom
        burnIn = c.burnIn ?? burnIn
        flickering = c.flickering ?? flickering
        horizontalSync = c.horizontalSync ?? horizontalSync
        jitter = c.jitter ?? jitter
        glowingLine = c.glowingLine ?? glowingLine
        rgbShift = c.rgbShift ?? c.rbgShift ?? rgbShift
        ambientLight = c.ambientLight ?? ambientLight
        // 机壳开关是**预设携带字段,nil 回落缺省开、不回落当前值**(2026-08-06 bug 修复):
        // 经典配色预设出厂显式带 frameEnabled=false(v1.4 统一"设备特征全关"),
        // 经典 CRT 预设则不带(nil=缺省开)。若这里写 `?? frameEnabled`,
        // 从经典配色切回经典 CRT 时上一套的 false 会残留,机壳被莫名关掉。
        // (同 bitRate/ansiColorsHex 的"跟着预设走"处理,理由见下面 bitRate 那条注释)
        frameEnabled = c.frameEnabled ?? true
        // 标签条样式同为预设携带字段(bitRate 同款语义):切到没配的预设回缺省直角框
        crtTabBarStyle = c.crtTabBarStyle ?? 0
        margin = c.margin ?? margin
        windowOpacity = c.windowOpacity ?? windowOpacity
        dividerStyle = c.dividerStyle ?? dividerStyle
        bloomStyle = c.bloomStyle ?? bloomStyle
        emissiveModel = c.emissiveModel ?? emissiveModel
        bloomShape = c.bloomShape ?? bloomShape
        overdrive = c.overdrive ?? overdrive
        overdriveKnee = c.overdriveKnee ?? overdriveKnee
        // 波特率是**身份字段,直赋不用 ??**(2026-07-30 用户裁决「速率要跟着预设走」):
        // 每个预设独立配一个速率,切到没配速率的预设就该回到不限速 ——
        // 用 ?? 兜底的话上一个预设的速率会残留,换主题后还在慢慢吐字,像卡了。
        // (同 ansiColorsHex / promptTheme 的处理,理由见上面那两条注释)
        bitRate = c.bitRate ?? 0
        powerOnEffect = c.powerOnEffect ?? powerOnEffect
        powerOnSpeed = c.powerOnSpeed ?? powerOnSpeed
        refreshRate = c.refreshRate ?? refreshRate
        animateInBackground = c.animateInBackground ?? animateInBackground
        restoreSession = c.restoreSession ?? restoreSession
        visualBell = c.visualBell ?? visualBell
        notifyOnBell = c.notifyOnBell ?? notifyOnBell
        notifyLongCommand = c.notifyLongCommand ?? notifyLongCommand
        notifyThresholdSeconds = c.notifyThresholdSeconds ?? notifyThresholdSeconds
        pasteProtection = c.pasteProtection ?? pasteProtection
        bootSelfTest = c.bootSelfTest ?? bootSelfTest
        channelSwitchFX = c.channelSwitchFX ?? channelSwitchFX
        crtEffectsEnabled = c.crtEffectsEnabled ?? crtEffectsEnabled
        plainTextColorHex = c.plainTextColor ?? plainTextColorHex
        plainBackgroundColorHex = c.plainBackgroundColor ?? plainBackgroundColorHex
        if let pa = c.plainAnsiColors, pa.count == 16 { plainAnsiHex = pa }
        // 背景图五件套是**预设携带字段,nil 回落出厂缺省、不回落当前值**
        // (2026-08-07 用户需求「壁纸每个预设独立设置」):此前用 ?? 兜底当前值,
        // 切预设时上一套的壁纸会一路残留 —— 表现成"所有预设共用一张图"。
        // 改直赋后:没配壁纸的预设回到无图,各预设的壁纸记在各自的
        // override/profile 里(同 bitRate/frameEnabled 的"跟着预设走"处理)
        plainBackgroundImagePath = c.plainBackgroundImage ?? ""
        plainBackgroundImageMode = c.plainBackgroundImageMode ?? 0
        plainBackgroundBlur = c.plainBackgroundBlur ?? 0.5
        plainBackgroundPixelPalette = c.plainBackgroundPixelPalette ?? 0
        crtBackgroundImageChroma = c.crtBackgroundImageChroma ?? false
        inheritCwd = c.inheritCwd ?? inheritCwd
        scrollbackLines = c.scrollbackLines ?? scrollbackLines
        optionAsMeta = c.optionAsMeta ?? optionAsMeta
        cursorBlinks = c.blinkingCursor ?? cursorBlinks
    }

    // MARK: - 配置库(系统预设 + 用户自定义)
    //
    // 目录布局(~/Library/Application Support/YeTerm/):
    //   config.json           当前生效配置(启动载入,兼容旧机制)
    //   profiles/<名称>.json   用户自定义配置
    //   overrides/<名称>.json  系统预设的用户修改(「还原默认」= 删此文件)
    // 系统预设不可删除;名称全局唯一(系统+用户)。

    @Published var userProfileNames: [String] = []

    private var profilesDir: String { NSHomeDirectory() + "/Library/Application Support/YeTerm/profiles" }
    private var overridesDir: String { NSHomeDirectory() + "/Library/Application Support/YeTerm/overrides" }

    func isBuiltin(_ name: String) -> Bool { Presets.names.contains(name) }

    /// 名称可用:非空、不与系统预设/已有用户配置重复
    func nameAvailable(_ raw: String) -> Bool {
        let n = raw.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !Presets.names.contains(n) && !userProfileNames.contains(n)
    }

    private func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-") + ".json"
    }
    private func profilePath(_ name: String) -> String { profilesDir + "/" + fileName(name) }
    private func overridePath(_ name: String) -> String { overridesDir + "/" + fileName(name) }

    private func loadIfExists(_ path: String) -> CRTConfig? {
        FileManager.default.fileExists(atPath: path) ? CRTConfig.load(path: path) : nil
    }

    func refreshUserProfiles() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: profilesDir)) ?? []
        userProfileNames = files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter { !Presets.names.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// 某配置的存储态:用户配置读其文件;系统预设 = **出厂值为底 + override
    /// 只搬观感参数白名单**。
    /// v1.2 补丁勘差(用户实测"经典配色关 CRT 全都一样"):applyAndSave 把模型
    /// 全量快照写成 override,点过预设就有旧快照 —— 后续版本给内置预设新增的
    /// 身份数据(经典配色的 plain 三件套/官方 ANSI 表)和用户全局偏好(通知/
    /// 背景图…)全被旧快照压住。改为白名单后:身份颜色与全局偏好
    /// 永远跟出厂(出厂 nil 的字段经 load 的 ?? 兜底自然保留用户当前偏好),
    /// (机壳开关曾列在全局偏好里,2026-08-06 起改为**预设携带**:v1.4 经典配色
    /// 出厂显式带 false,全局语义已被打破 —— load 里直赋 ?? true,详见那处注释)
    /// 未来新增字段默认免疫旧档。想自定义 ANSI/配色身份 →「复制当前」存自己的配置。
    func storedConfig(named name: String) -> CRTConfig? {
        if isBuiltin(name) {
            guard var c = Presets.byName(name) else { return nil }
            if let o = loadIfExists(overridePath(name)) {
                // 观感参数白名单(用户对系统预设的微调,合法保留)
                c.backgroundColor = o.backgroundColor ?? c.backgroundColor
                c.fontColor = o.fontColor ?? c.fontColor
                c.ambientLight = o.ambientLight ?? c.ambientLight
                c.bloom = o.bloom ?? c.bloom
                c.brightness = o.brightness ?? c.brightness
                c.burnIn = o.burnIn ?? c.burnIn
                c.chromaColor = o.chromaColor ?? c.chromaColor
                c.contrast = o.contrast ?? c.contrast
                c.flickering = o.flickering ?? c.flickering
                c.glowingLine = o.glowingLine ?? c.glowingLine
                c.horizontalSync = o.horizontalSync ?? c.horizontalSync
                c.jitter = o.jitter ?? c.jitter
                c.rasterization = o.rasterization ?? c.rasterization
                // v1.4:辉光风格/发光模型是纯观感旋钮,与 bloom/rasterization 同类,入白名单。
                c.bloomStyle = o.bloomStyle ?? c.bloomStyle
                c.emissiveModel = o.emissiveModel ?? c.emissiveModel
                c.bloomShape = o.bloomShape ?? c.bloomShape
                c.overdrive = o.overdrive ?? c.overdrive
                c.overdriveKnee = o.overdriveKnee ?? c.overdriveKnee
                // 波特率也入白名单(2026-07-30 用户裁决:速率跟着预设走、每个预设独立配)。
                // 内置预设出厂一律 nil = 不限速;用户给某个预设配了速率就记在它的
                // override 里,换主题各用各的、互不干扰
                c.bitRate = o.bitRate ?? c.bitRate
                c.rgbShift = o.rgbShift ?? o.rbgShift ?? c.rgbShift
                c.saturationColor = o.saturationColor ?? c.saturationColor
                c.screenCurvature = o.screenCurvature ?? c.screenCurvature
                c.staticNoise = o.staticNoise ?? c.staticNoise
                c.windowOpacity = o.windowOpacity ?? c.windowOpacity
                c.margin = o.margin ?? c.margin
                c.frameMargin = o.frameMargin ?? c.frameMargin
                c.frameColor = o.frameColor ?? c.frameColor
                c.screenRadius = o.screenRadius ?? c.screenRadius
                c.frameShininess = o.frameShininess ?? c.frameShininess
                c.fontName = o.fontName ?? c.fontName
                c.fontWidth = o.fontWidth ?? c.fontWidth
                c.crtEffectsEnabled = o.crtEffectsEnabled ?? c.crtEffectsEnabled
                // 提示符主题入白名单(2026-07-29 用户实测:给 VT220 配"极简"切走
                // 再回变回出厂 ASCII)—— v1.3 新字段无旧快照压制风险(旧 override
                // 无此键即 nil 兜底出厂),用户对内置预设的提示符微调应被记住
                c.promptTheme = o.promptTheme ?? c.promptTheme
                // 文字颜色入白名单(2026-08-03:与 fontColor 同类的观感微调,
                // 用户给经典配色预设调的文字颜色应被记住)
                c.crtTextColor = o.crtTextColor ?? c.crtTextColor
                // 背景图五件套入白名单(2026-08-07 用户需求「壁纸每个预设独立」):
                // 出厂恒 nil(内置预设从不带图),用户给某预设配的壁纸记在它的
                // override 里,换预设各用各的。经典 CRT 组照旧不铺(判定在
                // TerminalWindowController.applyCRTMode,按预设名,不受此处影响)
                c.plainBackgroundImage = o.plainBackgroundImage ?? c.plainBackgroundImage
                c.plainBackgroundImageMode = o.plainBackgroundImageMode ?? c.plainBackgroundImageMode
                c.plainBackgroundBlur = o.plainBackgroundBlur ?? c.plainBackgroundBlur
                c.plainBackgroundPixelPalette = o.plainBackgroundPixelPalette ?? c.plainBackgroundPixelPalette
                c.crtBackgroundImageChroma = o.crtBackgroundImageChroma ?? c.crtBackgroundImageChroma
            }
            // 经典 CRT 锁定兜底(旧档可能存过"关"):设备还原主题恒为 CRT 开;
            // 文字颜色恒纯白(2026-08-03,同一条锁定逻辑,防旧 override 残值)
            if Presets.isClassicCRT(name) {
                c.crtEffectsEnabled = true
                c.crtTextColor = nil
            }
            return c
        }
        return loadIfExists(profilePath(name))
    }

    /// 主题切换回调(v1.2 #12 换台效果:只有"切主题"触发,拖滑杆调参不触发)
    var onPresetSwitch: (() -> Void)?

    func loadPreset(_ name: String) {
        guard let cfg = storedConfig(named: name) else { return }
        load(config: cfg)
        presetName = name
        onPresetSwitch?()
    }

    /// 以当前设置为底创建/复制新配置(名称查重;成功即切到新配置)
    @discardableResult
    func createProfile(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard nameAvailable(name) else { return false }
        try? FileManager.default.createDirectory(atPath: profilesDir, withIntermediateDirectories: true)
        var cfg = toConfig()
        cfg.name = name
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cfg),
              (try? data.write(to: URL(fileURLWithPath: profilePath(name)))) != nil else { return false }
        refreshUserProfiles()
        presetName = name
        return true
    }

    /// 删除用户配置(系统预设拒绝);删的是当前配置则回落到「我的 CRT 配置」
    func deleteProfile(named name: String) {
        guard !isBuiltin(name) else { return }
        try? FileManager.default.removeItem(atPath: profilePath(name))
        refreshUserProfiles()
        if presetName == name {
            loadPreset("Default Amber")
        }
    }

    /// 系统预设还原出厂值(删 override + 重载出厂参数)
    func resetBuiltinToDefault() {
        guard isBuiltin(presetName), let base = Presets.byName(presetName) else { return }
        try? FileManager.default.removeItem(atPath: overridePath(presetName))
        load(config: base)
    }

    /// 编辑落盘到所属配置:系统预设写 override,用户配置写回自身文件
    private func persistProfile(_ cfg: CRTConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var named = cfg
        named.name = presetName
        guard let data = try? enc.encode(named) else { return }
        let dir = isBuiltin(presetName) ? overridesDir : profilesDir
        let path = isBuiltin(presetName) ? overridePath(presetName) : profilePath(presetName)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
        if !isBuiltin(presetName), !userProfileNames.contains(presetName) {
            refreshUserProfiles()   // 导入的陌生名字自动成为用户配置
        }
    }

    func toConfig() -> CRTConfig {
        var c = CRTConfig()
        c.name = presetName
        c.version = 2                      // 存盘用 v2 语义(弧度 ×0.4),与 crterm 导出兼容
        c.fontColor = fontColorHex
        c.backgroundColor = backgroundColorHex
        c.ansiColors = ansiColorsHex
        c.crtTextColor = crtTextColorHex
        c.promptTheme = promptTheme
        c.fontName = fontName
        c.brightness = brightness
        c.contrast = contrast
        c.saturationColor = saturation
        c.chromaColor = chroma
        c.screenCurvature = curvature
        c.rasterization = rasterization
        c.staticNoise = staticNoise
        c.bloom = bloom
        c.burnIn = burnIn
        c.flickering = flickering
        c.horizontalSync = horizontalSync
        c.jitter = jitter
        c.glowingLine = glowingLine
        c.rgbShift = rgbShift
        c.ambientLight = ambientLight
        c.frameEnabled = frameEnabled
        c.crtTabBarStyle = crtTabBarStyle
        c.margin = margin
        c.blinkingCursor = cursorBlinks
        c.windowOpacity = windowOpacity
        c.dividerStyle = dividerStyle
        c.bloomStyle = bloomStyle
        c.emissiveModel = emissiveModel
        c.bloomShape = bloomShape
        c.overdrive = overdrive
        c.overdriveKnee = overdriveKnee
        c.bitRate = bitRate
        c.powerOnEffect = powerOnEffect
        c.powerOnSpeed = powerOnSpeed
        c.refreshRate = refreshRate
        c.animateInBackground = animateInBackground
        c.restoreSession = restoreSession
        c.visualBell = visualBell
        c.notifyOnBell = notifyOnBell
        c.notifyLongCommand = notifyLongCommand
        c.notifyThresholdSeconds = notifyThresholdSeconds
        c.pasteProtection = pasteProtection
        c.bootSelfTest = bootSelfTest
        c.channelSwitchFX = channelSwitchFX
        c.crtEffectsEnabled = crtEffectsEnabled
        c.plainTextColor = plainTextColorHex
        c.plainBackgroundColor = plainBackgroundColorHex
        c.plainAnsiColors = plainAnsiHex
        c.plainBackgroundImage = plainBackgroundImagePath
        c.plainBackgroundImageMode = plainBackgroundImageMode
        c.plainBackgroundBlur = plainBackgroundBlur
        c.plainBackgroundPixelPalette = plainBackgroundPixelPalette
        c.crtBackgroundImageChroma = crtBackgroundImageChroma
        c.inheritCwd = inheritCwd
        c.scrollbackLines = scrollbackLines
        c.optionAsMeta = optionAsMeta
        c.fontWidth = fontWidth
        c.fontSize = fontSize
        c.frameMargin = 0.2
        return c
    }

    private func applyAndSave() {
        let cfg = toConfig()
        applyHandler?(cfg, CGFloat(fontSize), Float(cursorStyle))
        guard persistenceEnabled else { return }
        save(cfg)
        persistProfile(cfg)
    }

    private func save(_ cfg: CRTConfig) {
        let dir = NSHomeDirectory() + "/Library/Application Support/YeTerm"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) {
            try? data.write(to: URL(fileURLWithPath: dir + "/config.json"))
        }
    }
}
