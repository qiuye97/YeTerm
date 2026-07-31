// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— GPU 管线的"编译产物缓存"(v1.2 #1)
//
// 这个文件:解决"每次启动都要现场编译着色器"的耗时问题。
//   本项目的 .metal 着色器是运行时编译的(见 MetalContext 导读),编译分两段:
//   ▸ 前端:MSL 源码 → 中间码(makeLibrary,类比 javac 编 .class);
//   ▸ 后端:中间码 → 本机 GPU 机器码(makeRenderPipelineState,
//     类比 JIT 把字节码编成本机指令 —— 这段在慢机器上是启动大头)。
//   MTLBinaryArchive 就是 Metal 官方的"JIT 产物落盘"机制:第一次启动把
//   编好的 GPU 机器码存进一个档案文件,以后启动直接取,后端编译整个跳过。
//   (前端那段系统自带的编译服务也有全局缓存,二次启动同样快。)
//
// 缓存失效怎么办?—— 学数据库缓存的思路:内容寻址。
//   缓存文件名 = SHA-256(全部着色器源码 + GPU 型号 + 系统版本) 的前 16 位。
//   app 升级改了着色器 → 哈希变 → 直接找不到旧文件 → 自动重新编译,
//   永远不会"用错缓存"。旧哈希的文件顺手删掉,不留垃圾。
//
// 语法看点:
//   `try?` —— "失败就当 nil"的吞错写法:缓存的铁律是**坏了也不能影响渲染**,
//     所以本文件里所有缓存操作都不往外抛错,失败就退回无缓存路径。
//   `CryptoKit` 的 SHA256 —— 苹果自带的哈希库,类比 Java 的 MessageDigest。
// ─────────────────────────────────────────────────────────────────────────────
import CryptoKit
import Foundation
import Metal

/// 管线二进制缓存:MTLBinaryArchive 落盘,二次启动跳过后端编译(M1 慢机收益最大)。
/// 铁律:任何缓存故障都静默降级为"现场编译",绝不影响画面正确性。
/// `--shader-dir` 热重载模式下由 MetalContext 决定不创建本对象(源码随时在变,缓存无意义)。
final class ShaderCache {
    private let device: MTLDevice
    private var archive: MTLBinaryArchive?
    private let archiveURL: URL
    private var loggedHit = false

    /// 缓存目录:~/Library/Application Support/YeTerm/ShaderCache/
    private static var cacheDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("YeTerm/ShaderCache", isDirectory: true)
    }

    /// 内容寻址 key:全部 .metal 源码(按文件名排序拼接)+ GPU 名 + 系统版本。
    /// 【学】任何一项变了(改着色器 / 换机器 / 升系统)哈希都变 → 旧缓存自然失效。
    private static func contentKey(device: MTLDevice) -> String? {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "metal",
                                            subdirectory: "Shaders"),
              !urls.isEmpty else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("yeterm-shadercache-v1".utf8))
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let src = try? Data(contentsOf: url) else { return nil }
            hasher.update(data: Data(url.lastPathComponent.utf8))
            hasher.update(data: src)
        }
        hasher.update(data: Data(device.name.utf8))
        hasher.update(data: Data(ProcessInfo.processInfo.operatingSystemVersionString.utf8))
        // 【学】.map { String(format: "%02x", $0) } = 逐字节转十六进制字符串(Java 常见套路)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    init?(device: MTLDevice) {
        guard let dir = Self.cacheDir, let key = Self.contentKey(device: device) else { return nil }
        self.device = device
        let fileName = "pipelines-\(key).mtlbin"
        archiveURL = dir.appendingPathComponent(fileName)

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 清掉旧哈希的档案(app 更新/升系统后残留)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                    includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("pipelines-")
                && f.lastPathComponent != fileName {
                try? FileManager.default.removeItem(at: f)
            }
        }

        let desc = MTLBinaryArchiveDescriptor()
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            desc.url = archiveURL  // 热启动:从磁盘装载既有档案
        }
        // 装载失败(文件损坏/格式过期)→ 降级为空档案重新积累
        if let a = try? device.makeBinaryArchive(descriptor: desc) {
            archive = a
        } else {
            try? FileManager.default.removeItem(at: archiveURL)
            let empty = MTLBinaryArchiveDescriptor()
            archive = try? device.makeBinaryArchive(descriptor: empty)
        }
        if archive == nil { return nil }
    }

    /// 创建管线:先查档案(命中=零后端编译),未命中现场编译并落盘。
    func makePipeline(_ desc: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        guard let archive else { return try device.makeRenderPipelineState(descriptor: desc) }
        desc.binaryArchives = [archive]

        // 【学】.failOnBinaryArchiveMiss = "只准查缓存,查不到就报错"——
        //      我们故意用报错来精确区分命中/未命中(命中路径完全不触发编译器)。
        if let ps = try? device.makeRenderPipelineState(descriptor: desc,
                                                        options: .failOnBinaryArchiveMiss,
                                                        reflection: nil) {
            if !loggedHit {
                loggedHit = true
                Self.log("管线缓存命中(热启动,零后端编译)← \(archiveURL.lastPathComponent)")
            }
            return ps
        }

        // 未命中:现场编译(冷启动路径),编好立刻收进档案并落盘
        let t0 = CFAbsoluteTimeGetCurrent()
        let ps = try device.makeRenderPipelineState(descriptor: desc)
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        Self.log("后端编译 \(desc.fragmentFunction?.name ?? "?") \(ms)ms(未命中,已入档)")
        try? archive.addRenderPipelineFunctions(descriptor: desc)
        serialize()
        return ps
    }

    /// 档案落盘:先写临时文件再原子替换(多窗口各持一份档案对象,写坏了谁也不迁就谁)。
    /// 【学】"写临时文件 + rename"是所有平台防半截文件的标准姿势(rename 是原子操作)。
    private func serialize() {
        guard let archive else { return }
        let tmp = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(archiveURL.lastPathComponent)-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try archive.serialize(to: tmp)
            _ = try FileManager.default.replaceItemAt(archiveURL, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Self.log("档案落盘失败(忽略,下次冷启重编): \(error.localizedDescription)")
        }
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[ShaderCache] \(msg)\n".utf8))
    }
}
