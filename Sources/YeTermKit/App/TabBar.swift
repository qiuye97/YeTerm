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

/// 盒绘标签条画布(2026-08-07 重构:与玻璃条同构的字符版)。三行字符画,形如:
/// ```
/// ┌────────────┬────────────┬────────────┐
/// │x   1 zsh   │   2 ssh    │   3 vim    │
/// └────────────┴────────────┴────────────┘
/// ```
/// 格子等宽平分、标题居中;**选中格整格反显**(荧光亮底暗字 = 深色底档);
/// **悬浮格浅灰底 + 左侧浮出 x**(点 x 关那页);全部走 ANSI,经 CRT 染色后
/// 反显块即磷光亮块、灰底即弱磷光 —— 和玻璃条"选中深/悬浮浅"一一对应。
final class TabStripController {
    struct TabInfo {
        let title: String
        let hasActivity: Bool
    }

    static let rows = 3   // 上框线 / 内容行 / 下框线

    private let ctx: MetalContext
    private let content: ContentRenderer
    private let termDelegate = HarnessTermDelegate()
    private var terminal: Terminal
    private var cols: Int
    /// 每个标签占据的显示列区间(命中用;与 feed 的字符逐列对齐)
    private var ranges: [Range<Int>] = []
    /// 悬浮格的 x 按钮命中列(略放宽到 3 列,好点)
    private var closeRange: Range<Int>?

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.content = ContentRenderer(ctx: ctx)
        self.cols = 80
        self.terminal = Terminal(delegate: termDelegate,
                                 options: TerminalOptions(cols: 80, rows: Self.rows))
    }

    /// 全量重排 + 重 feed(3×cols 小画布,整幅重画零成本)
    func update(tabs: [TabInfo], selected: Int, hovered: Int?, cols newCols: Int) {
        let c = max(20, newCols)
        if c != cols {
            cols = c
            terminal = Terminal(delegate: termDelegate,
                                options: TerminalOptions(cols: c, rows: Self.rows))
        }
        let (r1, r2, r3) = compose(tabs: tabs, selected: selected, hovered: hovered)
        terminal.feed(text: "\u{1b}[2J\u{1b}[H" + r1 + "\r\n" + r2 + "\r\n" + r3)
    }

    func render(font: NSFont, scale: CGFloat) -> MTLTexture? {
        content.render(terminal: terminal, font: font, scale: scale, wait: false)
    }

    /// 悬浮命中:显示列 → 标签下标(边框列返回 nil)
    func tabIndex(atColumn col: Int) -> Int? {
        ranges.firstIndex { $0.contains(col) }
    }

    /// 点击命中:x 按钮列 → 关闭;格内其余列 → 切换
    func hitTest(column col: Int) -> (tab: Int, isClose: Bool)? {
        if let cr = closeRange, cr.contains(col),
           let t = ranges.firstIndex(where: { $0.contains(col) }) {
            return (t, true)
        }
        return tabIndex(atColumn: col).map { ($0, false) }
    }

    // ---- 排版 ----

    /// 生成三行字符画并记录命中区间。格宽 = (cols - (n+1) 根竖线) / n,
    /// 余数从左往右一格一列摊掉;CJK 标题按显示宽 2 计列。
    private func compose(tabs: [TabInfo], selected: Int,
                         hovered: Int?) -> (String, String, String) {
        ranges = []
        closeRange = nil
        let n = tabs.count
        guard n > 0, cols >= n * 5 + n + 1 else { return ("", "", "") }

        let inner = cols - (n + 1)
        let base = inner / n, extra = inner % n
        let widths = (0..<n).map { base + ($0 < extra ? 1 : 0) }

        var r1 = "┌", r2 = "│", r3 = "└"
        var cursor = 1
        for (i, tab) in tabs.enumerated() {
            let w = widths[i]
            r1 += String(repeating: "─", count: w)
            r3 += String(repeating: "─", count: w)

            // 标题:「N 标题」+ 活动点「·」;两侧各留 3 列(x 区 + 呼吸),居中
            let label = Self.truncate("\(i + 1) " + (tab.hasActivity ? "· " : "") + tab.title,
                                      to: max(1, w - 6))
            let lw = Self.displayWidth(label)
            let padL = max(0, (w - lw) / 2)
            let padR = max(0, w - lw - padL)
            var body = String(repeating: " ", count: padL) + label
                     + String(repeating: " ", count: padR)
            // 悬浮格左侧浮出 x(玻璃条同款交互;字符画布无真悬浮态,由控制器
            // 用鼠标追踪喂进来)。x 恒在第 2 列,标题居中不因它挪动
            if hovered == i, w >= 4 {
                var chars = Array(body)
                chars[1] = "x"
                body = String(chars)
                closeRange = cursor..<(cursor + 3)
            }
            if i == selected {
                // 深色档:整格反显(SGR 7)→ CRT 染色后 = 磷光亮底 + 暗字
                r2 += "\u{1b}[7m" + body + "\u{1b}[27m"
            } else if hovered == i {
                // 浅色档:暗灰底(真彩 SGR 48;2)→ 染色后 = 弱磷光底
                r2 += "\u{1b}[48;2;84;84;84m" + body + "\u{1b}[49m"
            } else {
                r2 += body
            }
            ranges.append(cursor..<(cursor + w))
            cursor += w + 1
            let last = (i == n - 1)
            r1 += last ? "┐" : "┬"
            r2 += "│"
            r3 += last ? "┘" : "┴"
        }
        return (r1, r2, r3)
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
                             onClose: @escaping (Int) -> Void,
                             onNew: @escaping () -> Void) -> NSView {
        let host = NSHostingView(rootView: GlassTabBarView(model: model, onSelect: onSelect,
                                                           onClose: onClose, onNew: onNew))
        host.autoresizingMask = []   // frame 由 RootView.layout 手排
        return host
    }
}

/// 参考图(Terminal.app 26 风格)逐项对齐:整条深色圆角底、各标签等宽、
/// 「标题 + ⌘N 角标」、竖线分隔、选中标签 = 亮色胶囊、右端圆形 + 号
private struct GlassTabBarView: View {
    @ObservedObject var model: GlassTabBarModel
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNew: () -> Void
    /// 鼠标悬浮的标签下标(悬浮时左侧浮出圆形关闭钮,参考图 Terminal.app 同款)
    /// 【学】@State = 视图私有的可变状态,变了自动重画(类比 React useState)。
    @State private var hovered: Int?

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
                .padding(3)   // 四边等距(2026-08-07 用户实测:两头间隙要和上下一致)
            }
            newButton
        }
        .frame(height: GlassTabBar.height)
    }

    /// 单元布局照参考图(2026-08-07 用户需求):标题**居中**;⌘N 角标钉右;
    /// 悬浮时左侧浮出圆形 ✕ 关闭钮 —— 居中组与两侧件用 ZStack 分层,
    /// 标题左右各让 40pt,长标题截断也不会撞上 ✕ / ⌘N
    private func tabCell(_ item: GlassTabItem, idx: Int) -> some View {
        let selected = (idx == model.selected)
        return ZStack {
            HStack(spacing: 6) {
                if item.hasActivity {
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 40)
            HStack {
                if hovered == idx {
                    Button(action: { onClose(idx) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(L("关闭标签页"))
                }
                Spacer(minLength: 0)
                if idx < 9 {
                    Text("⌘\(idx + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GlassTabBar.height - 8)
        .background {
            // 选中 = 重底;未选中悬浮 = 浅底(2026-08-07 用户调校)
            if selected {
                Capsule().fill(.primary.opacity(0.32))
            } else if hovered == idx {
                Capsule().fill(.primary.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(idx) }
        .onHover { inside in
            if inside {
                hovered = idx
            } else if hovered == idx {
                hovered = nil
            }
        }
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
