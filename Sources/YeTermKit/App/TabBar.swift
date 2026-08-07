// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 标签栏的两种皮肤(2026-08-06 用户需求)
//
// 这个文件:窗口内多标签的**两套标签栏**,按「机壳是否生效」二选一:
//   ① TabStripController —— CRT 盒绘条:选中标签被线框"抬起"、底线从它处断开
//      (老 DOS/TUI 软件的翻页卡样式)。走 OSD 同款机制:一个 2 行的假想终端当
//      画布,feed 盒绘字符 → ContentRenderer 渲成纹理 → 合成进画面顶部 →
//      自动过 CRT 管线 —— 吃荧光染色、扫描线、辉光,跟屏幕一起鼓弧度。
//   ② GlassTabBar —— 液态玻璃胶囊条(参考用户给的 Terminal.app 截图):
//      标题 + ⌘N 角标、竖线分隔、选中标签是亮色胶囊、右端圆形 + 号。
//      纯 SwiftUI,macOS 26 用系统 Liquid Glass,15 回落毛玻璃材质。
//
// 语法看点:
//   `enum GlassTabBar`(无 case)—— Swift 惯用的"命名空间":只放静态成员,
//     类比 Java 的工具类 + private 构造器。
//   `NSHostingView` —— 把 SwiftUI 视图包成 AppKit 视图往窗口里挂的桥
//     (类比在传统 DOM 页面里嵌一块 React 组件)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Metal
import SwiftTerm
import SwiftUI

// MARK: - ① CRT 盒绘标签条

/// 盒绘标签条画布。产出两行字符画,形如:
/// ```
///  ┌─ 1 zsh ─┐
/// ─┘         └── 2 ssh ─── 3 vim ──────────
/// ```
/// 选中标签在上行、由线框托住,底线在它处断开;未选中标签嵌在底线里。
final class TabStripController {
    struct TabInfo {
        let title: String
        let hasActivity: Bool
    }

    private let ctx: MetalContext
    private let content: ContentRenderer
    private let termDelegate = HarnessTermDelegate()
    private var terminal: Terminal
    private var cols: Int
    /// 每个标签占据的显示列区间(点击命中用;与 feed 的字符逐列对齐)
    private var ranges: [Range<Int>] = []

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.content = ContentRenderer(ctx: ctx)
        self.cols = 80
        self.terminal = Terminal(delegate: termDelegate,
                                 options: TerminalOptions(cols: 80, rows: 2))
    }

    /// 全量重排 + 重 feed(2×cols 小画布,整幅重画零成本)
    func update(tabs: [TabInfo], selected: Int, cols newCols: Int) {
        let c = max(20, newCols)
        if c != cols {
            cols = c
            terminal = Terminal(delegate: termDelegate,
                                options: TerminalOptions(cols: c, rows: 2))
        }
        let (row1, row2) = compose(tabs: tabs, selected: selected)
        terminal.feed(text: "\u{1b}[2J\u{1b}[H" + row1 + "\r\n" + row2)
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }

    /// 点击命中:显示列 → 标签下标
    func tabIndex(atColumn col: Int) -> Int? {
        ranges.firstIndex { $0.contains(col) }
    }

    // ---- 排版 ----

    /// 生成两行字符画并记录各标签的列区间。
    /// 逐段从左到右拼(两行同步推进游标),CJK 标题按显示宽 2 计列 ——
    /// 画布是真终端,列数一致才能上下对齐、点击才打得准。
    private func compose(tabs: [TabInfo], selected: Int) -> (String, String) {
        ranges = []
        guard !tabs.isEmpty else { return ("", String(repeating: "─", count: cols)) }

        // 标签文案:「N 标题」,后台有动静加「·」(参考图同款活动点)
        var labels = tabs.enumerated().map { i, t in
            "\(i + 1) " + (t.hasActivity ? "· " : "") + t.title
        }
        // 定宽预算:选中段框架占 6 列(┌─␣…␣─┐),未选中段占 2 列(前后空格),
        // 段间线 2 列,首列留 1 列线头。超预算就按份truncate标题(至少留 4 列)。
        func overhead(_ n: Int) -> Int { 1 + 6 + (n - 1) * 2 + n * 2 }
        let budget = cols - overhead(tabs.count)
        let widths = labels.map { Self.displayWidth($0) }
        if widths.reduce(0, +) > budget {
            let per = max(4, budget / tabs.count)
            labels = labels.map { Self.truncate($0, to: per) }
        }

        var row1 = " ", row2 = "─"     // 首列:上行空、下行线头
        var cursor = 1
        for (i, label) in labels.enumerated() {
            let w = Self.displayWidth(label)
            if i == selected {
                // 上行 ┌─ label ─┐,下行 ┘…(空)…└,共 w+6 列
                row1 += "┌─ " + label + " ─┐"
                row2 += "┘" + String(repeating: " ", count: w + 4) + "└"
                ranges.append(cursor..<(cursor + w + 6))
                cursor += w + 6
            } else {
                // 嵌在底线里:␣label␣,共 w+2 列
                row1 += String(repeating: " ", count: w + 2)
                row2 += " " + label + " "
                ranges.append(cursor..<(cursor + w + 2))
                cursor += w + 2
            }
            // 段间连接线 2 列
            row1 += "  "
            row2 += "──"
            cursor += 2
        }
        // 底线铺满剩余;两行都硬钳在 cols 内(防终端自动折行撑爆画布)
        if cursor < cols {
            row2 += String(repeating: "─", count: cols - cursor)
        }
        return (Self.clip(row1, to: cols), Self.clip(row2, to: cols))
    }

    /// 字符显示宽(1 或 2)。只认无争议的宽字符区段(CJK/全角);
    /// East Asian ambiguous(…、▓ 等)一律**不要**用在本画布(OSD 同款教训)。
    private static func charWidth(_ s: Unicode.Scalar) -> Int {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + charWidth($1) }
    }

    /// 按显示宽截断,尾缀 ".."(纯 ASCII,避开 ambiguous 的 "…")
    static func truncate(_ s: String, to width: Int) -> String {
        guard displayWidth(s) > width else { return s }
        var acc = 0
        var out = ""
        for ch in s {
            let w = displayWidth(String(ch))
            if acc + w > width - 2 { break }
            out.append(ch)
            acc += w
        }
        return out + ".."
    }

    /// 按显示宽硬剪(整行保险丝)
    private static func clip(_ s: String, to width: Int) -> String {
        guard displayWidth(s) > width else { return s }
        var acc = 0
        var out = ""
        for ch in s {
            let w = displayWidth(String(ch))
            if acc + w > width { break }
            out.append(ch)
            acc += w
        }
        return out
    }
}

// MARK: - ② 液态玻璃标签条

struct GlassTabItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let hasActivity: Bool
}

/// 数据模型:窗口控制器往里灌,SwiftUI 自动重画
/// 【学】ObservableObject + @Published = SwiftUI 的响应式数据源(类比 Vue 的
///      reactive store):字段一变,订阅它的视图 body 自动重算。
final class GlassTabBarModel: ObservableObject {
    @Published var items: [GlassTabItem] = []
    @Published var selected = 0
}

enum GlassTabBar {
    static let height: CGFloat = 34

    static func makeHostView(model: GlassTabBarModel,
                             onSelect: @escaping (Int) -> Void,
                             onNew: @escaping () -> Void) -> NSView {
        let host = NSHostingView(rootView: GlassTabBarView(model: model,
                                                           onSelect: onSelect, onNew: onNew))
        host.autoresizingMask = []   // frame 由 RootView.layout 手排
        return host
    }
}

/// 参考图(Terminal.app 26 风格)逐项对齐:整条深色圆角底、各标签等宽、
/// 「标题 + ⌘N 角标」、竖线分隔、选中标签 = 亮色胶囊、右端圆形 + 号
private struct GlassTabBarView: View {
    @ObservedObject var model: GlassTabBarModel
    let onSelect: (Int) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            glassContainer {
                HStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        tabCell(item, idx: idx)
                        if idx < model.items.count - 1 {
                            Rectangle()
                                .fill(.secondary.opacity(0.35))
                                .frame(width: 1, height: 14)
                        }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)   // 端头多留一点:胶囊外轮廓的圆弧别啃到首尾格
            }
            newButton
        }
        .frame(height: GlassTabBar.height)
    }

    private func tabCell(_ item: GlassTabItem, idx: Int) -> some View {
        let selected = (idx == model.selected)
        return HStack(spacing: 6) {
            if item.hasActivity {
                Circle().fill(.secondary).frame(width: 5, height: 5)
            }
            Text(item.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if idx < 9 {
                Text("⌘\(idx + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: GlassTabBar.height - 8)
        .background {
            if selected {
                Capsule().fill(.primary.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(idx) }
    }

    private var newButton: some View {
        Button(action: onNew) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: GlassTabBar.height - 6, height: GlassTabBar.height - 6)
        }
        .buttonStyle(.plain)
        .background(glassCircle)
        .help(L("新建标签页(⌘T)"))
    }

    /// 容器玻璃底:26 上真 Liquid Glass,15 回落毛玻璃材质。
    /// 外轮廓用 **Capsule**(2026-08-07 用户实测:圆角矩形和内侧选中胶囊的
    /// 端头弧度不一致,参考图 Terminal.app 的条两端就是全圆的)
    /// 【学】@ViewBuilder + #available:同一段界面按系统版本给两种实现,
    ///      编译期都保留、运行时按版本走(部署目标 15、SDK 26 的标准写法)。
    @ViewBuilder
    private func glassContainer<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            content()
                .glassEffect(.regular, in: Capsule())
        } else {
            content()
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var glassCircle: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }
}
