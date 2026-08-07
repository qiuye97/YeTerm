// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 设置页探针(自测体系 5/5)
//
// 这个文件:离屏实例化设置窗,逐导航页截图断言"渲染非空白",再验配置库
//   逻辑(重名拒绝/系统预设拒删/删除回落)。注意 persistenceEnabled = false
//   那行:探针绝不许写用户真实配置文件 —— 曾经差点污染,加了保险丝。
//   (教训:测试代码碰真实数据前,先想想怎么隔离。)
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftUI

/// 设置页自测(--probe-settings <png前缀>):离屏实例化设置窗,逐导航页截图 ——
/// SwiftUI 布局问题(空白页/组件缺失)不用等用户开 GUI 才发现;
/// 同时断言复古字体注册成功。
public enum SettingsProbe {
    public static func run(outPrefix: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        FontLibrary.registerBundledFonts()

        // 探针把界面语言钉成中文:下面大量断言直接比对中文文案,
        // 不钉的话用户/CI 环境切成英文就会整片误报(实测踩到)。
        // i18n 自己那几条在下面临时切到英文再切回来。
        L10n.shared.language = .zhHans

        var pass = true
        func check(_ name: String, _ ok: Bool, detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { pass = false }
        }

        check("复古字体注册 ≥ 10 款", FontLibrary.retroFamilies.count >= 10,
              detail: "count=\(FontLibrary.retroFamilies.count)")
        let families = Set(FontLibrary.allFamilies())
        let sample = FontLibrary.retroFamilies.prefix(3).map(\.family)
        check("注册字体可被系统枚举", sample.allSatisfy { families.contains($0) },
              detail: sample.joined(separator: ", "))
        check("模糊搜索", FontLibrary.fuzzyMatch("trmns", "Terminus (TTF)")
                        && !FontLibrary.fuzzyMatch("zzz", "Terminus"))

        // ---- 多语言(i18n)----
        // 缺翻译只会回落中文、不会崩,所以**必须有断言盯着**,否则英文界面
        // 会悄悄退化成半中半英而没人发现。四条:
        let l10n = L10n.shared
        let savedLang = l10n.language   // = .zhHans(上面刚钉的)
        l10n.language = .english
        let enTable = L10n.enTableForTesting()
        check("英文译文表载入", enTable.count >= 400, detail: "count=\(enTable.count)")
        check("英文模式真的翻译了", L("设置…") == "Settings…" && L("终端") == "Terminal",
              detail: "\(L("设置…")) / \(L("终端"))")
        check("缺翻译回落中文(不留空)", L("这句故意不在表里") == "这句故意不在表里")
        // 占位符完整性:译文里的 %@/%d/%1$@ 必须与原文一一对应 ——
        // 少一个 String(format:) 就丢数据,多一个会读到野内存(真会崩)。
        func specs(_ s: String) -> [String] {
            var out: [String] = []
            var it = Array(s), i = 0
            while i < it.count {
                if it[i] == "%", i + 1 < it.count {
                    var j = i + 1
                    while j < it.count, it[j].isNumber || it[j] == "$" { j += 1 }
                    if j < it.count, "@dfs%".contains(it[j]) {
                        out.append(String(it[i...j])); i = j + 1; continue
                    }
                }
                i += 1
            }
            return out.sorted()
        }
        let badSpec = enTable.filter { specs($0.key) != specs($0.value) }
        check("译文占位符与原文一致", badSpec.isEmpty,
              detail: badSpec.keys.prefix(3).joined(separator: " | "))
        l10n.language = savedLang
        check("语言切回后恢复中文", l10n.language == .zhHans && L("终端") == "终端")

        // v1.2 预设扩容:总量 + 每套系统预设必须有简介(加新预设漏写说明立刻红)
        check("内置预设 ≥ 43 套", Presets.names.count >= 43,
              detail: "count=\(Presets.names.count)")
        check("系统预设简介全覆盖", Presets.names.allSatisfy { Presets.blurb($0) != nil },
              detail: Presets.names.filter { Presets.blurb($0) == nil }.joined(separator: ", "))
        check("预设分组无遗漏", Presets.groups.flatMap(\.names).count == Presets.names.count)
        // v1.2 补丁:经典 CRT 锁定判定 + 经典配色携带普通模式配色(关特效不"全都一样")
        check("经典 CRT 锁定判定", Presets.isClassicCRT("Apple ][") && !Presets.isClassicCRT("Dracula"))
        check("经典配色带普通模式配色",
              Presets.classicSchemes.allSatisfy { $0.plainTextColor != nil && $0.plainBackgroundColor != nil })
        // v1.2 补丁:22 套经典配色全部携带专属 ANSI 16 色(官方表或按气质原创)
        check("经典配色 ANSI 表全覆盖",
              Presets.classicSchemes.allSatisfy { $0.ansiColors?.count == 16 && $0.plainAnsiColors?.count == 16 })
        // 每套系统预设必须配字体,且字体名可解析(内置注册族 or 系统已装族)
        let resolvable = Set(FontLibrary.retroFamilies.map(\.family))
            .union(FontLibrary.allFamilies())
        let unresolved = Presets.all.compactMap { c -> String? in
            guard let f = c.resolvedFontName else { return "\(c.name ?? "?")(缺字体)" }
            return resolvable.contains(f) ? nil : "\(c.name ?? "?")→\(f)"
        }
        check("预设匹配字体全覆盖且可解析", unresolved.isEmpty,
              detail: unresolved.joined(separator: ", "))
        // 内置 imgcat 资源(v1.2 #4 一键安装的源;缺了打包就废)
        let imgcatURL = Bundle.module.url(forResource: "imgcat", withExtension: nil,
                                          subdirectory: "Tools")
        let imgcatHead = imgcatURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .prefix(20) ?? ""
        // v1.3:提示符主题 —— 集成脚本含 YETERM_PROMPT 处理段(四套内置全在),
        // 经典 CRT 全带 promptTheme、经典配色全不干预(nil)
        let integ = ShellIntegration.script
        check("集成脚本含提示符主题段",
              integ.contains("YETERM_PROMPT") && ["ascii", "dos", "c64", "minimal"]
                  .allSatisfy { integ.contains($0) }
              && integ.contains("prompt_powerlevel9k_teardown"))
        check("经典 CRT 预设全带复古提示符",
              Presets.classicCRT.allSatisfy { $0.promptTheme?.hasPrefix("retro:") == true })
        check("经典配色预设不干预提示符",
              Presets.classicSchemes.allSatisfy { $0.promptTheme == nil })
        check("MS-DOS 蓝配 DOS 提示符", Presets.byName("MS-DOS 蓝")?.promptTheme == "retro:dos"
              && Presets.byName("Commodore 64")?.promptTheme == "retro:c64")
        // v1.4:经典 CRT 全部逐机型配了白热化 + 紧核长尾光晕(新增机型忘配立刻红)
        let noGlow = Presets.classicCRT.filter { ($0.overdrive ?? 0) <= 0 || $0.bloomShape != 1 }
            .map { $0.name ?? "?" }
        check("经典 CRT 全带白热化 + 紧核长尾光晕", noGlow.isEmpty,
              detail: noGlow.joined(separator: ", "))
        // 单色数据终端一类必须用照片定标值;存储管必须最弱(物理原理差别,别被后人调平)
        check("VT220 用照片定标值 / 存储管最弱",
              Presets.byName("DEC VT220")?.overdrive == 0.85
              && Presets.byName("DEC VT220")?.overdriveKnee == 0.20
              && (Presets.byName("Tektronix 4014")?.overdrive ?? 1) < 0.3)
        // v1.4 用户裁决:经典配色统一成「只开辉光 + 文字发光」,设备特征全关。
        // Deep Blue / Matrix 两套点名保留原样(本就是按 CRT 设备气质创作的)。
        let unified = Presets.classicSchemes.filter { !["Deep Blue", "Matrix"].contains($0.name ?? "") }
        let notClean = unified.filter { c in
            (c.rasterization ?? 0) != 4 || (c.screenCurvature ?? 1) != 0
            || (c.frameMargin ?? 1) != 0 || c.frameEnabled != false
            || (c.burnIn ?? 1) != 0 || (c.staticNoise ?? 1) != 0 || (c.flickering ?? 1) != 0
            || (c.glowingLine ?? 1) != 0 || (c.horizontalSync ?? 1) != 0 || (c.jitter ?? 1) != 0
            || (c.rgbShift ?? 1) != 0 || (c.rbgShift ?? 1) != 0 || (c.ambientLight ?? 1) != 0
        }.map { $0.name ?? "?" }
        check("经典配色:设备特征全关(光栅/弧度/机壳/余辉/噪点/闪烁/亮线/失步/抖动/色差/环境光)",
              notClean.isEmpty, detail: notClean.joined(separator: ", "))
        let notUniform = unified.filter {
            $0.bloom != 0.3 || $0.overdrive != 0.4 || $0.overdriveKnee != 0.55 || $0.bloomShape != 1
        }.map { $0.name ?? "?" }
        check("经典配色:辉光与文字发光全部统一(20 套同值)",
              notUniform.isEmpty && unified.count == 20,
              detail: notUniform.isEmpty ? "count=\(unified.count)" : notUniform.joined(separator: ", "))
        // 例外两套必须**原样保留**(别被后人"顺手统一"掉)
        check("Deep Blue / Matrix 保留设备气质",
              (Presets.byName("Deep Blue")?.screenCurvature ?? 0) > 0
              && (Presets.byName("Matrix")?.screenCurvature ?? 0) > 0
              && Presets.byName("Deep Blue")?.rasterization == 0
              && Presets.byName("Matrix")?.rasterization == 0)

        // v1.2 补丁:主题格式文档入包(设置「配置文件」页可导出,喂 AI 生成主题)
        let docURL = Bundle.module.url(forResource: "主题配置格式", withExtension: "md", subdirectory: "Docs")
        let docSize = docURL.flatMap { try? Data(contentsOf: $0).count } ?? 0
        check("主题格式文档入包且非空", docSize > 2000, detail: "size=\(docSize)")
        check("内置 imgcat 脚本入包且完好",imgcatHead.hasPrefix("#!/"),
              detail: imgcatURL?.lastPathComponent ?? "缺失")
        // imgcat 是 YeTerm 自写版(开源前把 iTerm2 那份 GPL-2 脚本换掉了,见
        // THIRD-PARTY-NOTICES.md)。两条断言防回退:
        //   ①许可声明还在 —— 有人若图省事换回上游脚本,这里立刻红;
        //   ②大图速度:非 tmux 走单条大序列(`1337;File=`),tmux 才分段
        //     (2026-07-28 用户实测:逐条 printf 上万条序列慢到没法用)。
        let imgcatFull = imgcatURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("imgcat 是本项目自写版(GPL-3 声明在)",
              imgcatFull.contains("GPL-3.0-or-later"))
        check("imgcat 保留单条快路径 + tmux 分段兼容",
              imgcatFull.contains("1337;File=") && imgcatFull.contains("1337;MultipartFile="))

        // UI 文案不得出现 cool-retro-term 字样(用户 2026-07-27 裁决;简介+组标题全查)
        let uiTexts = Presets.groups.map(\.title) + Presets.names.compactMap { Presets.blurb($0) }
        check("UI 文案无 crterm 字样", !uiTexts.contains { $0.lowercased().contains("retro-term") || $0.lowercased().contains("crterm") })

        let model = SettingsModel(from: Presets.byName("Default Amber"))
        model.persistenceEnabled = false   // 探针不许碰用户真实配置

        // ---- 配置库逻辑(真实文件,自清理) ----
        let tmpName = "probe-临时配置"
        model.deleteProfile(named: tmpName)   // 清残留
        check("系统预设名不可用", !model.nameAvailable("Default Amber"))
        check("新名称可用", model.nameAvailable(tmpName))
        check("创建用户配置", model.createProfile(named: tmpName)
                            && model.userProfileNames.contains(tmpName))
        check("重名被拒", !model.createProfile(named: tmpName))
        check("创建后成为当前配置", model.presetName == tmpName && !model.isBuiltin(tmpName))
        model.deleteProfile(named: tmpName)
        check("删除用户配置并回落系统预设", !model.userProfileNames.contains(tmpName)
                            && model.isBuiltin(model.presetName))
        let before = model.userProfileNames
        model.deleteProfile(named: "Default Amber")
        check("系统预设拒绝删除", Presets.byName("Default Amber") != nil
                            && model.userProfileNames == before)

        // CRT 开关随预设走(用户裁决:开关不凌驾于预设)
        check("内置预设全部显式 CRT 开",
              Presets.all.allSatisfy { $0.crtEffectsEnabled == true })
        model.crtEffectsEnabled = false
        model.loadPreset("Default Amber")
        check("普通模式点 CRT 预设即切回", model.crtEffectsEnabled)

        // 壁纸跟着预设走(2026-08-07 用户需求;此前 load 用 ?? 兜底当前值,
        // 换预设时上一套的壁纸一路残留 = "所有预设共用一张")。钉住新语义:
        // 带壁纸的配置载入后,再载入不带壁纸字段(nil)的出厂预设,壁纸必须清空
        var wpCfg = CRTConfig()
        wpCfg.plainBackgroundImage = "/tmp/probe-壁纸.png"
        wpCfg.plainBackgroundImageMode = 3
        wpCfg.plainBackgroundDarken = 0.9
        wpCfg.crtBackgroundImageChroma = true
        let wpModel = SettingsModel(from: wpCfg)
        wpModel.persistenceEnabled = false
        let wpLoaded = wpModel.plainBackgroundImagePath == "/tmp/probe-壁纸.png"
            && wpModel.plainBackgroundImageMode == 3 && wpModel.crtBackgroundImageChroma
            && wpModel.plainBackgroundDarken == 0.9
        wpModel.load(config: Presets.byName("Default Amber")!)
        check("壁纸跟预设走:载入无壁纸预设即清空(不残留上一套)",
              wpLoaded && wpModel.plainBackgroundImagePath.isEmpty
              && wpModel.plainBackgroundImageMode == 0
              && wpModel.plainBackgroundDarken == 0.5
              && !wpModel.crtBackgroundImageChroma,
              detail: "loaded=\(wpLoaded) path=\(wpModel.plainBackgroundImagePath) mode=\(wpModel.plainBackgroundImageMode)")
        // 暗化乘数定标:0.5 档必须精确 = 0.35(v1.2 固定观感;auto-drive 有
        // ×0.35 像素直读断言,分段线性映射的会合点不许漂)
        check("暗化滑块 0.5 档 = ×0.35(旧观感钉死)",
              PlainBackground.dimMultiplier(0.5) == Float(0.35)
              && PlainBackground.dimMultiplier(0) == 1.0
              && PlainBackground.dimMultiplier(1) == 0.0,
              detail: "mid=\(PlainBackground.dimMultiplier(0.5))")

        // ---- v1.4 三项新配置(「文字发光」)----
        // ① 二进制合同:CRTUniforms 尾部追加四个 float(emissiveModel/bloomStyle/
        //    overdrive/overdriveKnee)后 size = 232。setFragmentBytes 传的是 .size,
        //    最后一个字段必须落在 size 之内,否则 GPU 读到垃圾(216 也不是 16 的倍数,
        //    非整倍 size 本就有先例、可行;这里只钉住「别漏改一侧」)
        // v1.5.1 背景图片再追加三个字段(bgImageOn / bgImageUVScale / bgImageChroma)
        // → size = 252。中间那个是 float2,**要 8 字节对齐**:236 不是 8 的倍数,所以
        // 它排在 240,前后各一个 float 恰好填满、无空洞 —— 这条断言就是防这类排布事故
        // (排错了两侧结构体大小会对不上,GPU 从此读到错位的参数)。
        // 2026-08-07 机壳最小带再追加 _padScreenInset(252→256 对齐占位)+
        // screenInset(float2,256→264)→ size = 264(Metal 侧 sizeof 含尾部对齐 = 272)
        check("CRTUniforms 布局 = 264 字节",
              MemoryLayout<CRTUniforms>.size == 264,
              detail: "size=\(MemoryLayout<CRTUniforms>.size) stride=\(MemoryLayout<CRTUniforms>.stride)")
        check("背景图字段缺省中性(不铺图 + 不染色)",
              CRTUniforms().bgImageOn == 0 && CRTUniforms().bgImageChroma == 0)
        // ② 缺省必须 = 老行为(旧配置档解析出 nil → 走原路,观感零变化)
        var neutral = CRTUniforms()
        CRTConfig().apply(to: &neutral)
        check("新字段缺省中性(辉光高斯 + 颜料模型 + 白热化关)",
              neutral.bloomStyle == 0 && neutral.emissiveModel == 0 && neutral.overdrive == 0
              && neutral.bloomShape == 0)
        // ③ round-trip:load → toConfig 不丢字段
        var rt = CRTConfig()
        rt.bloomStyle = 1; rt.emissiveModel = 1; rt.bitRate = 14400
        rt.overdrive = 0.7; rt.overdriveKnee = 0.55; rt.bloomShape = 1
        let rtModel = SettingsModel(from: rt)
        rtModel.persistenceEnabled = false
        let back = rtModel.toConfig()
        check("v1.4 字段 round-trip 不丢",
              back.bloomStyle == 1 && back.emissiveModel == 1 && back.bitRate == 14400
              && back.overdrive == 0.7 && back.overdriveKnee == 0.55 && back.bloomShape == 1,
              detail: "bloom=\(back.bloomStyle ?? -1) emissive=\(back.emissiveModel ?? -1) bps=\(back.bitRate ?? -1) od=\(back.overdrive ?? -1)")
        // ④ CRT 总开关关 → 新特效一并中性化(auto-drive 场景 20 的同款纪律)
        var offU = CRTUniforms()
        var offCfg = CRTConfig()
        offCfg.crtEffectsEnabled = false
        offCfg.bloomStyle = 1; offCfg.emissiveModel = 1; offCfg.overdrive = 0.8; offCfg.bloomShape = 1
        offCfg.apply(to: &offU)
        check("CRT 关 → 辉光风格/发光模型/白热化归零",
              offU.bloomStyle == 0 && offU.emissiveModel == 0 && offU.bloomAmount == 0
              && offU.overdrive == 0 && offU.bloomShape == 0)
        // v1.4 高刷支持:帧率换算规则(测真函数 MetalOverlayView.resolveFPS,不是重复算术)。
        // 真机跑到多少受显示器限制,但**规则**必须可测 —— 尤其"选 120 而屏只有 60"这种
        // 情形要如实降级,不能让设置页显示 120 却实际跑 60。
        let rf = MetalOverlayView.resolveFPS
        let fpsRules =
            rf(120, 144, false) == 120      // 高刷屏选 120 → 120
            && rf(0, 144, false) == 144     // 跟随显示器 → 跑满 144
            && rf(0, 240, false) == 240     // 更高刷也跟得上
            && rf(120, 60, false) == 60     // ★ 60Hz 屏选 120 → 如实降到 60
            && rf(0, 60, false) == 60       // 60Hz 屏跟随 → 60
            && rf(60, 120, false) == 60     // 主动选 60 → 不擅自提到 120
            && rf(120, 144, true) == 30     // 低电量 → 压到 30
            && rf(30, 144, false) == 30     // 省电挡照旧
        check("帧率换算规则正确(含 60Hz 屏选 120 如实降级 / 跟随显示器跑满高刷)", fpsRules)
        // ⑤ 白底主题必须禁用白热化(2026-07-31 用户实测「Macintosh 128K 文字一点都看不清」)。
        //    白热化模拟「电子束把磷光体打到过曝而发白」,前提是**亮的是文字**;
        //    白底黑字整个反过来,开着只会啃掉笔画边缘把字洗没。按前景/背景亮度自动判定。
        func overdriveOf(_ name: String) -> Float {
            var u = CRTUniforms()
            Presets.byName(name)?.apply(to: &u)
            return u.overdrive
        }
        let lightBg = ["Macintosh 128K", "ZX Spectrum", "E-Ink", "Solarized Light"]
        let stillOn = lightBg.filter { overdriveOf($0) > 0 }
        check("白底主题禁用白热化(否则文字被洗没)", stillOn.isEmpty,
              detail: stillOn.joined(separator: ", "))
        // 暗底主题不能被误伤 —— 护栏只该拦白底
        check("暗底主题白热化照旧生效",
              overdriveOf("DEC VT220") == 0.85 && overdriveOf("Dracula") > 0)
        // 用户自制主题也受保护(不是写死预设名)
        var lightTheme = CRTConfig()
        lightTheme.backgroundColor = "#ffffff"; lightTheme.fontColor = "#000000"
        lightTheme.overdrive = 0.9
        var lu = CRTUniforms(); lightTheme.apply(to: &lu)
        check("自制白底主题同样受护栏保护", lu.overdrive == 0)
        // ⑥ 波特率**跟着预设走**(2026-07-30 用户裁决):切到没配速率的预设必须回到不限速,
        //    不许残留上一个预设的速率(否则换主题后还在慢慢吐字,看着像卡了)
        //    ⚠️ 必须用 load(config:) 直喂,**不能** loadPreset("...") —— 后者会读用户
        //    真实的 override 文件,用户给那个预设配过速率就会让断言翻车(第一版就这么红了:
        //    用户实测时给 Default Amber 存过 2400)。探针不许依赖用户数据。
        let rateModel = SettingsModel(from: Presets.byName("Default Amber"))
        rateModel.persistenceEnabled = false
        rateModel.bitRate = 14400
        rateModel.load(config: CRTConfig())        // 不带 bitRate 的主题
        check("切到不带速率的主题 → 回落不限速(身份字段直赋,不残留)",
              rateModel.bitRate == 0, detail: "切后 bitRate=\(rateModel.bitRate)")
        var carried = CRTConfig()
        carried.bitRate = 300
        rateModel.load(config: carried)
        check("主题带速率 → 跟着生效", rateModel.bitRate == 300)
        // ⑥ 机壳开关**跟着预设走**(2026-08-06 bug 修复):经典配色出厂显式 frameEnabled=false,
        //    经典 CRT 是 nil(缺省开)—— 往返切换后 false 不许残留(load 直赋 ?? true)。
        //    同上,用 load(config:) 直喂出厂值,不走 loadPreset(不依赖用户 override)
        let frameModel = SettingsModel(from: Presets.byName("DEC VT220"))
        frameModel.persistenceEnabled = false
        check("经典 CRT 出厂机壳开", frameModel.frameEnabled)
        frameModel.load(config: Presets.byName("Dracula") ?? CRTConfig())   // 经典配色:显式 false
        check("切经典配色 → 机壳关(出厂显式 false)", !frameModel.frameEnabled)
        frameModel.load(config: Presets.byName("DEC VT220") ?? CRTConfig()) // 切回:nil 必须回缺省开
        check("切回经典 CRT → 机壳恢复开(false 不残留)", frameModel.frameEnabled)
        // ⑥ 波特率档位表:升序、无重复、首档为「不限速」、覆盖 110~10Mbps
        let rates = ByteRateLimiter.presetRates
        check("波特率档位表合法(16 档升序无重复)",
              rates.first == 0 && rates.count == 16
              && rates == rates.sorted() && Set(rates).count == rates.count
              && rates.last == 10_000_000 && rates[1] == 110,
              detail: "count=\(rates.count)")
        // ⑥ 档位显示名的分界写法(≤9600 用 bps,再往上 kbps/Mbps)
        check("波特率显示名分界正确",
              ByteRateLimiter.rateLabel(0) == "不限速"
              && ByteRateLimiter.rateLabel(9600) == "9600 bps"
              && ByteRateLimiter.rateLabel(14400) == "14.4 kbps"
              && ByteRateLimiter.rateLabel(56000) == "56.0 kbps"
              && ByteRateLimiter.rateLabel(1_500_000) == "1.5 Mbps",
              detail: "9600→\(ByteRateLimiter.rateLabel(9600)) 14400→\(ByteRateLimiter.rateLabel(14400))")

        // ---- 字形安放策略(2026-07-30 用户实测 q2.png「符号显示不全」)----
        // 钉死两条:①真的比格子大的符号必须缩(不然被裁掉半个);
        // ②普通文字/CJK 一律原样(尤其点阵字体,缩放会毁掉逐像素锐利)
        if let dev = MTLCreateSystemDefaultDevice() {
            let f = NSFont(name: "Menlo", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
            let cell = GlyphAtlas.cellSize(font: f, scale: 2)
            if let atlas = GlyphAtlas(device: dev, font: f, cellPx: cell, scale: 2) {
                let oversized = ["①", "⑴", "❸"]
                let bad = oversized.filter { atlas.fitKind(text: $0) != .scaled }
                check("超格符号走缩放(①⑴❸)", bad.isEmpty,
                      detail: bad.map { "\($0)=\(atlas.fitKind(text: $0).rawValue)" }
                          .joined(separator: " "))
                let plain = ["A", "z", "0", "@", "-", "你", "漢"]
                let moved = plain.filter { atlas.fitKind(text: $0, wide: $0 == "你" || $0 == "漢") != .normal }
                check("普通文字/CJK 一律原样", moved.isEmpty,
                      detail: moved.map { "\($0)=\(atlas.fitKind(text: $0).rawValue)" }
                          .joined(separator: " "))
            } else {
                check("字形图集可创建(策略断言前提)", false)
            }
            // 点阵字体(方舟像素):所有 ASCII 都不许被缩放 —— 缩了就毁点阵对齐
            if let zpix = NSFont(name: "Ark Pixel 12px Mono zh_cn", size: 16) {
                let cell = GlyphAtlas.cellSize(font: zpix, scale: 2)
                if let atlas = GlyphAtlas(device: dev, font: zpix, cellPx: cell, scale: 2) {
                    let ascii = (33...126).map { String(UnicodeScalar($0)!) }
                    let scaled = ascii.filter { atlas.fitKind(text: $0) == .scaled }
                    check("点阵字体 ASCII 无一被缩放", scaled.isEmpty,
                          detail: scaled.joined())
                }
            }
        }

        // ---- SSH 主机库(v1.3):JSON 读写 + 钥匙串密码 roundtrip ----
        let sshStore = SSHHostStore.shared
        let sshTmp = NSTemporaryDirectory() + "yeterm-probe-ssh.json"
        // 装填隔离(2026-07-30 实测教训):用户真清单里已有主机时,只设
        // pathOverride 不 load(),内存里还留着真主机 → "删完应为空"之类的断言必假红
        try? FileManager.default.removeItem(atPath: sshTmp)
        let realHostsBefore = sshStore.hosts.map(\.id)
        sshStore.pathOverride = sshTmp
        sshStore.load()
        var probeHost = SSHHost()
        probeHost.name = "探针机"; probeHost.host = "10.0.0.9"
        probeHost.port = 2222; probeHost.user = "probe"; probeHost.note = "回归专用"
        sshStore.upsert(probeHost)
        sshStore.load()
        check("SSH 主机 JSON 读写", sshStore.hosts.contains {
            $0.id == probeHost.id && $0.port == 2222 && $0.name == "探针机"
        })
        check("ssh 命令组装", probeHost.sshCommand == "ssh -p 2222 probe@10.0.0.9"
                            && SSHHost(name: "", host: "h", port: 22, user: "u").sshCommand == "ssh u@h")
        // 兼容旧设备开关(老设备常只给 ssh-rsa)+ 额外参数原样拼接
        // 用例地址取 RFC 5737 文档保留段 192.0.2.0/24,不会指向任何真实主机
        let legacy = SSHHost(host: "192.0.2.10", user: "root", legacyAlgorithms: true)
        check("兼容旧设备参数组装",
              legacy.sshCommand == "ssh -o HostKeyAlgorithms=+ssh-rsa "
                  + "-o PubkeyAcceptedAlgorithms=+ssh-rsa root@192.0.2.10",
              detail: legacy.sshCommand)
        check("额外参数拼接",
              SSHHost(host: "h", user: "u", extraOptions: "-C -o ServerAliveInterval=30")
                  .sshCommand == "ssh -C -o ServerAliveInterval=30 u@h")
        // 算法自动降级(v1.3 用户追加):真实报错文本 → 兼容参数(dss 必须被滤掉,
        // 本机 ssh 已移除该算法,带上去 ssh 会以另一个错失败)
        let realErr = "Unable to negotiate with 192.0.2.10 port 22: "
            + "no matching host key type found. Their offer: ssh-rsa,ssh-dss"
        let derived = SSHConnectivity.legacyOptions(fromError: realErr)
        check("协商报错 → 兼容参数(抓对方 offer,滤掉 dss)",
              derived.contains("HostKeyAlgorithms=+ssh-rsa")
              && !derived.contains("dss")
              && derived.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"),
              detail: derived)
        check("推出的参数本机 ssh 认", SSHConnectivity.validate(options: derived))
        let kexErr = "no matching key exchange method found. "
            + "Their offer: diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"
        let kexOpts = SSHConnectivity.legacyOptions(fromError: kexErr)
        check("kex 协商报错 → KexAlgorithms 参数",
              kexOpts.contains("KexAlgorithms=+diffie-hellman-group1-sha1")
              && SSHConnectivity.validate(options: kexOpts), detail: kexOpts)
        // 折行/尾随文字场景(终端窄时报错会被拼成一整串,后面还接着提示符)
        let glued = "no matching host key type found. Their offer: ssh-rsa,ssh-dss❯ ls -la"
        let gluedOpts = SSHConnectivity.legacyOptions(fromError: glued)
        check("offer 后紧跟别的文字也只吃算法名",
              gluedOpts.contains("HostKeyAlgorithms=+ssh-rsa")
              && !gluedOpts.contains("ls") && SSHConnectivity.validate(options: gluedOpts),
              detail: gluedOpts)
        check("非协商类报错不误判",
              SSHConnectivity.legacyOptions(fromError: "Permission denied (publickey).").isEmpty)
        check("降级参数拼进命令行(选项在地址之前)",
              SSHHost(host: "h", user: "u").sshCommand(extraFlags: "-o X=y")
                  == "ssh -o X=y u@h")

        // 旧档兼容:没有新字段的 JSON 必须照读(自动 Codable 会报错,故手写解码器)
        let oldJSON = """
        [{"id":"\(UUID().uuidString)","name":"旧档","host":"1.2.3.4","port":22,\
        "user":"u","note":""}]
        """
        let decodedOld = (try? JSONDecoder().decode([SSHHost].self, from: Data(oldJSON.utf8))) ?? []
        check("旧版 ssh-hosts.json 仍可解码",
              decodedOld.first?.host == "1.2.3.4" && decodedOld.first?.legacyAlgorithms == false)
        sshStore.setPassword("probe-secret", id: probeHost.id)
        check("钥匙串密码存取", sshStore.password(id: probeHost.id) == "probe-secret")
        sshStore.remove(id: probeHost.id)
        check("删除主机连带清密码", sshStore.hosts.isEmpty && sshStore.password(id: probeHost.id) == nil)
        // 菜单栏含「服务器」菜单(动态内容打开时才生成,这里只验骨架在位)
        let menuBar = MainMenu.build(themeMenuDelegate: nil)
        // 按 identifier 找,**不能**按标题 —— 标题跟着界面语言走(i18n 后的纪律)
        check("菜单栏含服务器菜单",
              menuBar.items.contains { $0.submenu?.identifier == MainMenu.serverMenuID })
        // 「远程主机」页截图前留两台样例(空清单页文字太稀疏过不了密度阈值,
        // 且带列表才真正验到行渲染);pathOverride 仍生效 → 不碰用户真清单
        for (n, ip) in [("样例甲", "10.1.1.1"), ("样例乙", "10.1.1.2")] {
            var h = SSHHost()
            h.name = n; h.host = ip; h.user = "ops"; h.note = "探针样例"
            sshStore.upsert(h)
        }
        defer {   // 页面截完再清:pathOverride 复位 + 临时文件删除 + 真清单未污染
            sshStore.pathOverride = nil
            sshStore.load()
            try? FileManager.default.removeItem(atPath: sshTmp)
            check("真实主机清单未被探针污染", sshStore.hosts.map(\.id) == realHostsBefore)
        }

        var shots = 0
        for (id, slug) in [("CRT", "crt"), ("预设", "presets"), ("颜色", "colors"), ("字体", "fonts"), ("特效", "effects"), ("屏幕", "screen"), ("光标", "cursor"), ("终端", "terminal"), ("远程主机", "remote"), ("快捷键", "shortcuts")] {
            let hosting = NSHostingController(rootView: SettingsView(model: model, initialSectionID: id))
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 760, height: 560))
            // 补不透明底:SwiftUI 页面本身不画背景(真实设置窗底下垫的是
            // NSVisualEffectView 玻璃层),裸 hosting 捕出来大片 alpha=0 的
            // 「透明黑」——文字与背景在数值上分不开,非空白判据会误报空白
            // (2026-07-29 远程主机页 count=9 事故;同页 PNG 目检明明有内容)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.orderFront(nil)
            pump(0.8)
            guard let content = window.contentView, let rep = capture(content) else {
                check("\(id) 页截图", false)
                continue
            }
            try? write(rep, "\(outPrefix)_\(slug).png")
            shots += 1
            // 双判据:占比(内容密集页)或绝对点数(光标这类稀疏页只有细文字命中)
            let (ratio, count) = litRatio(rep)
            check("\(id) 页渲染非空白", ratio > 0.008 || count >= 40,
                  detail: String(format: "nonUniform=%.3f count=%d", ratio, count))
            window.close()
        }

        // 英文界面再渲两页(i18n):英文句子普遍比中文长,**排版炸掉是最常见的
        // i18n 事故** —— 文案页(终端)与表格页(快捷键)各取一张当回归底片。
        // 截完切回中文,免得影响后续断言。
        L10n.shared.language = .english
        for (id, slug) in [("终端", "terminal_en"), ("快捷键", "shortcuts_en")] {
            let hosting = NSHostingController(rootView: SettingsView(model: model, initialSectionID: id))
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 760, height: 560))
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.orderFront(nil)
            pump(0.8)
            guard let content = window.contentView, let rep = capture(content) else {
                check("\(id) 页英文截图", false)
                continue
            }
            try? write(rep, "\(outPrefix)_\(slug).png")
            shots += 1
            let (ratio, count) = litRatio(rep)
            check("\(id) 页英文渲染非空白", ratio > 0.008 || count >= 40,
                  detail: String(format: "nonUniform=%.3f count=%d", ratio, count))
            window.close()
        }
        L10n.shared.language = .zhHans

        print("shots=\(shots)")
        print(pass ? "SETTINGS-PROBE-PASS" : "SETTINGS-PROBE-FAIL")
        return pass ? 0 : 1
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, _ path: String) throws {
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 「非均匀度」= 与页面主色(众数)差异明显的采样点占比。
    /// 判据变迁(2026-07-26 flaky 事故):旧版数"中间调像素"(60<亮度和<720),
    /// 隐含假设深色外观(深玻璃+浅字)。系统切浅色外观后页面=白底黑字,
    /// 白底被"纯白"排除、细黑字抽样踩不中 → 正常页面误报空白。
    /// 现判据与外观无关:渲染失败=整片均匀色 → ≈0;有内容=必有像素偏离主色。
    private static func litRatio(_ rep: NSBitmapImageRep) -> (ratio: Double, count: Int) {
        guard let px = rep.bitmapData else { return (0, 0) }
        let stride = rep.bitsPerPixel / 8, rowBytes = rep.bytesPerRow
        // 采样区内缩 5%:排除窗口圆角(角区像素是透明/黑,会给"空白页"贡献假偏离)
        let x0 = rep.pixelsWide / 20, y0 = rep.pixelsHigh / 20
        // 第一遍:量化到 512 桶(每通道 3bit)找主色(= 页面背景)
        var hist = [Int](repeating: 0, count: 512)
        var samples: [(Int, Int, Int)] = []
        for y in Swift.stride(from: y0, to: rep.pixelsHigh - y0, by: 4) {
            for x in Swift.stride(from: x0, to: rep.pixelsWide - x0, by: 4) {
                let o = y * rowBytes + x * stride
                let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                hist[((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)] += 1
                samples.append((r, g, b))
            }
        }
        guard !samples.isEmpty else { return (0, 0) }
        let dominant = hist.firstIndex(of: hist.max() ?? 0) ?? 0
        let cr = ((dominant >> 6) & 7) * 32 + 16
        let cg = ((dominant >> 3) & 7) * 32 + 16
        let cb = (dominant & 7) * 32 + 16
        // 第二遍:与主色中心距离 >40 灰阶才算内容(相邻桶的背景渐变/抖动不算,
        // 免得真空白页因背景微渐变误报"有内容"—— 哨兵要往严的方向漏)
        let deviant = samples.lazy.filter {
            abs($0.0 - cr) > 40 || abs($0.1 - cg) > 40 || abs($0.2 - cb) > 40
        }.count
        return (Double(deviant) / Double(samples.count), deviant)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
