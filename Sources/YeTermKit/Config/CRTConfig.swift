// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 配置文件的数据模型(阅读顺序:配置系统从这开始)
//
// 这个文件:一份"主题配置"的完整字段定义 + JSON 读写 + 把配置换算成
//   着色器参数(apply 方法)。和 cool-retro-term 的导出 JSON 双向兼容,
//   所以字段名是它家的(甚至保留了历史拼写错误 rbgShift 以兼容旧档)。
// 类比 Java:一个 DTO/POJO + Jackson 注解的合体 —— Swift 里只要声明
//   `struct CRTConfig: Codable`,编译器就自动合成 JSON 编解码,零注解零反射。
//
// 全字段 Optional(String?/Double?)是刻意设计:老版本 JSON 缺字段照样解析,
//   缺的走默认值 —— "容错解析"让任何年代的配置档都能导入。
//
// apply(to:) 里藏着最重要的移植考据:contrast/saturation 是 CPU 侧"预混色"
//   (从不进着色器)、各种 lint(a,b,t) 线性插值换算 —— 每行注释都标了
//   原版出处,想理解特效参数语义看这里。
//
// 语法看点:
//   `struct ... : Codable` —— 自动 JSON 序列化协议(= Encodable+Decodable)。
//   `??` 空合并运算符 —— "有值用值,没值用默认",类比 Java Optional.orElse。
//   计算属性 `var resolvedFontName: String? { ... }` —— 长得像字段用起来像
//     字段,实际每次现算(类比 getter)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import simd

/// cool-retro-term 配置 JSON 兼容层(profile version 2,即其 v1.2 世代导出格式;
/// 兼容 cool-retro-term 导出的配置档)。
/// 全字段容错解析:现有特效参数立即生效,尚未实现的特效(burnIn/bloom/flickering 等)
/// 先存留,M1b 全链接上后自动生效。
public struct CRTConfig: Codable {
    // 颜色(#RRGGBB)
    public var backgroundColor: String?
    public var fontColor: String?
    // 特效参数(0~1)
    public var flickering: Double?
    public var horizontalSync: Double?
    public var staticNoise: Double?
    public var chromaColor: Double?
    public var saturationColor: Double?
    public var screenCurvature: Double?
    public var glowingLine: Double?
    public var burnIn: Double?
    public var bloom: Double?
    public var rasterization: Int?
    public var jitter: Double?
    public var rbgShift: Double?          // 历史拼写,保持兼容
    public var rgbShift: Double?          // master 拼写
    public var brightness: Double?
    public var contrast: Double?
    public var ambientLight: Double?
    public var windowOpacity: Double?
    // 字体
    public var fontName: String?
    public var fontWidth: Double?
    // 其它
    public var margin: Double?
    public var blinkingCursor: Bool?
    public var frameMargin: Double?
    public var name: String?
    public var version: Int?
    // 机壳细项(YeTerm 扩展字段;crterm 原版机壳参数写死,导入其 JSON 时缺省走 master 默认值)
    public var frameEnabled: Bool?        // 机壳层总开关(v1.2.1 用户追加:关=暗角/边缘阴影/反射带全消;缺省开)
    public var crtTabBarStyle: Int?       // 盒绘标签条样式(2026-08-07 用户需求,跟着预设走):
                                          // 0 直角框(缺省)/1 圆角框/2 极简块/3 胶囊块/4 下划线/5 翻页卡
    public var frameColor: String?        // #RRGGBB,默认 #ffffff
    public var screenRadius: Double?      // 0~1,圆角半径 lint(4,120,·),默认 0.2
    public var frameShininess: Double?    // 0~1,反光强度,默认 0.2
    // 字号(YeTerm 扩展:crterm 的 profile 导出不含字号,但我们的 config.json 需要持久化它)
    public var fontSize: Double?
    // 分屏荧光分割线样式(YeTerm 扩展:0 实线 / 1 虚线段 / 2 点线)
    public var dividerStyle: Int?
    // 开机动画(YeTerm v1.1 扩展:新窗口播放显像管开机特效;缺省 = 开)
    public var powerOnEffect: Bool?
    // 开机动画速度档(v1.2 补丁:0 慢/1 标准/2 快/3 极速;缺省 1)
    public var powerOnSpeed: Int?

    /// 速度档 → 时长系数(开关机动画共用)
    static func powerSpeedFactor(_ level: Int?) -> Double {
        switch level ?? 1 {
        case 0: return 0.6
        case 2: return 1.6
        case 3: return 2.5
        default: return 1.0
        }
    }
    // 刷新率挡(YeTerm v1.1 扩展:30/60;缺省 60。低电量模式下运行时自动压 ≤30)
    public var refreshRate: Int?
    // 后台动画(YeTerm v1.1.2 扩展:app 失活时特效是否继续;缺省开 = 拟真优先,
    // 关 = 失活即停摆最省电。遮挡/最小化无论如何都停)
    public var animateInBackground: Bool?
    // 会话恢复(YeTerm v1.2 #2 扩展:启动时恢复上次的窗口位置/分屏布局/工作目录;缺省开)
    public var restoreSession: Bool?
    // 通知 + Visual Bell(YeTerm v1.2 #5 扩展,纯本机;缺省全开、阈值 10 秒)
    public var visualBell: Bool?              // bell → CRT 荧光闪屏
    public var notifyOnBell: Bool?            // 后台 bell → 通知中心
    public var notifyLongCommand: Bool?       // 长命令后台完成 → 通知中心(需 shell 集成)
    public var notifyThresholdSeconds: Double?
    // 粘贴保护(YeTerm v1.2 #6 扩展:多行粘贴弹确认;缺省开)
    public var pasteProtection: Bool?
    // 开机自检画面(YeTerm v1.2 #10 扩展:首窗 BIOS 风自检滚屏;缺省开)
    public var bootSelfTest: Bool?
    // 换台效果(YeTerm v1.2 #12 扩展:切主题闪断一下;缺省开)
    public var channelSwitchFX: Bool?
    // CRT 特效总开关(YeTerm v1.2 用户追加:关=普通终端观感,渲染仍全程 GPU;
    // ⌘E 快切,持久化;缺省开)
    public var crtEffectsEnabled: Bool?
    // CRT 模式 ANSI 16 色(v1.2 预设大更新,YeTerm 扩展):经典配色预设携带
    // 官方 ANSI 表;nil = crterm 专属调色板(内置经典 CRT 主题一律 nil)
    public var ansiColors: [String]?
    // CRT 模式文字颜色(2026-08-03 用户需求,YeTerm 扩展):终端**默认前景**
    // (无 SGR 颜色指令的普通输出)画进内容纹理用的颜色;nil = 纯白(历史行为,
    // 荧光染色后输出纯磷光色)。与「前景色(荧光)」分工:荧光色是染色滤镜,
    // chroma=1 时乘在**所有**颜色上(调它会把 ANSI 彩色一起偏色);本字段只动
    // 默认输出的字 —— 对齐普通模式「文字颜色」的语义。⚠️ chroma 低时色相进
    // 不了输出(染色公式只取内容亮度),仅亮度生效,设置页有说明文案。
    // 内置「经典 CRT」组恒 nil(考据观感依赖内容亮度=1 → 满驱动纯磷光;
    // 锁定在 storedConfig 与设置页,同「不铺背景图」一条产品逻辑)
    public var crtTextColor: String?
    // 提示符主题(v1.3,YeTerm 扩展;主题身份字段,不入 override 白名单):
    // nil = 不干预(用户自己的 p10k/starship 照常);"retro:ascii|dos|c64|minimal"
    // = 内置复古提示符;"omz:<主题名>" = 切指定 oh-my-zsh 主题。
    // 经 YETERM_PROMPT 环境变量传给新开的 shell,仅 YeTerm 内、仅新会话生效
    public var promptTheme: String?
    // 普通终端模式独立颜色系统(v1.2 用户裁决:仿 Terminal.app,与 CRT 荧光两套)
    public var plainTextColor: String?        // 缺省 #ffffff
    public var plainBackgroundColor: String?  // 缺省 #000000
    public var plainAnsiColors: [String]?     // 16 hex,缺省 Terminal.app 调色板
    // 背景图片(v1.2 #16 用户追加;**v1.5.1 起 CRT 模式也生效**)。
    // 字段名保留 `plain*` 前缀是为了兼容已存在的用户配置档 —— 语义已扩成"两种模式
    // 共用同一张图、同一套预处理特效",只是上屏路径不同:
    //   · 普通模式 → 合成层第一笔铺底(OffscreenRenderer.encodeComposite 的 background);
    //   · CRT 模式 → CRT 着色器的「屏幕底图」(替换染色公式的背景色项,见 CRT.metal)。
    // 例外:内置「经典 CRT」组的 21 套真实设备还原主题不铺图(用户裁决 2026-07-31,
    // 与"这组锁定 CRT 特效不可关"同一条产品逻辑;判定在 TerminalWindowController)。
    public var plainBackgroundImage: String?      // 图片路径;nil/空 = 无背景图
    public var plainBackgroundImageMode: Int?     // 0 无变化/1 毛玻璃/2 像素风/3 暗化/4 黑白胶片
    public var plainBackgroundBlur: Double?       // 毛玻璃模糊强度 0~1(缺省 0.5,仅 mode=1 用)
    public var plainBackgroundPixelPalette: Int?  // 像素风调色板:0 PICO-8/1 DB16/2 GameBoy/3 原色(仅 mode=2 用)
    public var plainBackgroundDarken: Double?     // 暗化程度 0~1(缺省 0.5 = 旧固定观感 ×0.35,仅 mode=3 用)
    public var plainBackgroundAnimFPS: Int?       // 动图/视频背景取帧上限 15/30/60(缺省 30;静图不读)
    /// 背景图的荧光染色(v1.5.1,**仅 CRT 模式读**):nil/false = 保留图片原色,图当
    /// 屏幕底图、磷光文字发光浮在上面(缺省);true = 整张图染成磷光单色 + 吃扫描线,
    /// 像真 CRT 正在显示这张图。普通模式的背景图走合成层,不受此项影响。
    public var crtBackgroundImageChroma: Bool?
    // ---- v1.4「文字发光」三项。**全部缺省 = 现有行为**,
    //      老配置档解析出来 nil 就走原路,观感零变化。 ----
    /// 辉光风格:0 = 归一化高斯(crterm 语义,能量守恒,缺省)/ 1 = 光晕 halation
    /// (加权 max,亮核峰值不衰减)。见 `Bloom.metal` 的 `blur_max_fragment`
    public var bloomStyle: Int?
    /// 发光模型:0 = convertWithChroma(crterm 语义,颜料模型,缺省)/ 1 = 自发光
    /// (背景基底 + 磷光加法层 + 色相保持压缩)。见 `CRT.metal` 的 `emissiveLight`
    public var emissiveModel: Int?
    /// 波特率限速(bps):字符按老串口速率一个个吐出来。nil/0 = 不限速(缺省)。
    /// 见 `ByteRateLimiter`;档位表 `ByteRateLimiter.presetRates`
    public var bitRate: Int?
    /// 白热化强度(v1.4 用户提的架构拆分:「文字自身发光」那一半)。0 = 关(缺省)。
    /// 笔画芯部按自身束驱动量往白推 —— 与 `bloom`(把周围照亮)**正交**,
    /// 从此不必为了要"中心发白"而把辉光开到最大。见 `CRT.metal` 的 `applyOverdrive`
    public var overdrive: Double?
    /// 光晕形状:0 = 单层高斯(缺省)/ 1 = 紧核 + 长尾(双尺度,更接近真 halation 的
    /// 「衰减比指数快、比高斯慢」)。见 `Bloom.metal` 的 `blur_combine_fragment`
    public var bloomShape: Int?
    /// 白热化起点(0~1;束驱动量低于此不发白)。缺省 **0.20** —— 由真 CRT 照片的饱和度曲线
    /// 定标而来(knee 0.20 + 强度 0.85 时与照片的均方差 0.035,关闭时 0.376,好 10.7 倍)
    public var overdriveKnee: Double?

    // 小件三连(YeTerm v1.2 #8 扩展)
    public var inheritCwd: Bool?          // ⌘N/⌘T 新窗继承当前目录;缺省开
    public var scrollbackLines: Int?      // 滚回历史行数;缺省 10000
    public var optionAsMeta: Bool?        // Option 键当 Meta(Emacs/zsh 词跳);缺省开

    public static func load(path: String) -> CRTConfig? {
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("config: 无法读取 \(path)\n".utf8))
            return nil
        }
        do {
            return try JSONDecoder().decode(CRTConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("config: JSON 解析失败 \(error)\n".utf8))
            return nil
        }
    }

    // MARK: - 颜色数学(逐行对齐 cool-retro-term 原版并逐值核实过)

    /// 原版 `strToColor`:各分量除以 **256**(非 255)
    static func strToColor(_ hex: String?) -> SIMD3<Float>? {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return .init(Float((v >> 16) & 0xff) / 256.0,
                     Float((v >> 8) & 0xff) / 256.0,
                     Float(v & 0xff) / 256.0)
    }

    /// contrast/saturation 的 CPU 预混色(原版从不进 shader,全版本等效公式):
    ///   k   = 0.7 + contrast×0.3
    ///   sat = lerp(fg, white, saturation×0.5)
    ///   fontColor(uniform)       = lerp(bg, sat, k)
    ///   backgroundColor(uniform) = lerp(sat, bg, k)
    public func effectiveColors() -> (font: SIMD4<Float>, background: SIMD4<Float>) {
        let fg = Self.strToColor(fontColor) ?? .init(1, 1, 1)
        let bg = Self.strToColor(backgroundColor) ?? .init(0, 0, 0)
        let white = SIMD3<Float>(repeating: 255.0 / 256.0)
        let s = Float(saturationColor ?? 0)
        let k = 0.7 + Float(contrast ?? 0.8) * 0.3
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let sat = lerp(fg, white, s * 0.5)
        let font = lerp(bg, sat, k)
        let back = lerp(sat, bg, k)
        return (.init(font, 1), .init(back, 1))
    }

    /// `"System: Menlo"` → 去前缀的字体名(原版对系统字体加 "System: " 前缀)
    public var resolvedFontName: String? {
        guard var n = fontName else { return nil }
        if let r = n.range(of: "System: ") { n.removeSubrange(r) }
        return n.isEmpty ? nil : n
    }

    /// 映射到当前已实现的 uniform 集(M1b 接全链后扩展)。
    /// 弧度按 v1.2 世代语义 ×0.4(screenCurvatureSize)。
    func apply(to u: inout CRTUniforms) {
        let colors = effectiveColors()
        u.fontColor = colors.font
        u.backgroundColor = colors.background
        if let c = chromaColor { u.chromaColor = Float(c) }
        if let n = staticNoise { u.staticNoise = Float(n) }
        if let r = rasterization { u.rasterMode = Int32(r) }
        // 弧度尺度:v2 世代 ×0.4,master(version 3)×0.6
        let curvScale: Float = (version ?? 2) >= 3 ? 0.6 : 0.4
        if let cur = screenCurvature { u.screenCurvature = Float(cur) * curvScale }
        if let f = flickering { u.flickering = Float(f) }
        if let h = horizontalSync, h > 0 {
            u.horizontalSyncStrength = 0.05 + Float(h) * (0.35 - 0.05)   // lint(0.05,0.35,h)
        }
        if let j = jitter { u.jitter = Float(j) }
        if let g = glowingLine { u.glowingLine = Float(g) * 0.2 }        // QML 喂入前 ×0.2
        if let b = bloom { u.bloomAmount = Float(b) * 2.5 }              // QML: bloom×2.5
        // 辉光风格 1(halation)的幅度补偿:加权 max 保住亮核峰值,而归一化高斯
        // 把亮核摊薄必然掉峰值 —— 同一个 bloom 滑块值下 max 版亮好几倍。乘一个
        // 补偿系数,让同一份预设在两种风格间切换时**总体强度相当**、不必重调滑块。
        // 系数由 --render-demo 实测两风格的画面平均亮度定标(见 v1.4 自测记录)。
        u.bloomStyle = (bloomStyle ?? 0) == 1 ? 1 : 0
        u.bloomShape = (bloomShape ?? 0) == 1 ? 1 : 0
        // 紧核+长尾把能量收进笔画附近,同一 bloom 值下近处更亮 → 幅度补偿(实测定标)
        if u.bloomShape > 0.5 { u.bloomAmount *= Self.dualShapeCompensation }
        if u.bloomStyle > 0.5 { u.bloomAmount *= Self.halationCompensation }
        u.emissiveModel = (emissiveModel ?? 0) == 1 ? 1 : 0
        // 背景图荧光染色(v1.5.1)。`bgImageOn` 不在这里填 —— 那要看纹理到底加载成功
        // 没有,由消费方(MetalOverlayView / RenderDemo)每帧按实际绑定的纹理填。
        u.bgImageChroma = (crtBackgroundImageChroma ?? false) ? 1 : 0
        // 白热化(v1.4)。⚠️ **白底主题一律关掉** —— 2026-07-31 用户实测
        // 「Macintosh 128K 文字一点都看不清」的根修之一:
        // 白热化模拟的是「电子束把磷光体打到过曝而发白」,前提是**亮的东西是文字**。
        // 白底黑字的主题(Mac 128K / ZX Spectrum / E-Ink / Solarized Light)整个反过来 ——
        // 亮的是背景、文字是电子束**关掉**的地方,此时白热化只会啃掉笔画的抗锯齿边缘
        // 把字变淡,对背景做的那点提亮毫无意义(它本来就接近白)。
        // 按**前景/背景亮度关系**自动判定,而不是写死预设名 —— 用户自制主题也受保护。
        let fgLum = Self.strToColor(fontColor).map { 0.21 * $0.x + 0.72 * $0.y + 0.04 * $0.z } ?? 1
        let bgLum = Self.strToColor(backgroundColor).map { 0.21 * $0.x + 0.72 * $0.y + 0.04 * $0.z } ?? 0
        u.overdrive = bgLum > fgLum ? 0 : Float(overdrive ?? 0)
        u.overdriveKnee = Float(overdriveKnee ?? 0.20)
        if let br = brightness { u.brightness = 0.5 + Float(br) }        // lint(0.5,1.5,b)
        if let bi = burnIn, bi > 0 {
            u.burnIn = Float(bi)
            u.burnInTime = 1.0 / (0.16 + Float(bi) * (1.6 - 0.16))       // 1/lint(0.16,1.6,b) 秒
        }
        u.rgbShift = Float(rgbShift ?? rbgShift ?? 0)                    // 原值;每帧换算 UV
        u.contentOffset = .init(repeating: Float(margin ?? 0.5))         // 原值;每帧换算 UV

        // ---- 机壳层(1.2 TerminalFrame.qml 的 CPU 侧公式;master 版已退役) ----
        //   _lightColor = mix(fontColor, backgroundColor, 0.2)(原始配置色,非预混)
        //   frameColor  = mix(#fff, _lightColor, lint(0.2, 0.8, ambientLight))
        let ambient = Float(ambientLight ?? 0)
        let fSizeRaw = Float(frameMargin ?? 0.2)
        u.ambientLight = ambient
        u.frameSize = fSizeRaw * 0.05                                    // 保留字段(1.2 屏幕无内缩,着色器不再用)
        let radius = Float(screenRadius ?? 0.2)
        u.screenRadius = (4.0 + radius * (120.0 - 4.0)) * 2.0
        u.frameShininess = Float(frameShininess ?? 0.2) * 0.5
        // 1.2 displayTerminalFrame 条件 × YeTerm 机壳总开关(2026-07-28 用户实测:
        // frameMargin 恒 0.2 使机壳恒开,弧度调 0 四角暗角/阴影仍在且无处可关 →
        // 屏幕页暴露开关,关=整层消失;缺省开=原版观感不变)
        // 屏幕弧度>0 时机壳**强制开**(2026-08-06 用户裁决):弧度把屏幕四角鼓成
        // 弧形,没机壳包边就是四角残缺的怪相 —— 此时忽略 frameEnabled(设置页
        // 开关同步灰掉)。frameEnabled 本身不动:弧度归零后回到用户原选择。
        let curveOn = (screenCurvature ?? 0) > 0
        u.frameOn = ((frameEnabled ?? true) || curveOn) && (fSizeRaw > 0 || curveOn) ? 1 : 0
        let fgRaw = Self.strToColor(fontColor) ?? SIMD3<Float>(1, 1, 1)
        let bgRaw = Self.strToColor(backgroundColor) ?? SIMD3<Float>(0, 0, 0)
        let baseFrame = Self.strToColor(frameColor) ?? SIMD3<Float>(1, 1, 1)   // _staticFrameColor 默认 #fff
        let lightColor = fgRaw + (bgRaw - fgRaw) * 0.2
        let ambF = 0.2 + 0.6 * ambient                                    // lint(0.2,0.8,ambient)
        let mixed = baseFrame + (lightColor - baseFrame) * ambF
        u.frameColor = .init(mixed, 1)

        // CRT 总开关关(v1.2 用户裁决 2026-07-28:**渲染管线永远 GPU**,
        // 关"特效"只是观感直通):全部特效参数中性化 —— modern 直通、零弧度/
        // 噪点/闪烁/抖动/辉光/余辉/色差、无机壳、亮度中性;颜色跳过 contrast/
        // saturation 预混,配置 hex 精确直出;chroma 全开 = ANSI 彩色保真。
        // 放在 apply 尾部统一生效:GUI/render-demo/一切消费方同一条路。
        if crtEffectsEnabled == false {
            u.screenCurvature = 0
            u.staticNoise = 0
            u.flickering = 0
            u.horizontalSyncStrength = 0
            u.jitter = 0
            u.glowingLine = 0
            u.bloomAmount = 0
            u.burnIn = 0
            u.rgbShift = 0
            u.rasterMode = 4          // modern 直通
            u.brightness = 1
            u.frameOn = 0
            u.ambientLight = 0
            u.chromaColor = 1
            u.emissiveModel = 0       // v1.4:自发光模型属 CRT 特效,普通模式一并中性化
                                      // (shader 侧 colorPassthrough 也会绕过,这里是双保险)
            u.bloomStyle = 0          // bloomAmount 已归零、辉光趟根本不跑,归零只为探针可断言
            u.overdrive = 0           // 白热化是 CRT 物理,普通终端模式不该有
            u.bloomShape = 0
            // 背景图在普通模式走合成层铺底(不进 CRT pass),shader 侧一并中性化:
            // bgImageOn 由消费方填 0,染色档归零只为探针可断言
            u.bgImageChroma = 0
            // 直通模式颜色 = 普通终端独立配色(÷255 精确)。
            // colorPassthrough:shader 绕过 convertWithChroma(chroma=1 也有
            // fontColor 乘染/暗部混 bg 的串色,用户 p10k 实测);fontColor 仅供
            // 光标块使用,backgroundColor 填余量/留白区(与内容 bg 同源同值)
            u.colorPassthrough = 1
            let p = plainPalette()
            u.fontColor = .init(p.fg, 1)
            u.backgroundColor = .init(p.bg, 1)
        }
    }

    /// hex → RGB,标准 ÷255(精确直出;区别于 crterm strToColor 的 ÷256)
    static func hex255(_ s: String?) -> SIMD3<Float>? {
        guard var t = s else { return nil }
        if t.hasPrefix("#") { t = String(t.dropFirst()) }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return .init(Float((v >> 16) & 0xff) / 255.0,
                     Float((v >> 8) & 0xff) / 255.0,
                     Float(v & 0xff) / 255.0)
    }

    /// CRT 模式的 ANSI 16 色覆盖(v1.2 预设大更新;nil = crterm 专属调色板)。
    /// ÷255 精确直出 —— 经典配色主题的官方 ANSI 表按原色值上屏,染色交给
    /// chroma(色准约定 chroma=1 时原样保留)
    func crtAnsiPalette() -> [SIMD3<Float>]? {
        guard let hexes = ansiColors, hexes.count == 16 else { return nil }
        return hexes.map { Self.hex255($0) ?? .init(0, 0, 0) }
    }

    /// CRT 模式默认前景覆盖(2026-08-03「文字颜色」):÷255 精确直出(同
    /// crtAnsiPalette 的理由 —— YeTerm 扩展字段不吃 crterm ÷256 怪癖);
    /// nil = 纯白 = 历史行为
    func crtTextFg() -> SIMD3<Float>? { Self.hex255(crtTextColor) }

    /// 普通终端模式的 AnsiColor 覆盖表(v1.2;strToColor 除以 256 的 crterm 语义
    /// 不适合普通模式精确配色,这里用标准 ÷255)
    func plainPalette() -> (fg: SIMD3<Float>, bg: SIMD3<Float>, palette: [SIMD3<Float>]) {
        func hex255(_ s: String?) -> SIMD3<Float>? { Self.hex255(s) }
        let hexes = plainAnsiColors ?? AnsiColor.terminalAppAnsiHex
        var palette: [SIMD3<Float>] = []
        for i in 0..<16 {
            let fallback = hex255(AnsiColor.terminalAppAnsiHex[i]) ?? .init(0, 0, 0)
            palette.append(i < hexes.count ? (hex255(hexes[i]) ?? fallback) : fallback)
        }
        return (hex255(plainTextColor) ?? .init(1, 1, 1),
                hex255(plainBackgroundColor) ?? .init(0, 0, 0),
                palette)
    }

    /// FastBlur 半径语义:lint(16, 64, bloomQuality);无 bloomQuality 字段时用默认 0.5 → 40px
    var bloomRadiusPx: Float {
        40
    }

    /// 辉光风格 1(halation)的幅度补偿系数。定标方法:同一 fixture 用两种风格各出一张
    /// --render-demo 图,调此系数使两图的平均亮度接近(实测记录见 v1.4 自测)。
    static let halationCompensation: Float = 0.12

    /// 双尺度光晕(紧核+长尾)的幅度补偿,同样由 --render-demo 实测平均亮度定标
    static let dualShapeCompensation: Float = 1.0
}
