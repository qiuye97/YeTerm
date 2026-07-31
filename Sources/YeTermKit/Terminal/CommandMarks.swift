// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 命令导航的"书签本"(v1.2 #3,OSC 133 shell 集成)
//
// 这个文件:终端怎么知道"哪一行是一条命令的开始"?靠 shell 主动报幕 ——
//   我们往 ~/.zshrc 注入一小段钩子,让 zsh 在关键时刻输出**隐形转义序列**
//   (OSC 133,FinalTerm 发明、iTerm2/WezTerm 通行的行业约定):
//     A = 提示符开始   C = 命令开始执行   D;退出码 = 命令结束
//   终端解析到这些序列时记下当前行号,就得到了整个会话的"命令书签本":
//   ⌘↑/⌘↓ 跳上/下一条命令、一键复制上条输出、失败命令旁标 ✗,全吃这份数据。
//
// 行号基准(工程要点):用「会话稳定行号」= 视口顶行(yDisp)+ 光标行 + 已裁剪行数
//   (totalLinesTrimmed)。滚动缓冲区裁剪头部后,减掉 trimmed 就还原成当前
//   lines 下标 —— scrollTo(row:)/getText 都吃这个下标,一套基准贯穿全链。
//
// 语法看点:
//   `ArraySlice<UInt8>` —— 数组切片(零拷贝的"窗口",类比 Java 的 subList);
//   `extension EventTerminalView` —— 给已有类"追加"方法,不改原文件
//     (Swift 的扩展机制,类比 Kotlin extension function)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import Foundation
import SwiftTerm

/// 一条命令的书签:提示符行 / 输出起始行 / 结束行 + 退出码(行号=会话稳定行号)
struct CommandMark {
    var promptRow: Int          // OSC 133;A:提示符打印处
    var outputStartRow: Int?    // OSC 133;C:命令开始执行(输出从这行起)
    var endRow: Int?            // OSC 133;D:命令结束(下一提示符前)
    var exitCode: Int?          // D 携带的 $?(0=成功)
    var startTime: CFAbsoluteTime?   // C 时刻(v1.2 #5:命令耗时 = D 时刻 − 这里)
}

/// 书签本:解析 OSC 133 序列流,维护有序 marks(状态机全主线程,与终端解析同线程)
final class CommandMarkStore {
    private(set) var marks: [CommandMark] = []
    private let maxMarks = 2000   // 超长会话上限,超出丢最旧(书签本不是日志)

    /// 命令完成回调(v1.2 #5 通知用):参数 = 完成的书签 + 耗时秒(无 C 时刻则 0)
    var onCommandFinished: ((CommandMark, TimeInterval) -> Void)?

    /// 收到一条 OSC 133。payload 形如 "A" / "C" / "D;0"。
    /// `row` = 序列到达时刻的会话稳定行号。
    func ingest(payload: String, row: Int) {
        let parts = payload.split(separator: ";", maxSplits: 1)
        guard let kind = parts.first else { return }
        switch kind {
        case "A":
            marks.append(CommandMark(promptRow: row))
            if marks.count > maxMarks { marks.removeFirst(marks.count - maxMarks) }
        case "B":
            break   // 提示符结束(可选标记),导航用不到,静默接受
        case "C":
            if !marks.isEmpty, marks[marks.count - 1].outputStartRow == nil {
                marks[marks.count - 1].outputStartRow = row
                marks[marks.count - 1].startTime = CFAbsoluteTimeGetCurrent()
            }
        case "D":
            let code = parts.count > 1 ? Int(parts[1]) : nil
            // D 归属最近一条尚未收尾的命令(D 在下一提示符打印前发出)
            if let i = marks.lastIndex(where: { $0.endRow == nil }) {
                marks[i].endRow = row
                marks[i].exitCode = code
                // 只有真正跑过命令(有 C)才算"完成"——空回车的 A..D 不通知
                if let t0 = marks[i].startTime {
                    onCommandFinished?(marks[i], CFAbsoluteTimeGetCurrent() - t0)
                }
            }
        default:
            break
        }
    }

    func clear() { marks.removeAll() }
}

// MARK: - EventTerminalView 接线

extension EventTerminalView {
    private static var storeKey: UInt8 = 0

    /// 本视图的命令书签本(装了 shell 集成才会有内容)
    var commandMarks: CommandMarkStore {
        // 【学】objc_getAssociatedObject:给不能加存储属性的扩展"外挂"一个属性
        //     (关联对象,AppKit 世界的惯用后门;跟随宿主对象一起释放)
        if let s = objc_getAssociatedObject(self, &Self.storeKey) as? CommandMarkStore {
            return s
        }
        let s = CommandMarkStore()
        objc_setAssociatedObject(self, &Self.storeKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    /// 当前会话稳定行号(见文件头「行号基准」)
    private var stableCursorRow: Int {
        let t = getTerminal()
        return t.getTopVisibleRow() + t.getCursorLocation().y + t.buffer.totalLinesTrimmed
    }

    /// 注册 OSC 133 解析(TermHost 装配时调用,幂等由 store 惰性创建保证)
    func installCommandMarks() {
        let store = commandMarks
        getTerminal().registerOscHandler(code: 133) { [weak self] data in
            guard let self else { return }
            let payload = String(bytes: data, encoding: .utf8) ?? ""
            store.ingest(payload: payload, row: self.stableCursorRow)
        }
    }

    // MARK: 导航/取用(菜单 action 从窗口控制器转发进来)

    /// 会话稳定行号 → 当前 lines 下标(scrollTo/getText 的基准)
    private func linesIndex(of stableRow: Int) -> Int {
        stableRow - getTerminal().buffer.totalLinesTrimmed
    }

    /// ⌘↑:跳到上一条命令的提示符行(相对当前视口顶)
    func jumpToPreviousCommand() {
        let t = getTerminal()
        let top = t.getTopVisibleRow()
        guard let mark = commandMarks.marks.last(where: { linesIndex(of: $0.promptRow) < top }) else {
            scrollTo(row: 0)   // 没有更早的书签 → 到最顶
            return
        }
        scrollTo(row: max(0, linesIndex(of: mark.promptRow)))
    }

    /// ⌘↓:跳到下一条命令的提示符行
    func jumpToNextCommand() {
        let t = getTerminal()
        let top = t.getTopVisibleRow()
        guard let mark = commandMarks.marks.first(where: { linesIndex(of: $0.promptRow) > top }) else {
            scroll(toPosition: 1.0)   // 没有更晚的书签 → 回到底部(跟随实时输出)
            return
        }
        scrollTo(row: max(0, linesIndex(of: mark.promptRow)))
    }

    /// 复制上一条命令的输出(最近一条有 C 有 D 的命令,C 行到 D 前一行)
    /// 返回复制的文本(nil = 没有可复制的输出)
    @discardableResult
    func copyLastCommandOutput() -> String? {
        let t = getTerminal()
        guard let mark = commandMarks.marks.last(where: {
            $0.outputStartRow != nil && $0.endRow != nil
        }), let startStable = mark.outputStartRow, let endStable = mark.endRow else { return nil }
        let start = linesIndex(of: startStable)
        let end = linesIndex(of: endStable) - 1   // D 所在行是新提示符行,输出到它前一行
        guard end >= start, start >= 0 else { return nil }
        let text = t.getText(start: Position(col: 0, row: start),
                             end: Position(col: t.cols - 1, row: end))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// 当前视口内失败命令(exit≠0)的视口行号(✗ 荧光标记渲染用)
    func failedCommandViewportRows() -> [Int] {
        let t = getTerminal()
        let top = t.getTopVisibleRow()
        return commandMarks.marks.compactMap { m in
            guard let code = m.exitCode, code != 0 else { return nil }
            let vr = linesIndex(of: m.promptRow) - top
            return (0..<t.rows).contains(vr) ? vr : nil
        }
    }
}
