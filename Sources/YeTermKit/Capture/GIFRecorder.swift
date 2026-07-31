// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— GIF 录制器(v1.2 #7)
//
// 这个文件:把 CRT 画面连拍成动图。流程三步 ——
//   ① Timer 以 12fps 找 overlay 要"活帧"(带光标闪烁/噪点/动画相位的真实画面);
//   ② 每帧缩到半尺寸(GIF 是老格式,全尺寸文件大得离谱,半尺寸观感够用);
//   ③ 停止时用系统 ImageIO(CGImageDestination)逐帧写 GIF,零第三方依赖。
//
// 语法看点:`CGImageDestination` —— 苹果的"图像编码流水线":创建时报帧数,
//   逐帧 add(带每帧延时属性),finalize 一次性落盘;
//   `kCGImagePropertyGIFLoopCount = 0` = 无限循环(动图的常规约定)。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// CRT 画面 GIF 录制:12fps,半尺寸,上限 30 秒(到点自动停)。
/// 帧攒**压缩 PNG**(~100-200KB/帧,30s 约几十 MB;首版攒裸位图 30s 要 300MB+,
/// 用户要求放宽时长后必须换),停止时逐帧解码编 GIF。
final class GIFRecorder {
    private var frames: [Data] = []
    private var timer: Timer?
    private var frameProvider: (() -> CGImage?)?
    private var onAutoStop: (() -> Void)?

    let fps = 12.0
    let maxSeconds = 30.0
    var isRecording: Bool { timer != nil }
    var seconds: Double { Double(frames.count) / fps }

    /// 开始录制。`onAutoStop`:攒满上限自动停时回调(菜单状态要跟着变)
    func start(frameProvider: @escaping () -> CGImage?, onAutoStop: @escaping () -> Void) {
        stopTimer()
        frames.removeAll()
        self.frameProvider = frameProvider
        self.onAutoStop = onAutoStop
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let img = self.frameProvider?(), let half = Self.halfSize(img),
               let png = Self.pngData(half) {
                self.frames.append(png)
            }
            if self.seconds >= self.maxSeconds {
                self.stopTimer()
                self.onAutoStop?()
            }
        }
    }

    /// 停止并写盘。返回写成的 URL(nil = 没有帧/编码失败)
    func finish(writeTo url: URL) -> URL? {
        stopTimer()
        defer { frames.removeAll() }
        guard frames.count >= 2,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return nil }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        let frameProps = [kCGImagePropertyGIFDictionary:
                            [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        for data in frames {
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
        }
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// CGImage → PNG data(攒内存用压缩形态)
    private static func pngData(_ img: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    func cancel() {
        stopTimer()
        frames.removeAll()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 半尺寸重绘(sRGB 直算,与全链色彩纪律一致)
    private static func halfSize(_ img: CGImage) -> CGImage? {
        let w = img.width / 2, h = img.height / 2
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
