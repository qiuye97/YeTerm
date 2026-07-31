// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 把 GPU 画面存成 PNG 的小工具
//
// 这个文件:自动化测试的落盘端 —— 渲染结果(CGImage)写成 PNG 文件,
//   Claude 靠这些截图"看见"自己画的画面。用的是 ImageIO(macOS 系统自带的
//   图片编解码框架,类比 Java 的 ImageIO.write,连名字都一样)。
// 语法看点:`as CFURL` / `as CFString` —— Swift 类型与 CoreFoundation
//   (Apple 的底层 C 框架)类型的桥接转换,调 C API 时常见。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGWriter {
    enum WriteError: Error, CustomStringConvertible {
        case destinationFailed(String)
        case finalizeFailed(String)
        var description: String {
            switch self {
            case .destinationFailed(let p): return "无法创建 PNG 输出: \(p)"
            case .finalizeFailed(let p): return "PNG 写入失败: \(p)"
            }
        }
    }

    static func write(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.destinationFailed(path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WriteError.finalizeFailed(path)
        }
    }
}
