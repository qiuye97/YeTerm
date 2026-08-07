// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 显存账本:把「GPU 上到底躺着多少东西」逐项摊开
//
// 这个文件:一个**纯只读**的诊断口,不参与渲染、不改任何画面。开关是环境变量
//   YETERM_DEBUG_VRAM=1(与 YETERM_DEBUG_GLYPH / YETERM_DEBUG_ANIMBG 同一套路),
//   开了以后每 2 秒往 stderr 打一份清单:每张纹理多大、合计多少、Metal 自己
//   报的总分配量是多少,以及两者的差额(= 探针够不到的部分:drawable、
//   标签栏/OSD 各自的图集、驱动内部缓冲)。
//
// 为什么需要它:活动监视器只给一个总数,vmmap 只能看到"一块 16.1MB 的 GPU 区域",
//   都答不出「这 16MB 是谁的」。要谈优化就得先有分项账 —— 类比 Java 里光看
//   堆总量没用,得 jmap -histo 看每个类占多少。
//
// 语法看点:
//   `MTLTexture.allocatedSize` —— Metal 自报的实际字节数(含对齐/压缩,比
//     "宽×高×4" 手算准)。
//   `device.currentAllocatedSize` —— 整个 GPU device 当前分配总量,是这份
//     账本的"对账基准"。
//   元组数组 `[(String, MTLTexture?)]` —— 轻量的"名字→纹理"清单,不值得
//     为它单开一个 struct(Swift 里元组是一等公民,Java 得手写个小类)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Metal

/// 显存账本探针(诊断专用,缺省完全不参与运行)。
/// 用法:`YETERM_DEBUG_VRAM=1 YeTerm`,每 2 秒往 stderr 打一份分项清单。
enum VRAMProbe {
    /// 总开关:环境变量存在才工作(缺省零成本 —— 连清单都不会去拼)
    static let enabled = ProcessInfo.processInfo.environment["YETERM_DEBUG_VRAM"] != nil

    private static var lastDump: CFTimeInterval = 0

    /// 字节 → "12.5MB"(账本只关心 MB 量级,一位小数够用)
    static func mb(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
    }

    /// 打一份账(节流 2 秒;items 里 nil 的条目自动跳过 —— 没建的纹理不占账)。
    /// `extra` 给调用方补充非纹理口径的说明(如 pane 数、drawable 尺寸)。
    static func dump(device: MTLDevice, items: [(String, MTLTexture?)], extra: String = "") {
        guard enabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDump >= 2.0 else { return }
        lastDump = now

        var lines: [String] = []
        var sum = 0
        // 同名条目合并计数(多 pane 时 "pane.content" 会出现好几次)
        var merged: [(name: String, bytes: Int, count: Int)] = []
        for (name, tex) in items {
            guard let t = tex else { continue }
            let size = t.allocatedSize
            sum += size
            if let idx = merged.firstIndex(where: { $0.name == name }) {
                merged[idx].bytes += size
                merged[idx].count += 1
            } else {
                merged.append((name, size, 1))
            }
        }
        for m in merged.sorted(by: { $0.bytes > $1.bytes }) {
            let tag = m.count > 1 ? " ×\(m.count)" : ""
            lines.append(String(format: "  %-24@ %@%@", m.name as NSString, mb(m.bytes) as NSString, tag as NSString))
        }
        let total = device.currentAllocatedSize
        // 差额 = Metal 总量 − 探针能点到名的部分。这块含:CAMetalLayer 的
        // drawable(默认 3 张)、标签栏/OSD/粘贴确认框各自的 ContentRenderer
        // 图集、pipeline state 与着色器编译产物、驱动内部缓冲。
        let unaccounted = max(total - sum, 0)
        let head = "\n[vram] Metal 总分配=\(mb(total))  探针点名=\(mb(sum))  差额=\(mb(unaccounted))"
        let body = lines.joined(separator: "\n")
        let tail = extra.isEmpty ? "" : "\n  ── \(extra)"
        FileHandle.standardError.write(Data("\(head)\n\(body)\(tail)\n".utf8))
    }
}
