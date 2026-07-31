// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— Metal 的"数据库连接池"
//
// 这个文件:集中管理 GPU 编程的两样根基 ——
//   ▸ MTLDevice:代表 GPU 本身(类比 DataSource);
//   ▸ MTLCommandQueue:往 GPU 提交任务的队列(类比 Connection,先进先出)。
//   外加一个特色能力:**运行时编译着色器**。着色器(shader)= 跑在 GPU 上的
//   小程序(语言叫 MSL,长得像 C++),常规项目在 Xcode 里离线编译;
//   我们把 .metal 当文本文件打进包里,启动时现场编译 —— 好处:
//   ①无需完整 Xcode 工具链;②支持 ⌘R 改完着色器热重载,调参数飞快。
//   类比 JSP/Groovy 脚本:源码进包、运行时编译、改了即生效。
//
// 语法看点:
//   `enum ShaderError: Error` —— Swift 的错误就是实现 Error 协议的类型,
//     `throw`/`try`/`do-catch` 类比 Java 异常,但必须在调用处写 try 显式标记。
//   `init?()` —— "可失败构造器":条件不满足返回 nil 而不是抛异常
//     (调用方用 if let 接,天然强制处理失败分支)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Metal

/// Metal 上下文:device/queue + **运行时**着色器编译。
/// 本项目不依赖离线 metal 编译器 —— .metal 以文本资源入包,
/// `makeLibrary(source:)` 由系统 Metal 框架前端现场编译(CLT-only 也可用)。
/// 源加载顺序:`shaderDirOverride`(--shader-dir / YETERM_SHADER_DIR,热重载用)→ Bundle.module。
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue

    /// 热重载重定向:指向文件系统里的 Shaders 目录
    var shaderDirOverride: URL?

    private var libraryCache: [String: MTLLibrary] = [:]

    // 管线二进制缓存(v1.2 #1):首次创建管线时才决定启不启用 ——
    // shaderDirOverride 是 init 之后才被调用方设置的,不能在 init 里判断。
    private var shaderCache: ShaderCache?
    private var shaderCacheResolved = false

    enum ShaderError: Error, CustomStringConvertible {
        case sourceNotFound(String)
        case compileFailed(name: String, log: String)
        case functionNotFound(String)
        var description: String {
            switch self {
            case .sourceNotFound(let n): return "着色器源未找到: \(n).metal"
            case .compileFailed(let n, let log): return "着色器编译失败 [\(n).metal]:\n\(log)"
            case .functionNotFound(let f): return "着色器函数未找到: \(f)"
            }
        }
    }

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            FileHandle.standardError.write(Data("Metal 设备不可用\n".utf8))
            return nil
        }
        device = dev
        queue = q
        if let dir = ProcessInfo.processInfo.environment["YETERM_SHADER_DIR"] {
            shaderDirOverride = URL(fileURLWithPath: dir, isDirectory: true)
        }
    }

    /// 编译(或取缓存)一个 .metal 源文件。`name` 不带扩展名,如 "Passthrough"。
    func library(named name: String) throws -> MTLLibrary {
        if let cached = libraryCache[name] { return cached }
        let source = try loadSource(name: name)
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            // 前端编译计时:系统编译服务自带全局缓存,热启动这里也会明显变快;
            // 与 ShaderCache 的后端日志合看即得冷/热启动对比(v1.2 #1 验收项)
            let t0 = CFAbsoluteTimeGetCurrent()
            let lib = try device.makeLibrary(source: source, options: options)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            FileHandle.standardError.write(Data("[Shader] 前端编译 \(name).metal \(ms)ms\n".utf8))
            libraryCache[name] = lib
            return lib
        } catch {
            // localizedDescription 含带行号的完整编译日志
            throw ShaderError.compileFailed(name: name, log: error.localizedDescription)
        }
    }

    /// 创建渲染管线的统一漏斗(v1.2 #1):所有 makeRenderPipelineState 一律走这里,
    /// 好让二进制缓存覆盖全部管线。`--shader-dir` 热重载模式下缓存整体旁路。
    func makePipeline(_ desc: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        if !shaderCacheResolved {
            shaderCacheResolved = true
            if shaderDirOverride == nil {
                shaderCache = ShaderCache(device: device)
            }
        }
        guard let cache = shaderCache else {
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        return try cache.makePipeline(desc)
    }

    /// 热重载:清缓存,下次取用即重编
    func invalidateCache() {
        libraryCache.removeAll()
    }

    func function(_ fnName: String, library name: String) throws -> MTLFunction {
        guard let fn = try library(named: name).makeFunction(name: fnName) else {
            throw ShaderError.functionNotFound(fnName)
        }
        return fn
    }

    private func loadSource(name: String) throws -> String {
        if let dir = shaderDirOverride {
            let url = dir.appendingPathComponent("\(name).metal")
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal", subdirectory: "Shaders"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            throw ShaderError.sourceNotFound(name)
        }
        return s
    }
}
