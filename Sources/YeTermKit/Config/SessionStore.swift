// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 窗口会话的"存档/读档"(v1.2 #2)
//
// 这个文件:把"退出前的样子"存成 JSON、下次启动照原样摆回来 ——
//   每个窗口的位置大小 + 分屏结构(一棵树)+ 每个格子 shell 的工作目录。
//   类比游戏存档:退出时快照世界状态,进游戏读档还原。
//
// 两个技术点:
//   ▸ 布局树用**递归枚举**表达:一个节点要么是叶子(pane),要么是分割
//     (split,带方向+子节点)。`indirect enum` = 允许枚举内嵌自己
//     (类比 Java 里节点类型自引用的树结构);Swift 对带关联值的枚举
//     能**自动合成 JSON 编解码**,一行不用写。
//   ▸ 工作目录去哪拿?shell 是独立进程,不能"问"它(问就要往终端里打字)。
//     用系统调用 proc_pidinfo 直接查内核里该进程的 cwd —— lsof 同款原理,
//     零打扰、微秒级。
// ─────────────────────────────────────────────────────────────────────────────
import Darwin
import Foundation

/// 会话状态:窗口 frame + 分屏布局树 + 各 pane cwd。
/// 存 ~/Library/Application Support/YeTerm/session.json;
/// 铁律与 ShaderCache 同:任何读写故障静默降级(损坏的存档=没有存档)。
public struct SessionState: Codable {
    /// 布局树节点:叶子 = 一个 shell 会话;split = 一次分屏(children 顺序即摆放顺序)
    public indirect enum LayoutNode: Codable {
        case pane(cwd: String?)
        case split(vertical: Bool, weights: [Double], children: [LayoutNode])
    }

    public struct WindowState: Codable {
        /// [x, y, w, h](AppKit 屏幕坐标)
        public var frame: [Double]
        public var layout: LayoutNode
    }

    public var version = 1
    public var windows: [WindowState]
}

public enum SessionStore {
    static var path: String {
        NSHomeDirectory() + "/Library/Application Support/YeTerm/session.json"
    }

    public static func load() -> SessionState? {
        guard let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(SessionState.self, from: data),
              s.version == 1, !s.windows.isEmpty else { return nil }
        return s
    }

    public static func save(_ state: SessionState) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        // 【学】.atomic = 先写临时文件再原子改名,防止退出瞬间写出半截 JSON
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 查进程当前工作目录(proc_pidinfo / PROC_PIDVNODEPATHINFO,lsof 同款内核接口)。
    /// shell 已死/权限不足返回 nil —— 调用方按"没有 cwd"处理(恢复到默认目录)。
    public static func cwdOf(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n == size else { return nil }
        // 【学】C 定长字符数组(char[1024])在 Swift 里是巨型元组,
        //      withUnsafeBytes 取首地址按 C 字符串解码是标准姿势
        let dir = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return dir.isEmpty ? nil : dir
    }
}
