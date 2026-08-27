// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 设置窗:整个项目唯一的 SwiftUI 界面(学声明式 UI 看这里)
//
// 这个文件:项目其余 UI 都是 AppKit(命令式:new 视图、手动 addSubview),
//   唯独设置页用 SwiftUI(声明式:描述"界面长什么样",框架自己算怎么刷新)。
//   类比前端:AppKit ≈ 原生 DOM 操作,SwiftUI ≈ React/Vue ——
//   `body` 就是 render 函数,`@State` ≈ useState,`@ObservedObject` ≈
//   订阅一个外部 store(我们的 SettingsModel),数据一变 body 自动重算。
//
// 结构导览:
//   SettingsWindowController —— AppKit 窗口外壳(桌面级模糊背景在这配),
//     用 NSHostingView 把 SwiftUI 塞进 AppKit 窗口(两个世界的桥)。
//   SettingsView —— 自绘左侧导航 + 右侧按分类切换的七个 Page 子视图。
//   glassCard()/glassButton()/glassCapsule() —— macOS 26 Liquid Glass
//     系统 API 的封装(#available 做版本分支,老系统退化成磨砂材质)。
//   EffectRow —— "开关+滑杆联动"组件:关=归零并记忆旧值,开=恢复
//     (计算属性造 Binding 的手法值得细看:get/set 自定义双向绑定的语义)。
//
// 语法看点:
//   `some View` —— "不透明返回类型":返回某种 View 但不说具体是啥
//     (SwiftUI 的视图类型嵌套极深,写不出来也不需要写)。
//   ViewBuilder 的链式修饰符 `.padding().background()` —— 每个修饰符都
//     包一层新视图,顺序有讲究(先 padding 再背景 ≠ 先背景再 padding)。
//   `@State private var query = ""` —— 视图私有状态,变了只刷新用到它的部分。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗(M3 重写版):左侧导航分类 + 液态玻璃卡片 + 特效启用开关 +
/// 字体独立导航页(系统全部字体 + crterm 内置复古字体,模糊搜索)。
/// 全系统组件,实时预览,自动写盘。⌘, 打开;由 AppDelegate 持有单例。
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    /// 留住 SwiftUI 宿主视图:show(sectionID:) 换根视图实现"直达某页"
    private let hosting: NSHostingView<SettingsView>

    init(model: SettingsModel) {
        self.model = model
        FontLibrary.registerBundledFonts()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("YeTerm 设置")
        window.titlebarAppearsTransparent = true
        // 背景拖动必须关:SwiftUI 滑杆的拖动会被窗口拖动抢走(用户实测「没法滑」)
        window.isMovableByWindowBackground = false
        // Liquid Glass 前提:窗口透出桌面 —— 整窗铺 behind-window 桌面模糊,
        // 玻璃组件叠其上才有折射/高光的「液态」质感(磨砂材质垫死则无从谈起)
        window.isOpaque = false
        window.backgroundColor = .clear
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        self.hosting = hosting
        window.contentView = blur
        window.minSize = NSSize(width: 640, height: 460)
        // 记住位置(跨启动恢复;程序化建窗需手动 setFrameUsingName 触发恢复)
        window.setFrameAutosaveName("YeTermSettingsWindow")
        window.setFrameUsingName("YeTermSettingsWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 直达指定导航页(菜单「管理服务器…」等入口用;sectionID = 导航项中文名)
    func show(sectionID: String) {
        hosting.rootView = SettingsView(model: model, initialSectionID: sectionID)
        show()
    }
}

// MARK: - 液态玻璃卡片(macOS 26+ 用系统 Liquid Glass,旧系统退化为材质)

private extension View {
    @ViewBuilder func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            self
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Liquid Glass 按钮(macOS 26 系统样式;旧系统退化 bordered)
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Liquid Glass 胶囊容器(搜索框等;两侧半圆,系统同款)
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}

// MARK: - 导航分类

private enum SettingsSection: String, CaseIterable, Identifiable {
    case crt = "CRT"
    case presets = "预设"
    case colors = "颜色"
    case fonts = "字体"
    case screen = "屏幕"
    case effects = "特效"
    case cursor = "光标"
    case terminal = "终端"
    case remote = "远程主机"
    case shortcuts = "快捷键"
    case files = "配置文件"

    var id: String { rawValue }

    /// 侧栏上显示的名字。**rawValue 是稳定标识符,不能跟着界面语言变** ——
    /// `show(sectionID:)`(菜单「管理服务器…」直达)和探针逐页截图都按它取页。
    /// i18n 的通用做法:身份与显示分家,显示才过翻译层。
    var title: String { L(rawValue) }

    var icon: String {
        switch self {
        case .crt: return "tv"
        case .presets: return "square.grid.2x2"
        case .colors: return "paintpalette"
        case .fonts: return "f.cursive"   // 勿用 textformat:中文环境本地化渲染成「格式」二字
        case .screen: return "display"
        case .effects: return "sparkles"
        case .cursor: return "cursorarrow.rays"
        case .terminal: return "terminal"
        case .remote: return "network"
        case .shortcuts: return "keyboard"
        case .files: return "folder"
        }
    }

    /// 导航显隐(v1.2 用户裁决):CRT 开=全量;关=隐藏特效/屏幕(CRT 专属旋钮)。
    /// 「预设」始终可见 —— 预设包含 CRT 开关状态(用户可存多套"普通终端"配置
    /// 互相切换;点内置 CRT 预设即切回 CRT 模式)。颜色页两种模式各一套内容。
    static func visible(crtOn: Bool) -> [SettingsSection] {
        crtOn ? allCases
              : [.crt, .presets, .fonts, .colors, .cursor, .terminal, .remote, .shortcuts, .files]
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 订阅翻译层:语言一变,整个设置页的 body 重算 → 所有 `L(...)` 重新取值。
    /// 【学】这就是"热切换"的全部秘密 —— 不用手动去改每个 Text,
    ///   声明式 UI 只要数据源变了就自己重画(类比 React 里 context 变更触发重渲染)。
    ///   下面各子页(TerminalPage / ColorsPage …)都是在本 body 里 new 出来的,
    ///   所以它们也跟着一起重建,无需各自订阅。
    @ObservedObject private var l10n = L10n.shared
    @State private var section: SettingsSection

    /// `initialSectionID`:探针逐页截图用(取值 = 导航项中文名;默认「预设」)
    init(model: SettingsModel, initialSectionID: String = "预设") {
        self.model = model
        _section = State(initialValue: SettingsSection(rawValue: initialSectionID) ?? .presets)
    }

    var body: some View {
        // 自绘侧栏(弃 NavigationSplitView:其自带不透明底会垫死玻璃层)——
        // 整窗透着 behind-window 桌面模糊,玻璃卡片/导航项浮在其上。
        // 分类随 CRT 总开关显隐(v1.2 用户裁决);当前页被藏起时自动跳「CRT」页
        let visible = SettingsSection.visible(crtOn: model.crtEffectsEnabled)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible) { s in
                    SidebarItem(section: s, selected: section == s) { section = s }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 40)          // 透明标题栏区域
            .frame(width: 170)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .crt: CRTPage(model: model)
                    case .presets: PresetsPage(model: model)
                    case .colors:
                        if model.crtEffectsEnabled {
                            ColorsPage(model: model)
                        } else {
                            PlainColorsPage(model: model)
                        }
                    case .fonts: FontsPage(model: model)
                    case .screen: ScreenPage(model: model)
                    case .effects: EffectsPage(model: model)
                    case .cursor: CursorPage(model: model)
                    case .terminal: TerminalPage(model: model)
                    case .remote: RemotePage()
                    case .shortcuts: ShortcutsPage(model: model)
                    case .files: FilesPage(model: model)
                    }
                }
                .padding(20)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: model.crtEffectsEnabled) { _, on in
            if !SettingsSection.visible(crtOn: on).contains(section) {
                section = .crt
            }
        }
    }
}

/// 侧栏导航项:选中态 = Liquid Glass 胶囊
private struct SidebarItem: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(section.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SidebarGlass(selected: selected))
    }
}

private struct SidebarGlass: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), selected {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        } else if selected {
            content.background(.selection, in: RoundedRectangle(cornerRadius: 8))
        } else {
            content
        }
    }
}

// MARK: - 通用小组件

/// 滑杆行:标题 + 系统滑杆 + 等宽数值。
/// 滑杆/开关的 Liquid Glass 外观由系统自动提供 —— 前提是二进制链接 SDK ≥26
/// (Package.swift 部署目标钉 15 时全 app 被按旧 app 兼容渲染,实测教训;
/// 勿再自绘控件仿制)。
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: String = "%.2f"

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 92, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// 特效行:启用开关 + 滑杆联动(关=0 并记忆旧值,开=恢复记忆或默认)
private struct EffectRow: View {
    let title: String
    @Binding var value: Double
    let stashKey: String
    let defaultOn: Double
    var range: ClosedRange<Double> = 0...1
    @ObservedObject var model: SettingsModel

    private var enabled: Binding<Bool> {
        Binding(
            get: { value > 0 },
            set: { on in
                if on {
                    value = model.effectStash[stashKey] ?? defaultOn
                } else {
                    if value > 0 { model.effectStash[stashKey] = value }
                    value = 0
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: enabled) { Text(title).frame(width: 76, alignment: .leading) }
                .toggleStyle(.switch)
                .controlSize(.mini)
            Slider(value: $value, in: range)
                .disabled(value <= 0)
                .opacity(value > 0 ? 1 : 0.4)
            Text(String(format: "%.2f", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private func pageTitle(_ t: String, _ sub: String = "") -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(t).font(.title2.bold())
        if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
    }
}

/// Color → "#rrggbb"(普通颜色页 ANSI 网格用)
private func hexFromColor(_ color: Color) -> String {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
    return String(format: "#%02x%02x%02x",
                  Int(round(ns.redComponent * 255)),
                  Int(round(ns.greenComponent * 255)),
                  Int(round(ns.blueComponent * 255)))
}

private func colorFromHex(_ hex: String) -> Color {
    var s = hex
    if s.hasPrefix("#") { s = String(s.dropFirst()) }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
    return Color(red: Double((v >> 16) & 0xff) / 255,
                 green: Double((v >> 8) & 0xff) / 255,
                 blue: Double(v & 0xff) / 255)
}

// MARK: - CRT 总开关页(v1.2 用户裁决:独立分类,开关 + 简介教程;
// 开关同时控制左侧其它分类的显隐)

private struct CRTPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle("CRT")

        // 经典 CRT 主题锁定(v1.2 补丁用户裁决):设备还原主题不可关特效
        let locked = model.crtEffectsEnabled && Presets.isClassicCRT(model.presetName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $model.crtEffectsEnabled) {
                    Text(L("CRT 复古特效")).font(.title3.bold())
                }
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(locked)
                Spacer()
                Text(L("快捷键 ⌘E"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if locked {
                Text(Lf("「%@」是真实设备还原主题,CRT 特效不可关闭 —— 想要素净观感请选「经典配色」组主题(它们关掉特效后仍保留各自配色),或自建配置。", Presets.displayName(model.presetName)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()

        VStack(alignment: .leading, spacing: 10) {
            Text(model.crtEffectsEnabled ? L("当前:复古显像管模式") : L("当前:普通终端模式"))
                .font(.callout.bold())
            Text(model.crtEffectsEnabled
                 ? L("画面按老 CRT 显示器拟真:荧光染色、扫描线、屏幕弧度、辉光、雪花噪点、磷光余辉、机壳边框全套生效。左侧的「预设 / 颜色 / 特效 / 屏幕」分类都是这套观感的调节旋钮。")
                 : L("画面是干净的现代终端:无弧度、无扫描线、无机壳,文字颜色精确直出。左侧保留「预设 / 字体 / 颜色 / 光标 / 终端」等通用设置;颜色系统与 CRT 模式相互独立(仿 macOS 自带终端:文字色、背景色、ANSI 16 色逐一可调)。CRT 开关会跟随预设:把当前普通终端状态「复制当前」存成配置,以后一点即回;点任何内置 CRT 预设则切回复古模式。"))
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()

    }
}

// MARK: - 普通终端颜色页(v1.2:CRT 关时的独立颜色系统,仿 Terminal.app)

private struct PlainColorsPage: View {
    @ObservedObject var model: SettingsModel
    private let ansiNames = [L("黑"), L("红"), L("绿"), L("黄"), L("蓝"), L("品红"), L("青"), L("白")]

    private func colorCell(_ title: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 10) {
            Text(title)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.35)
        }
        .frame(maxWidth: .infinity)
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { colorFromHex(hex.wrappedValue) },
            set: { hex.wrappedValue = hexFromColor($0) }
        )
    }

    var body: some View {
        pageTitle(L("颜色"), L("普通终端模式配色(与 CRT 模式互不影响)"))

        HStack(spacing: 0) {
            colorCell(L("文字颜色"), hexBinding($model.plainTextColorHex))
            Divider().opacity(0.25).padding(.vertical, 4)
            colorCell(L("背景色"), hexBinding($model.plainBackgroundColorHex))
        }
        .glassCard()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("ANSI 颜色")).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button(L("还原默认")) {
                    model.plainAnsiHex = AnsiColor.terminalAppAnsiHex
                }
                .glassButton()
                .controlSize(.small)
            }
            // 两行:普通 0-7 / 明亮 8-15(Terminal.app 同款布局)
            ForEach([0, 8], id: \.self) { base in
                HStack(spacing: 10) {
                    Text(base == 0 ? L("普通") : L("明亮"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)
                    ForEach(0..<8, id: \.self) { i in
                        VStack(spacing: 2) {
                            ColorPicker("", selection: Binding(
                                get: { colorFromHex(model.plainAnsiHex[base + i]) },
                                set: { model.plainAnsiHex[base + i] = hexFromColor($0) }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            Text(ansiNames[i]).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .glassCard()

        SelectionColorCard(model: model, crtMode: false)

        BackgroundImageCard(model: model, crtMode: false)
    }
}

// MARK: - 选中高亮卡片(2026-08-27;CRT/普通两个颜色页共用)

/// 选区配色跟着预设走(用户裁决「每个预设不同,可玩性更高」),两种模式共用
/// 同一份设置,故与 BackgroundImageCard 同款做法:一张卡片挂两个颜色页。
/// 反色(缺省)= 选中格前景/背景互换 = 历史行为;自定义 = 指定选中底色,
/// 文字颜色不设置则保留每格原本的颜色(只换底,ls 彩色/语法高亮不被抹平)。
private struct SelectionColorCard: View {
    @ObservedObject var model: SettingsModel
    /// true = 挂在 CRT 颜色页(补一句"会被荧光染色"的说明);false = 普通模式颜色页
    var crtMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("选中高亮")).font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: $model.selectionColorMode) {
                Text(L("反色")).tag(0)
                Text(L("自定义")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.selectionColorMode == 1 {
                HStack(spacing: 0) {
                    colorCell(L("选中背景色"), bgBinding)
                    Divider().opacity(0.25).padding(.vertical, 4)
                    colorCell(L("选中文字颜色"), fgBinding)
                }
                HStack(alignment: .top) {
                    Text(model.selectionTextColorHex == nil
                         ? L("文字颜色未设置:选中时保留每个字符原本的颜色,只换底色。")
                         : L("文字颜色已设置:选中范围内的文字统一用这个颜色。"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.selectionTextColorHex != nil {
                        Button(L("保留原色")) { model.selectionTextColorHex = nil }
                            .glassButton()
                            .controlSize(.small)
                    }
                }
            }
            if model.selectionColorMode == 0 {
                Text(L("反色 = 选中处前景/背景互换,复古终端的经典行为。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if crtMode {
                Text(L("CRT 模式下选中颜色同样经过荧光染色与白热化;色彩浓度低的单色主题只体现明暗,选不出色相。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()
    }

    /// 对称色格(与两个颜色页的 colorCell 同款,卡片自带一份避免跨结构体引用)
    private func colorCell(_ title: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 10) {
            Text(title)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.35)
        }
        .frame(maxWidth: .infinity)
    }

    private func hexToBinding(_ get: @escaping () -> String,
                              _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding<Color>(
            get: { colorFromHex(get()) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                set(String(format: "#%02x%02x%02x",
                           Int(round(ns.redComponent * 255)),
                           Int(round(ns.greenComponent * 255)),
                           Int(round(ns.blueComponent * 255))))
            }
        )
    }

    private var bgBinding: Binding<Color> {
        hexToBinding({ model.selectionBgColorHex }, { model.selectionBgColorHex = $0 })
    }

    /// 文字颜色绑定:nil(保留原色)状态下显示当前模式的默认文字色,写入即物化
    private var fgBinding: Binding<Color> {
        hexToBinding({
            model.selectionTextColorHex
                ?? (crtMode ? (model.crtTextColorHex ?? "#ffffff") : model.plainTextColorHex)
        }, { model.selectionTextColorHex = $0 })
    }
}

// MARK: - 背景图片卡片(v1.2 #16;v1.5.1 起 CRT 模式共用)

/// 两种模式共用同一份背景图设置(同一张图、同一套一次性预处理特效),所以这张卡片
/// 被普通模式颜色页和 CRT 颜色页各挂一份。差别只有两处:
///   ① CRT 模式多一个「荧光染色」开关(把图染成磷光单色 = 真 CRT 在显示这张图);
///   ② CRT 模式下内置「经典 CRT」组的设备还原主题整块禁用(用户裁决 2026-07-31,
///      与 CRTPage 里"这组不可关特效"是同一条产品逻辑,提示语也照同一套写法)。
private struct BackgroundImageCard: View {
    @ObservedObject var model: SettingsModel
    /// true = 挂在 CRT 颜色页(多染色开关 + 经典 CRT 锁定);false = 普通模式颜色页
    var crtMode: Bool

    private var lockedByClassicDevice: Bool {
        crtMode && Presets.isClassicCRT(model.presetName)
    }

    /// 当前选的是动图/视频(v1.5.2):按扩展名判定,与 PlainBackground.SourceKind 同一套
    private var isAnimatedSource: Bool {
        let ext = (model.plainBackgroundImagePath as NSString).pathExtension.lowercased()
        return ["gif", "mp4", "mov", "m4v"].contains(ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("背景图片")).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !model.plainBackgroundImagePath.isEmpty {
                    Button(L("清除")) { model.plainBackgroundImagePath = "" }
                        .glassButton()
                        .controlSize(.small)
                }
                Button(L("选择图片/视频…")) {
                    // 【学】NSOpenPanel = macOS 系统文件选择对话框(类比 <input type=file>);
                    //      runModal() 同步弹窗等用户选完,.OK 表示点了"打开"。
                    //      .image 已含 GIF;.movie 放行 mp4/mov/m4v(v1.5.2 动态背景)
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .movie]
                    panel.allowsMultipleSelection = false
                    panel.message = L("选择终端背景图片或视频")
                    if panel.runModal() == .OK, let url = panel.url {
                        model.plainBackgroundImagePath = url.path
                    }
                }
                .glassButton()
                .controlSize(.small)
            }
            .disabled(lockedByClassicDevice)
            .opacity(lockedByClassicDevice ? 0.5 : 1)

            if lockedByClassicDevice {
                Text(Lf("「%@」是真实设备还原主题,不铺背景图 —— 它还原的是一台具体的老机器,屏幕后面贴张壁纸就不是那台机器了。想给 CRT 屏配背景图请选「经典配色」组主题,或自建配置。", Presets.displayName(model.presetName)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.plainBackgroundImagePath.isEmpty {
                Text(L("未设置 —— 背景为上方的纯背景色。壁纸跟着预设走,每个预设可各配一张。"))
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text((model.plainBackgroundImagePath as NSString).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if isAnimatedSource {
                    // 动图/视频专属(v1.5.2):取帧上限挡位 —— 限的是上屏节奏,
                    // 越低越省电;视频恒静音,窗口被遮挡/最小化自动暂停
                    Picker(L("动画帧率"), selection: $model.plainBackgroundAnimFPS) {
                        Text("15 fps").tag(15)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Text(L("背景动画的帧率上限,越低越省电;视频恒静音播放。"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("", selection: $model.plainBackgroundImageMode) {
                    Text(L("无变化")).tag(0)
                    Text(L("毛玻璃")).tag(1)
                    Text(L("像素风")).tag(2)
                    Text(L("暗化")).tag(3)
                    Text(L("黑白胶片")).tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.plainBackgroundImageMode == 1 {
                    // 毛玻璃专属:模糊强度(用户追加;松手后按新强度一次性重算缓存)
                    SliderRow(title: L("模糊强度"), value: $model.plainBackgroundBlur)
                }
                if model.plainBackgroundImageMode == 3 {
                    // 暗化专属:程度滑块(0=原图/0.5=旧固定观感 ×0.35/1=全黑;
                    // 松手后按新程度一次性重算缓存,同毛玻璃的模糊强度)
                    SliderRow(title: L("暗化程度"), value: $model.plainBackgroundDarken)
                }
                if model.plainBackgroundImageMode == 2 {
                    // 像素风专属:复古调色板(v2;像素画社区公开标准调色板)
                    Picker(L("调色板"), selection: $model.plainBackgroundPixelPalette) {
                        Text(L("PICO-8 鲜艳")).tag(0)
                        Text(L("DB16 沉稳")).tag(1)
                        Text(L("GameBoy 绿")).tag(2)
                        Text(L("原色")).tag(3)
                    }
                    .pickerStyle(.segmented)
                }
                if crtMode {
                    // 荧光染色(v1.5.1 用户裁决:两种观感都留着,缺省保留原色)
                    Toggle(isOn: $model.crtBackgroundImageChroma) {
                        Text(L("荧光染色"))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(model.crtBackgroundImageChroma
                         ? L("开:整张图被染成磷光单色、跟着吃扫描线 —— 像这台老显示器正在显示这张图。")
                         : L("关:图片保留原色,只当屏幕底图;磷光文字照常发光浮在它上面,不会被图洗掉。"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(crtMode
                     ? L("特效在选图时一次性处理成缓存,不增加每帧渲染负担;图片跟着屏幕弧度一起鼓、被机壳裁切。暗化 / 黑白胶片会把图片压暗,文字浮在上面更好读。")
                     : L("特效在选图时一次性处理成缓存,不增加每帧渲染负担;暗化 / 黑白胶片会把图片压暗,文字浮在上面更好读。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()
    }
}

// MARK: - 预设页

private struct PresetsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var showNameSheet = false
    @State private var newName = ""
    @State private var confirmDelete = false
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        pageTitle(L("预设"))

        // 操作行:新建/复制(以当前设置为底)+ 还原默认(系统预设)/删除(用户配置)
        HStack(spacing: 10) {
            Button { newName = ""; showNameSheet = true } label: {
                Label(L("新建"), systemImage: "plus")
            }
            .glassButton()
            Button { newName = Lf("%@ 副本", Presets.displayName(model.presetName)); showNameSheet = true } label: {
                Label(L("复制当前"), systemImage: "doc.on.doc")
            }
            .glassButton()
            if model.isBuiltin(model.presetName) {
                Button { model.resetBuiltinToDefault() } label: {
                    Label(L("还原默认"), systemImage: "arrow.counterclockwise")
                }
                .glassButton()
            } else {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("删除"), systemImage: "trash")
                }
                .glassButton()
            }
        }

        Text(L("系统预设不可删除;修改任意参数后可随时「还原默认」。悬停或选中查看每套的出处简介。"))
            .font(.caption).foregroundStyle(.tertiary)

        // 系统预设分组展示(v1.2 扩容至 33 套:经典 CRT/复古设备/经典配色/私人收藏)。
        // 简介**就地显示**在选中项所在分组卡内(用户反馈:放页顶要来回翻,体验差)
        ForEach(Presets.groups, id: \.title) { group in
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title)
                    .font(.caption.bold()).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(group.names, id: \.self) { name in
                        PresetChip(name: name, cfg: model.storedConfig(named: name),
                                   selected: model.presetName == name) {
                            model.loadPreset(name)
                        }
                        .help(Presets.blurb(name) ?? name)   // 【学】.help = 悬停 tooltip
                    }
                }
                // 选中项属于本组 → 简介直接出现在网格下方,视线不用离开点击处
                if group.names.contains(model.presetName),
                   let blurb = Presets.blurb(model.presetName) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.tint)
                            .padding(.top, 2)
                        Text(blurb)
                            .font(.body)   // 正文字号(用户反馈 caption 太小)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)   // 【学】允许换行撑高
                    }
                    .padding(.top, 2)
                }
            }
            .glassCard()
        }

        VStack(alignment: .leading, spacing: 8) {
            Text(L("我的配置"))
                .font(.caption.bold()).foregroundStyle(.secondary)
            if model.userProfileNames.isEmpty {
                Text(L("还没有自定义配置 —— 选中任意系统预设调整后,点「复制当前」保存为你自己的。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.userProfileNames, id: \.self) { name in
                        PresetChip(name: name, cfg: model.storedConfig(named: name),
                                   selected: model.presetName == name) {
                            model.loadPreset(name)
                        }
                    }
                }
            }
        }
        .glassCard()

        // 命名弹窗(新建/复制共用;名称全局查重)
        Text("").hidden()
        .sheet(isPresented: $showNameSheet) {
            VStack(spacing: 14) {
                Text(L("配置名称")).font(.headline)
                TextField(L("名称"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                if !newName.trimmingCharacters(in: .whitespaces).isEmpty && !model.nameAvailable(newName) {
                    Text(L("名称已存在(系统预设与用户配置不可重名)"))
                        .font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    Button(L("取消")) { showNameSheet = false }
                    Button(L("创建")) {
                        if model.createProfile(named: newName) {
                            showNameSheet = false
                            newName = ""
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.nameAvailable(newName))
                }
            }
            .padding(24)
        }
        .confirmationDialog(Lf("删除配置「%@」?", Presets.displayName(model.presetName)), isPresented: $confirmDelete) {
            Button(L("删除"), role: .destructive) { model.deleteProfile(named: model.presetName) }
            Button(L("取消"), role: .cancel) {}
        }
    }
}

private struct PresetChip: View {
    let name: String
    let cfg: CRTConfig?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorFromHex(cfg?.backgroundColor ?? "#000000"))
                        .frame(width: 26, height: 18)
                    Text("A")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(colorFromHex(cfg?.fontColor ?? "#00ff00"))
                }
                Text(Presets.displayName(name)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 颜色页

private struct ColorsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle(L("颜色"))
        HStack(spacing: 0) {
            colorCell(L("前景色(荧光)"), hexBinding($model.fontColorHex))
            Divider().opacity(0.25).padding(.vertical, 4)
            colorCell(L("背景色"), hexBinding($model.backgroundColorHex))
            Divider().opacity(0.25).padding(.vertical, 4)
            // 文字颜色(2026-08-03:CRT 模式默认前景覆盖,DIY 配置用;
            // 经典 CRT 组锁定纯白,与背景图卡片同一条产品逻辑)
            colorCell(L("文字颜色"), crtTextBinding)
                .disabled(classicLocked)
                .opacity(classicLocked ? 0.5 : 1)
        }
        .glassCard()
        if classicLocked {
            Text(Lf("「%@」是真实设备还原主题,文字颜色固定纯白 —— 纯白经荧光染色输出纯磷光色,是这组考据观感的前提。想自定义文字颜色请选「经典配色」组主题,或自建配置。", Presets.displayName(model.presetName)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top) {
                Text(L("文字颜色只作用于无颜色指令的普通输出,ANSI 彩色不受影响;色彩浓度低时会被荧光染成前景色,仅亮度生效。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.crtTextColorHex != nil {
                    Button(L("还原纯白")) { model.crtTextColorHex = nil }
                        .glassButton()
                        .controlSize(.small)
                }
            }
        }
        VStack(spacing: 10) {
            SliderRow(title: L("亮度"), value: $model.brightness)
            SliderRow(title: L("对比度"), value: $model.contrast)
            SliderRow(title: L("饱和度"), value: $model.saturation)
            SliderRow(title: L("色彩浓度"), value: $model.chroma)
        }
        .glassCard()
        Text(L("色彩浓度 = 0 时为纯单色荧光屏;= 1 时保留终端原色。"))
            .font(.caption).foregroundStyle(.secondary)

        // ---- ANSI 16 色(v1.2 预设大更新):CRT 模式也可定制终端 16 基色 ----
        // nil = crterm 专属调色板(内置经典 CRT 主题的荧光考据观感);
        // 经典配色预设自带官方表;用户一改即物化为自定义
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("ANSI 颜色")).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if model.ansiColorsHex != nil {
                    Button(L("还原专属调色板")) { model.ansiColorsHex = nil }
                        .glassButton()
                        .controlSize(.small)
                }
            }
            ForEach([0, 8], id: \.self) { base in
                HStack(spacing: 10) {
                    Text(base == 0 ? L("普通") : L("明亮"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)
                    ForEach(0..<8, id: \.self) { i in
                        VStack(spacing: 2) {
                            ColorPicker("", selection: ansiBinding(base + i), supportsOpacity: false)
                                .labelsHidden()
                            Text(ansiNames[i]).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
            }
            Text(model.ansiColorsHex == nil
                 ? L("当前:crterm 专属调色板(亮青=奶油白等荧光考据色)。修改任一色即成为自定义配色;色彩浓度低时 ANSI 色会被荧光染色。")
                 : L("当前:自定义 ANSI 表(经典配色主题自带官方色)。「还原专属调色板」回到 crterm 荧光考据色。"))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()

        // 选中高亮(2026-08-27:与普通模式共用同一份设置,跟着预设走)
        SelectionColorCard(model: model, crtMode: true)

        // 背景图片(v1.5.1:CRT 模式也能铺;与普通模式共用同一份设置)
        BackgroundImageCard(model: model, crtMode: true)
    }

    private let ansiNames = [L("黑"), L("红"), L("绿"), L("黄"), L("蓝"), L("品红"), L("青"), L("白")]

    /// ANSI 单色绑定:nil(专属调色板)状态下读显示默认色,写入时先物化整表
    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding<Color>(
            get: { colorFromHex((model.ansiColorsHex ?? AnsiColor.crtBasic16Hex)[i]) },
            set: { color in
                var table = model.ansiColorsHex ?? AnsiColor.crtBasic16Hex
                table[i] = hexFromColor(color)
                model.ansiColorsHex = table
            }
        )
    }

    /// 对称色格:标题在上、色块在下,各占一半
    private func colorCell(_ title: String, _ binding: Binding<Color>) -> some View {
        VStack(spacing: 10) {
            Text(title)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.35)
        }
        .frame(maxWidth: .infinity)
    }

    /// 经典 CRT 组文字颜色锁定(判定按预设名,同 BackgroundImageCard)
    private var classicLocked: Bool { Presets.isClassicCRT(model.presetName) }

    /// 文字颜色绑定:nil(纯白缺省)状态下显示白,写入时物化 hex
    private var crtTextBinding: Binding<Color> {
        Binding<Color>(
            get: { colorFromHex(model.crtTextColorHex ?? "#ffffff") },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                model.crtTextColorHex = String(format: "#%02x%02x%02x",
                                               Int(round(ns.redComponent * 255)),
                                               Int(round(ns.greenComponent * 255)),
                                               Int(round(ns.blueComponent * 255)))
            }
        )
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { colorFromHex(hex.wrappedValue) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .green
                hex.wrappedValue = String(format: "#%02x%02x%02x",
                                          Int(round(ns.redComponent * 255)),
                                          Int(round(ns.greenComponent * 255)),
                                          Int(round(ns.blueComponent * 255)))
            }
        )
    }
}

// MARK: - 字体页(独立导航:全部系统字体 + crterm 复古字体,模糊搜索)

private struct FontsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var query = ""

    var body: some View {
        pageTitle(L("字体"))
        VStack(spacing: 10) {
            SliderRow(title: L("字号"), value: $model.fontSize, range: 8...32, format: "%.0f")
            SliderRow(title: L("字宽"), value: $model.fontWidth, range: 0.5...1.5)
        }
        .glassCard()

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("模糊搜索字体(如 mpl → Maple Mono)"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCapsule()

        // .equatable():query/选中没变就整卡跳过重算 —— 拖上面的字号滑块
        // (model 任意字段广播)不再触发整表 diff
        FontListCard(query: query, selected: model.fontName) { model.fontName = $0 }
            .equatable()
    }
}

/// 字体列表卡(2026-07-28 用户实测「字体多卡顿 / 卡片背景偶发消失」勘差,三件套):
/// ① Equatable 隔离:只有搜索词/选中字体变化才重算列表;
/// ② **固定高度 + 内部滚动 + LazyVStack**:此前整表撑开玻璃卡,几百字体高达
///    上万像素 —— Liquid Glass 材质在超高视图上偶发整块渲染失败,即"背景
///    消失"的根因;固定高度后材质尺寸恒定,且只实例化可见的十几行;
/// ③ 字体探测走 FontLibrary 进程级缓存(此前每次进页重探全部字体)。
private struct FontListCard: View, Equatable {
    let query: String
    let selected: String
    let onPick: (String) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.query == b.query && a.selected == b.selected
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    var body: some View {
        let all = FontLibrary.cachedAllFamilies
        let monoFamilies = FontLibrary.cachedMonoFamilies
        let iconFamilies = FontLibrary.cachedIconFamilies
        // 内置字体的 display 是中文源文(见 FontLibrary 的说明),显示与搜索都在这里过翻译层
        let retro = FontLibrary.retroFamilies.filter {
            FontLibrary.fuzzyMatch(query, $0.family)
                || FontLibrary.fuzzyMatch(query, $0.display)
                || FontLibrary.fuzzyMatch(query, L($0.display))
        }
        let retroSet = Set(FontLibrary.retroFamilies.map(\.family))
        // 三分区:复古(内置)→ 图标字体(Nerd Fonts,按字形探测归类)→ 其余系统字体
        let icon = all.filter {
            !retroSet.contains($0) && iconFamilies.contains($0) && FontLibrary.fuzzyMatch(query, $0)
        }
        let system = all.filter {
            !retroSet.contains($0) && !iconFamilies.contains($0) && FontLibrary.fuzzyMatch(query, $0)
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !retro.isEmpty {
                    header(L("复古字体(内置)"))
                    ForEach(retro, id: \.family) { f in
                        FontRow(family: f.family, note: L(f.display), mono: true,
                                selected: selected == f.family) { onPick(f.family) }
                    }
                    Divider().padding(.vertical, 6)
                }
                if !icon.isEmpty {
                    header(Lf("图标字体(%d)— 内置 Powerline/Nerd 图标,p10k 主题图标全", icon.count))
                    ForEach(icon, id: \.self) { family in
                        FontRow(family: family, note: nil, mono: monoFamilies.contains(family),
                                selected: selected == family) { onPick(family) }
                    }
                    Divider().padding(.vertical, 6)
                }
                header(Lf("系统字体(%d)", system.count))
                ForEach(system, id: \.self) { family in
                    FontRow(family: family, note: nil, mono: monoFamilies.contains(family),
                            selected: selected == family) { onPick(family) }
                }
            }
        }
        .frame(height: 360)
        .glassCard()
    }
}

private struct FontRow: View {
    let family: String
    let note: String?
    let mono: Bool
    let selected: Bool
    let action: () -> Void

    // 行内预览字体缓存(卡顿勘差):每次重建行都现场 NSFont(name:) 是列表里
    // 最贵的单笔开销,同一 family 只解析一次(主线程独占访问,无并发问题)
    private static var previewCache: [String: Font] = [:]
    private static func previewFont(_ family: String) -> Font {
        if let f = previewCache[family] { return f }
        let f = Font(NSFont(name: family, size: 13) ?? .systemFont(ofSize: 13))
        previewCache[family] = f
        return f
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                Text(family)
                    .font(Self.previewFont(family))
                    .lineLimit(1)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if mono {
                    Text(L("等宽"))
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 屏幕页

private struct ScreenPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle(L("屏幕"))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("光栅化")).frame(width: 92, alignment: .leading)
                Picker("", selection: $model.rasterization) {
                    Text(L("无")).tag(0)
                    Text(L("扫描线")).tag(1)
                    Text(L("像素")).tag(2)
                    Text(L("子像素")).tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            EffectRow(title: L("屏幕弧度"), value: $model.curvature, stashKey: "curvature",
                      defaultOn: 0.3, model: model)
            // 机壳边框开关(2026-07-28 用户实测:此前机壳恒开、四角暗角无处可关)。
            // 屏幕弧度>0 时强制开+灰掉(2026-08-06 用户裁决,与 CRTConfig.apply 的
            // frameOn 联动同一条规则):开关**显示**为开但不改 frameEnabled 存值,
            // 弧度归零后恢复用户原选择。
            // 【学】Binding(get:set:) 是手写的"计算属性版"双向绑定:显示值可以和
            //      存储值不同(这里 get 把弧度锁定叠加进去),类比 Vue 的 computed
            //      带 getter/setter。
            HStack {
                Text(L("机壳边框")).frame(width: 92, alignment: .leading)
                Toggle("", isOn: Binding(
                    get: { model.frameEnabled || model.curvature > 0 },
                    set: { model.frameEnabled = $0 }
                ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.curvature > 0)
                Text(model.curvature > 0
                     ? L("屏幕弧度开启时机壳自动开启(弧形四角需要机壳包边)")
                     : L("四角暗角、屏内边缘阴影与机壳反射"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            // 盒绘标签条样式(2026-08-07 用户需求:五款可选、跟着预设走;
            // 只作用于机壳模式的字符标签条,玻璃条不受影响)
            HStack {
                Text(L("标签栏样式")).frame(width: 92, alignment: .leading)
                Picker("", selection: $model.crtTabBarStyle) {
                    Text(L("直角框")).tag(0)
                    Text(L("圆角框")).tag(1)
                    Text(L("极简块")).tag(2)
                    Text(L("胶囊块")).tag(3)
                    Text(L("下划线")).tag(4)
                    Text(L("翻页卡")).tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(L("机壳模式多标签的字符标签条"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L("分屏分割线")).frame(width: 92, alignment: .leading)
                Picker("", selection: $model.dividerStyle) {
                    Text(L("实线")).tag(0)
                    Text(L("虚线段")).tag(1)
                    Text(L("点线")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // 刷新率挡(v1.1 #3):30 帧省电、60 帧顺滑;低电量模式下运行时自动压 30
            HStack {
                Text(L("刷新率")).frame(width: 92, alignment: .leading)
                Picker("", selection: $model.refreshRate) {
                    Text(L("30(省电)")).tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                    Text(L("跟随显示器")).tag(0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(L("上限由显示器决定:60Hz 屏上选 120 也只能跑 60。低电量模式自动降为 30"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard()
        VStack(spacing: 10) {
            SliderRow(title: L("留白"), value: $model.margin)
            SliderRow(title: L("窗口不透明度"), value: $model.windowOpacity)
        }
        .glassCard()
    }
}

// MARK: - 特效页(启用开关 + 滑杆联动)

private struct EffectsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle(L("特效"), L("开关即启用/禁用;重新启用会恢复上次的强度"))
        // CRT 总开关(v1.2 用户追加):关 = 普通终端模式
        HStack(spacing: 10) {
            Toggle(isOn: $model.crtEffectsEnabled) {
                Text(L("CRT 特效")).font(.callout.bold()).frame(width: 76, alignment: .leading)
            }
            .toggleStyle(.switch)
            Text(L("总开关(⌘E)。关闭 = 当成普通终端用:原生文字渲染,仅字体与前景/背景色生效"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .glassCard()
        // ── 文字发光(v1.4 按用户提的拆分重组:两半是两回事,放一起才好调)──
        VStack(spacing: 8) {
            Text(L("文字发光")).font(.callout.bold()).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("拆成两半独立调:**白热化** = 笔画自己被打得过狠而发白(就地,不影响周围);**辉光** = 光散射出去把周围照亮(一圈磷光色的晕)。想要「中心发白」调上面那个,不必再把辉光开到最大。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EffectRow(title: L("白热化"), value: $model.overdrive, stashKey: "overdrive", defaultOn: 0.85, model: model)
            if model.overdrive > 0 {
                HStack(spacing: 10) {
                    Text(L("发白起点")).frame(width: 76, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.overdriveKnee, in: 0...1)
                    Text(String(format: "%.2f", model.overdriveKnee))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text(L("从多亮开始发白。调低=连中等亮度的笔画也泛白;调高=只有最亮的芯部发白、边缘保持磷光色。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.35)
            EffectRow(title: L("辉光"), value: $model.bloom, stashKey: "bloom", defaultOn: 0.65, model: model)
            // 辉光风格(v1.4):辉光关掉时这一档没有意义,故跟着 bloom > 0 显隐
            if model.bloom > 0 {
                HStack(spacing: 10) {
                    Text(L("辉光风格")).frame(width: 76, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.bloomStyle) {
                        Text(L("柔雾")).tag(0)
                        Text(L("光晕")).tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(width: 140)
                    Text(L("柔雾=能量守恒的模糊(原版,更接近实测);光晕=亮核峰值不衰减"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Text(L("光晕形状")).frame(width: 76, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.bloomShape) {
                        Text(L("单层")).tag(0)
                        Text(L("紧核+长尾")).tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(width: 140)
                    Text(L("真 CRT 的光晕衰减比指数快、比高斯慢(玻璃多次散射 + 眼内杂散光)。紧核+长尾=光更贴笔画、远处更干净"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .glassCard()
        VStack(spacing: 8) {
            EffectRow(title: L("余辉"), value: $model.burnIn, stashKey: "burnIn", defaultOn: 0.4, model: model)
            EffectRow(title: L("雪花噪点"), value: $model.staticNoise, stashKey: "noise", defaultOn: 0.12, model: model)
            EffectRow(title: L("画面闪烁"), value: $model.flickering, stashKey: "flicker", defaultOn: 0.2, model: model)
        }
        .glassCard()
        // 发光模型(v1.4):影响整幅画面的颜色合成方式,不是某一个特效 → 独立一张卡
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(L("发光模型")).frame(width: 76, alignment: .leading)
                Picker("", selection: $model.emissiveModel) {
                    Text(L("颜料")).tag(0)
                    Text(L("自发光")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 140)
                Spacer()
            }
            Text(model.emissiveModel == 1
                 ? L("自发光:叠加的光不砍平,溢出按色相等比压缩 —— 亮处保持纯磷光色、不发白。注意:实测真 CRT 照片的亮处**是会发白的**(最亮处饱和度只剩 0.11),所以这一档偏「理想磷光体」而非「照片写实」。")
                 : L("颜料(推荐):cool-retro-term 原版语义 —— 亮处逐通道饱和后褪色发白。与真 CRT 照片的实测走向一致(饱和度随亮度先升后降),笔画中心高亮偏白、边缘渐变回绿。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
        VStack(spacing: 8) {
            EffectRow(title: L("水平抖动"), value: $model.horizontalSync, stashKey: "hsync", defaultOn: 0.16, model: model)
            EffectRow(title: L("抖动"), value: $model.jitter, stashKey: "jitter", defaultOn: 0.2, model: model)
            EffectRow(title: L("移动亮线"), value: $model.glowingLine, stashKey: "glowing", defaultOn: 0.2, model: model)
            EffectRow(title: L("RGB 色差"), value: $model.rgbShift, stashKey: "rgb", defaultOn: 0.3, model: model)
            EffectRow(title: L("环境光"), value: $model.ambientLight, stashKey: "ambient", defaultOn: 0.3, model: model)
        }
        .glassCard()
        // 纯开关组(v1.1):无强度滑杆 —— 不套 EffectRow(那是"开关+滑杆"联动)
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: $model.powerOnEffect) { Text(L("开机动画")).frame(width: 76, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(L("新窗口播放显像管通电特效:亮点 → 亮线 → 画面展开"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 播放速度 4 档(v1.2 补丁;开关机动画同速,关掉开机动画时隐藏)
                if model.powerOnEffect {
                    Picker("", selection: $model.powerOnSpeed) {
                        Text(L("慢")).tag(0)
                        Text(L("标准")).tag(1)
                        Text(L("快")).tag(2)
                        Text(L("极速")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 200)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.bootSelfTest) { Text(L("开机自检")).frame(width: 76, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(L("启动首窗滚一段 BIOS 风自检(真实芯片/内存/磁盘信息),约 2 秒"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.channelSwitchFX) { Text(L("换台效果")).frame(width: 76, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(L("切主题瞬间画面收缩成亮线+雪花一闪,再以新配色亮起(老电视换台)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.animateInBackground) { Text(L("后台动画")).frame(width: 76, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(L("切到其他 App 时特效照常播放(拟真);关闭 = 失活即暂停,最省电"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.restoreSession) { Text(L("会话恢复")).frame(width: 76, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Text(L("启动时还原上次退出的窗口位置、分屏布局和各分屏的工作目录"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .glassCard()
    }
}

// MARK: - 终端页(v1.2 #5:Shell 集成 + 通知 + Visual Bell)

private struct TerminalPage: View {
    @ObservedObject var model: SettingsModel
    @State private var integrationInstalled = ShellIntegration.isInstalled
    @State private var installMessage: String?
    @State private var imgcatInstalled = ImgcatInstaller.isInstalled
    @State private var imgcatMessage: String?
    @State private var omzInstalled = OmzInstaller.isInstalled
    @State private var omzInstalling = false
    @State private var omzMessage: String?

    /// 内置复古提示符四套(v1.3;零依赖,任何点阵字体完美)
    ///
    /// ⚠️ 这里必须是 `static var`(计算属性)而**不是** `static let` ——
    /// `static let` 在 Swift 里是"首次访问时算一次,之后永远用缓存",
    /// label 里的 `L(...)` 就会被冻在初始化那一刻的语言上,切语言不再更新。
    /// 计算属性每次访问都重算,才跟得上热切换。(i18n 时踩到的坑,勿改回 let)
    static var retroPrompts: [(value: String, label: String, preview: String)] { [
        ("retro:ascii", L("复古 ASCII"), "user@mac:~/project %"),
        ("retro:dos", L("DOS 风"), "C:\\PROJECT\\YE_TERM>"),
        ("retro:c64", L("C64 风"), "READY."),
        ("retro:minimal", L("极简"), "%"),
    ] }
    /// omz 精选主题(纯 ASCII 无 Nerd Font 依赖;agnoster 需 Powerline 字形,标注)
    /// 同上,必须是计算属性
    static var omzPrompts: [(value: String, label: String, preview: String)] { [
        ("omz:robbyrussell", L("omz · robbyrussell(默认)"), "➜  ye_term git:(main)"),
        ("omz:ys", "omz · ys", "# user @ mac in ~/project on git:main\n$"),
        ("omz:af-magic", "omz · af-magic", "~/project (main) »"),
        ("omz:bira", "omz · bira", "╭─user@mac ~/project (main)\n╰─$"),
        ("omz:clean", "omz · clean", "user mac ~/project (main) %"),
        ("omz:gentoo", "omz · gentoo", "user@mac ~/project (main) %"),
        ("omz:agnoster", L("omz · agnoster(需 Powerline 字形)"), "user@mac  ~/project  main"),
    ] }

    /// omz 一键安装:先确认(执行远程官方脚本,需网络),再异步跑
    private func confirmInstallOmz() {
        let alert = NSAlert()
        alert.messageText = L("安装 oh-my-zsh?")
        alert.informativeText = L("将执行 oh-my-zsh 官方安装脚本(需要网络)。安装为静默模式:不改默认 shell、不自动启动 zsh、不改动你现有的 ~/.zshrc(仅追加一段接线)。")
        alert.addButton(withTitle: L("安装"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        omzInstalling = true
        omzMessage = L("正在下载安装 oh-my-zsh…")
        OmzInstaller.install { err in
            omzInstalling = false
            omzInstalled = OmzInstaller.isInstalled
            omzMessage = err ?? L("安装完成。新开的终端窗口生效;上面选择 omz 主题即可切换。")
        }
    }

    var body: some View {
        pageTitle(L("终端"))

        // 界面语言(i18n)。放终端页顶部 —— 这里本来就是"使用者个人偏好"的归属地。
        // 【学】选单里各语言**用各自的母语写**(简体中文 / English),不跟着当前
        //   界面语言翻 —— 万一误切成看不懂的语言,还能照着母语名找回来。
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text(L("界面语言"))
                    .font(.callout.bold())
                Spacer()
                Picker("", selection: Binding(
                    get: { L10n.shared.language },
                    set: { L10n.shared.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Text(L("切换后立刻生效,不用重启;文件选择器等系统对话框在下次启动后跟随。终端里跑的程序输出什么语言,跟这个设置无关。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()

        // Shell 集成(命令导航/时长统计的数据来源)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: integrationInstalled ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(integrationInstalled ? .green : .secondary)
                Text(L("Shell 集成"))
                    .font(.callout.bold())
                Text(integrationInstalled ? L("已安装") : L("未安装"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(integrationInstalled ? L("刷新脚本") : L("一键安装")) {
                    let err = ShellIntegration.install()
                    integrationInstalled = ShellIntegration.isInstalled
                    installMessage = err ?? L("完成。新开的窗口 / 标签自动生效;已开的会话在里面执行一次 source ~/.zshrc 即可升级(或关掉重开)。")
                }
                .glassButton()
            }
            Text(L("往 ~/.zshrc 末尾追加一行接线,让 zsh 报告命令边界(只在 YeTerm 里生效,不影响其它终端)。⌘↑/⌘↓ 跳命令、⇧⌘C 复制上条输出、失败命令红条、命令耗时统计都靠它。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let msg = installMessage {
                Text(msg).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .glassCard()

        // imgcat 工具(v1.2 #4:终端内显示图片的命令行入口;脚本内置零网络)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: imgcatInstalled ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(imgcatInstalled ? .green : .secondary)
                Text(L("imgcat 看图工具"))
                    .font(.callout.bold())
                Text(imgcatInstalled ? L("已安装") : L("未安装"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(imgcatInstalled ? L("重新安装") : L("一键安装")) {
                    let err = ImgcatInstaller.install()
                    imgcatInstalled = ImgcatInstaller.isInstalled
                    imgcatMessage = err ?? L("完成。新开的终端窗口里 imgcat 图片.png 即可。")
                }
                .glassButton()
            }
            Text(L("把 imgcat 脚本(app 内置,无需联网)装到 ~/.local/bin 并接好 PATH。之后终端里 imgcat 任意图片,直接在 CRT 荧光屏上看图——扫描线、辉光、弧度照常生效。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let msg = imgcatMessage {
                Text(msg).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .glassCard()

        // ---- 提示符主题(v1.3 #2/#3):内置复古提示符 + omz 主题切换 ----
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: omzInstalled ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(omzInstalled ? .green : .secondary)
                Text("oh-my-zsh").font(.callout.bold())
                Text(omzInstalled ? L("已安装") : L("未安装(omz 主题需要它;内置复古提示符不需要)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !omzInstalled {
                    Button(omzInstalling ? L("安装中…") : L("一键安装…")) {
                        confirmInstallOmz()
                    }
                    .glassButton()
                    .disabled(omzInstalling)
                }
            }
            if let msg = omzMessage {
                Text(msg).font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.25)
            HStack(spacing: 10) {
                Text(L("提示符主题")).frame(width: 90, alignment: .leading)
                Picker("", selection: $model.promptTheme) {
                    Text(L("不干预(用你自己的 p10k / starship)")).tag(String?.none)
                    Divider()
                    ForEach(Self.retroPrompts, id: \.value) { p in
                        Text(p.label).tag(Optional(p.value))
                    }
                    Divider()
                    ForEach(Self.omzPrompts, id: \.value) { p in
                        Text(p.label).tag(Optional(p.value))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                Spacer()
            }
            if let sel = model.promptTheme,
               let preview = (Self.retroPrompts + Self.omzPrompts).first(where: { $0.value == sel })?.preview {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(L("仅在 YeTerm 里生效(不改 ~/.zshrc 的 ZSH_THEME,其它终端照旧);选择后立即换提示符,不打断正在输入的内容。需要新版 Shell 集成脚本:刷新脚本之前开的老会话收不到热切信号(里面执行一次 source ~/.zshrc 即可升级,或关掉重开),刷新后新开的会话永久免此步骤。切换预设主题会带上匹配的提示符:复古设备主题配纯 ASCII,点阵字体不再出豆腐块。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()

        // 小件三连(v1.2 #8)
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: $model.inheritCwd) { Text(L("继承目录")).frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("⌘N/⌘T 新窗口从当前窗口所在目录起步(不用重新 cd)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.optionAsMeta) { Text("Option=Meta").frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("Option 键发 Meta:⌥B/⌥F 按词跳、⌥. 取上条参数;关闭则打特殊字符(∫´®)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Text(L("滚回行数")).frame(width: 90, alignment: .leading)
                Picker("", selection: $model.scrollbackLines) {
                    Text(L("1 千")).tag(1000)
                    Text(L("5 千")).tag(5000)
                    Text(L("1 万")).tag(10000)
                    Text(L("5 万")).tag(50000)
                    Text(L("10 万")).tag(100000)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text(L("历史能往回翻多少行(改了立即生效;越大越占内存)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            // 波特率限速(v1.4):16 档必须走默认下拉菜单样式,segmented 塞不下
            HStack(spacing: 10) {
                Text(L("输出速率")).frame(width: 90, alignment: .leading)
                Picker("", selection: $model.bitRate) {
                    Text(ByteRateLimiter.rateLabel(0)).tag(0)
                    Divider()
                    ForEach(ByteRateLimiter.presetRates.dropFirst(), id: \.self) { bps in
                        Text(ByteRateLimiter.rateLabel(bps)).tag(bps)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Text(model.bitRate > 0
                     ? Lf("约 %d 字符/秒。**随当前预设保存** —— 换主题各用各的速率。⌃C 立刻吐完积压", model.bitRate / 8)
                     : L("不限速。选一档即模拟老设备的出字节奏(300 bps 能看着屏幕一行行长出来)。**随当前预设保存**"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .glassCard()

        // 通知 + Visual Bell(纯本机)
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: $model.pasteProtection) { Text(L("粘贴保护")).frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("粘贴多行内容时先弹确认框(每个换行都会被 shell 当回车执行,误贴很危险)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.visualBell) { Text(L("荧光闪屏")).frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("终端响铃(\\a)时屏幕亮度脉冲一下 —— 复古 CRT 版 visual bell"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.notifyOnBell) { Text(L("响铃通知")).frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("窗口不在前台时响铃 → 送系统通知中心"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.notifyLongCommand) { Text(L("长命令通知")).frame(width: 90, alignment: .leading) }
                    .toggleStyle(.switch).controlSize(.mini)
                Text(L("后台跑完的长命令 → 送通知(含耗时与退出码;需 Shell 集成)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if model.notifyLongCommand {
                HStack(spacing: 10) {
                    Text(L("时长阈值")).frame(width: 90, alignment: .leading)
                    Slider(value: $model.notifyThresholdSeconds, in: 3...120, step: 1)
                    Text(Lf("%d 秒", Int(model.notifyThresholdSeconds)))
                        .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
                }
            }
        }
        .glassCard()
    }
}

// MARK: - 光标页

private struct CursorPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle(L("光标"))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("形状")).frame(width: 92, alignment: .leading)
                Picker("", selection: $model.cursorStyle) {
                    Text(L("块")).tag(0)
                    Text(L("下划线")).tag(1)
                    Text(L("竖线")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle(L("闪烁(空闲 1 秒后开始)"), isOn: $model.cursorBlinks)
                .toggleStyle(.switch)
        }
        .glassCard()
    }
}

// MARK: - 快捷键页(v1.2 补丁用户追加:纯查看,全部快捷键的说明书)

private struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel

    private struct Item {
        let keys: String
        let name: String
        var note: String?
    }
    private struct ShortcutGroup {
        let title: String
        var caption: String?
        let items: [Item]
    }

    // 静态清单(与 MainMenu/各功能实现同步维护;改快捷键必改这里)
    private var groups: [ShortcutGroup] {
        [
            .init(title: L("窗口与标签页"), caption: nil, items: [
                .init(keys: "⌘N", name: L("新建窗口"), note: L("继承当前工作目录(设置→终端可关)")),
                .init(keys: "⌘T", name: L("新建标签页"), note: L("并入当前窗口的标签组")),
                .init(keys: "⌘W", name: L("关闭窗口"), note: L("先播显像管关机动画再关")),
                .init(keys: "⌘M", name: L("最小化")),
                .init(keys: "⌃⇥ / ⌃⇧⇥", name: L("下一个 / 上一个标签页")),
                .init(keys: "⇧⌘\\", name: L("显示所有标签页")),
            ]),
            .init(title: L("分屏"), caption: nil, items: [
                .init(keys: "⌘D", name: L("向右分屏")),
                .init(keys: "⇧⌘D", name: L("向下分屏")),
                .init(keys: "⌘]", name: L("下一个分屏"), note: L("焦点在各分屏间轮转")),
            ]),
            .init(title: L("编辑与查找"), caption: nil, items: [
                .init(keys: "⌘C / ⌘V / ⌘A", name: L("复制 / 粘贴 / 全选")),
                .init(keys: "⌘F", name: L("查找"), note: L("回车=下一个(向历史方向),⇧回车=上一个,Esc 关闭")),
                .init(keys: "⌘G / ⇧⌘G", name: L("查找下一个 / 上一个")),
                .init(keys: L("回车 / Esc"), name: L("粘贴保护确认框"), note: L("多行粘贴弹出预览:回车确认粘贴,Esc 取消")),
            ]),
            .init(title: L("命令导航"), caption: L("需先安装 Shell 集成(菜单「命令 → 安装 Shell 集成…」,仅 zsh)"),
                  items: [
                .init(keys: "⌘↑ / ⌘↓", name: L("跳到上一条 / 下一条命令"), note: L("在滚回历史里按命令边界跳转")),
                .init(keys: "⇧⌘C", name: L("复制上条命令输出")),
            ]),
            .init(title: L("显示与特效"), caption: nil, items: [
                .init(keys: "⌘E", name: L("开关 CRT 特效"), note: L("复古 ↔ 普通终端模式,切换带换台闪断")),
                .init(keys: "⇧⌘M", name: L("消磁"), note: L("径向波纹 + 色差彩蛋;点击机壳边缘也能触发")),
                .init(keys: "⌥⌘O", name: L("OSD 调节面板"), note: L("仿 CRT 屏上菜单:↑↓ 选项,←→ 调值,Esc 关闭")),
            ]),
            .init(title: L("导出"), caption: L("文件存到桌面"), items: [
                .init(keys: "⇧⌘S", name: L("导出 CRT 截图"), note: L("含机壳的整幅画面 PNG")),
                .init(keys: "⇧⌘R", name: L("录制 GIF"), note: L("再按一次停止,上限 30 秒")),
            ]),
            .init(title: L("鼠标"), caption: nil, items: [
                .init(keys: L("⌘点击"), name: L("打开链接 / 文件路径"), note: L("⌘悬停出荧光下划线;path:line(编译报错格式)直接跳编辑器对应行")),
                .init(keys: L("点击机壳"), name: L("消磁彩蛋"), note: L("CRT 模式下点终端画面外的机壳边框区域")),
            ]),
            .init(title: L("Meta 键(Option)"),
                  caption: model.optionAsMeta
                      ? L("当前:Option 作为 Meta 键(设置 → 终端 可关)。关闭后 Option 恢复输入特殊字符。")
                      : L("当前:已关闭(Option 输入特殊字符)。在 设置 → 终端 里开启后以下才可用。"),
                  items: [
                .init(keys: "⌥B / ⌥F", name: L("光标按词后退 / 前进"), note: L("zsh/bash/Emacs 词跳")),
                .init(keys: "⌥⌫", name: L("删除前一个词")),
                .init(keys: "⌥D", name: L("删除后一个词")),
                .init(keys: "⌥.", name: L("插入上条命令的末尾参数"), note: L("连按向更早的命令回溯")),
            ]),
            .init(title: L("其它"), caption: nil, items: [
                .init(keys: "⌘,", name: L("打开设置")),
                .init(keys: "⌘Q", name: L("退出 YeTerm")),
            ]),
        ]
    }

    var body: some View {
        pageTitle(L("快捷键"), L("全部快捷键一览(仅查看;快捷键不可自定义)"))

        ForEach(groups, id: \.title) { group in
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title).font(.callout.bold())
                if let cap = group.caption {
                    Text(cap).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(group.items, id: \.keys) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.keys)
                            .font(.system(size: 12, design: .monospaced).bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                            .frame(width: 118, alignment: .leading)
                        Text(item.name).font(.callout)
                        if let note = item.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .glassCard()
        }
    }
}

// MARK: - 配置文件页

// MARK: - 远程主机页(v1.3 SSH)

/// 远程服务器清单维护:列表 + 表单增删改。主机信息进 ssh-hosts.json,
/// 密码进系统钥匙串(SecureField 输入,界面上永不回显已存密码)。
/// 【学】@State 是 SwiftUI 的"组件内部状态"(类比 React useState):
///      改它视图自动重画;真数据在 SSHHostStore,@State 只是界面快照。
private struct RemotePage: View {
    @State private var hosts: [SSHHost] = SSHHostStore.shared.hosts
    @State private var showForm = false
    @State private var editingID: UUID?
    @State private var fName = ""
    @State private var fHost = ""
    @State private var fPort = "22"
    @State private var fUser = ""
    @State private var fNote = ""
    @State private var fPassword = ""
    @State private var hasStoredPassword = false
    @State private var fLegacy = false
    @State private var fExtra = ""
    @State private var testStatus = ""
    @State private var testing = false

    var body: some View {
        pageTitle(L("远程主机"))
        VStack(alignment: .leading, spacing: 10) {
            if hosts.isEmpty {
                Text(L("还没有服务器。添加后可从菜单栏「服务器」点击连接,或 ⇧⌘O 呼出选单(回车连接,⇧回车分屏连)。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hosts) { h in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(h.name).font(.body.bold())
                            if SSHHostStore.shared.hasPassword(id: h.id) {
                                Image(systemName: "key.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help(L("已存密码(钥匙串)"))
                            }
                        }
                        Text(h.address + (h.note.isEmpty ? "" : "  ·  \(h.note)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("编辑")) { beginEdit(h) }.glassButton()
                    // 纯文字按钮:Image(systemName:) 在 glass 样式下描不出来
                    // (探针截图实测只剩「编辑」),文字按钮稳且语义更直白
                    Button(L("删除")) {
                        SSHHostStore.shared.remove(id: h.id)
                        hosts = SSHHostStore.shared.hosts
                        if editingID == h.id { showForm = false }
                    }
                    .glassButton()
                }
            }
            Button {
                beginAdd()
            } label: {
                Label(L("新增服务器…"), systemImage: "plus")
            }
            .glassButton()
        }
        .glassCard()

        if showForm {
            VStack(alignment: .leading, spacing: 10) {
                Text(editingID == nil ? L("新增服务器") : L("编辑服务器"))
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text(L("名字"))
                        TextField(L("生产网关"), text: $fName).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("主机"))
                        TextField(L("IP 或域名"), text: $fHost).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("端口"))
                        TextField("22", text: $fPort).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    GridRow {
                        Text(L("用户名"))
                        TextField("root", text: $fUser).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("密码"))
                        SecureField(hasStoredPassword ? L("已存(留空不改)") : L("留空 = 走密钥/手动输入"),
                                    text: $fPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("备注"))
                        TextField(L("可选"), text: $fNote).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("兼容"))
                        Toggle(L("兼容旧设备(允许 ssh-rsa)"), isOn: $fLegacy)
                    }
                    GridRow {
                        Text(L("额外参数"))
                        TextField(L("可选,原样拼进 ssh 命令"), text: $fExtra)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if fLegacy {
                    Text(L("老设备(如越狱 iPhone、旧路由器/NAS)只提供 SHA-1 的 ssh-rsa 算法,")
                         + L("新版 ssh 默认已停用 → 报 no matching host key type found。")
                         + L("打开这个开关会自动带上兼容参数。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(L("保存")) { save() }
                        .glassButton()
                        .disabled(fHost.trimmingCharacters(in: .whitespaces).isEmpty
                                  || fUser.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(testing ? L("测试中…") : L("测试连通")) { runTest() }
                        .glassButton()
                        .disabled(testing || fHost.trimmingCharacters(in: .whitespaces).isEmpty
                                  || fUser.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(L("取消")) { showForm = false }.glassButton()
                    if hasStoredPassword {
                        Button(L("清除已存密码")) {
                            if let id = editingID { SSHHostStore.shared.setPassword("", id: id) }
                            hasStoredPassword = false
                        }
                        .glassButton()
                    }
                }
                if !testStatus.isEmpty {
                    Text(testStatus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .glassCard()
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(L("密码只存系统钥匙串,不写入任何配置文件。连接 = YeTerm 替你在 shell 里输入 ssh 命令(退出 ssh 回到原 shell);检测到 password: 提示自动代填一次,首连指纹确认自动应答 yes。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private func beginAdd() {
        editingID = nil
        fName = ""; fHost = ""; fPort = "22"; fUser = ""; fNote = ""; fPassword = ""
        fLegacy = false; fExtra = ""
        hasStoredPassword = false
        showForm = true
    }

    private func beginEdit(_ h: SSHHost) {
        editingID = h.id
        fName = h.name; fHost = h.host; fPort = String(h.port)
        fUser = h.user; fNote = h.note; fPassword = ""
        fLegacy = h.legacyAlgorithms; fExtra = h.extraOptions
        hasStoredPassword = SSHHostStore.shared.hasPassword(id: h.id)
        showForm = true
    }

    /// 测试连通:真跑一次 ssh 握手(不问密码);需要兼容参数时自动补上并
    /// 回填到「额外参数」框,保存后这台机器以后直接带着走
    private func runTest() {
        testing = true
        testStatus = ""
        var h = SSHHost()
        if let id = editingID { h.id = id }
        h.host = fHost.trimmingCharacters(in: .whitespaces)
        h.user = fUser.trimmingCharacters(in: .whitespaces)
        h.port = Int(fPort.trimmingCharacters(in: .whitespaces)) ?? 22
        h.legacyAlgorithms = fLegacy
        h.extraOptions = fExtra.trimmingCharacters(in: .whitespaces)
        SSHConnectivity.test(host: h) { r in
            testing = false
            testStatus = (r.ok ? "✅ " : "⚠️ ") + r.summary
            if !r.legacyOptions.isEmpty, !fExtra.contains(r.legacyOptions) {
                fExtra = fExtra.isEmpty ? r.legacyOptions : fExtra + " " + r.legacyOptions
                testStatus += L("\n已把兼容参数填入「额外参数」,点保存即长期生效。")
            }
        }
    }

    private func save() {
        var h = SSHHost()
        if let id = editingID { h.id = id }
        h.host = fHost.trimmingCharacters(in: .whitespaces)
        h.user = fUser.trimmingCharacters(in: .whitespaces)
        h.port = Int(fPort.trimmingCharacters(in: .whitespaces)) ?? 22
        h.note = fNote.trimmingCharacters(in: .whitespaces)
        h.legacyAlgorithms = fLegacy
        h.extraOptions = fExtra.trimmingCharacters(in: .whitespaces)
        let name = fName.trimmingCharacters(in: .whitespaces)
        h.name = name.isEmpty ? h.host : name
        SSHHostStore.shared.upsert(h)
        if !fPassword.isEmpty {
            SSHHostStore.shared.setPassword(fPassword, id: h.id)
        }
        hosts = SSHHostStore.shared.hosts
        showForm = false
    }
}

private struct FilesPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        pageTitle(L("配置文件"))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    importConfig()
                } label: {
                    Label(L("导入…"), systemImage: "square.and.arrow.down")
                }
                .glassButton()
                Button {
                    exportConfig()
                } label: {
                    Label(L("导出…"), systemImage: "square.and.arrow.up")
                }
                .glassButton()
            }
            Text(L("当前配置自动保存于 ~/Library/Application Support/YeTerm/config.json,启动时自动载入。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()

        // ---- 主题格式文档导出(v1.2 补丁用户追加:喂给 AI 生成主题用)----
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("主题配置格式文档")).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    exportThemeDoc()
                } label: {
                    Label(L("保存到电脑…"), systemImage: "doc.text")
                }
                .glassButton()
                .controlSize(.small)
            }
            Text(L("一份 Markdown 格式的主题 JSON 完整字段说明(含给 AI 的生成建议与示例)。把它交给任意 AI 即可帮你生成主题文件,放进 profiles 目录或用上方「导入」即可使用。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    /// 主题格式文档导出(内置 MD 资源 → 用户选择的位置;喂 AI 生成主题用)
    private func exportThemeDoc() {
        guard let src = Bundle.module.url(forResource: L("主题配置格式"), withExtension: "md",
                                          subdirectory: "Docs") else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("YeTerm 主题配置格式.md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)   // 覆盖语义(SavePanel 已确认过)
        do {
            try FileManager.default.copyItem(at: src, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("文档保存失败")
            alert.informativeText = "\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// 导入 crterm/YeTerm 配置 JSON(全字段容错;载入即实时生效并写盘)
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let cfg = CRTConfig.load(path: url.path) else {
            let alert = NSAlert()
            alert.messageText = L("配置导入失败")
            alert.informativeText = Lf("无法解析 %@,请确认是有效的主题配置 JSON。", url.lastPathComponent)
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        model.load(config: cfg)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(model.presetName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(model.toConfig()).write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("配置导出失败")
            alert.informativeText = "\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
