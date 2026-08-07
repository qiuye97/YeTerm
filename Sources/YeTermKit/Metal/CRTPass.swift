// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— CPU 与 GPU 之间的"参数合同"
//
// 这个文件:两样东西 ——
//   ① CRTUniforms 结构体:CRT 着色器的全部旋钮(时间/弧度/颜色/光标位置…)。
//     ⚠️ 它和 Shaders/CRT.metal 里的同名 struct 必须**逐字节完全一致**
//     (总 208 字节):CPU 按这个布局写内存,GPU 按那个布局读 ——
//     错一个字段顺序,画面就"神秘错乱"。类比前后端手写二进制协议对接,
//     没有 JSON 那层容错,所以两边都标了字节偏移注释。
//   ② 几个换算函数:虚拟分辨率(扫描线多粗多密,从字体尺寸推导)、
//     光栅化强度、十六进制颜色解析(#RRGGBB ÷256——照抄原版的"错误"
//     才能逐像素一致,这条是逐像素对齐原版的前提)。
//
// 语法看点:
//   `var x: SIMD2<Float> = .zero` —— ".zero" 是"类型推断的静态成员"简写,
//     等于 SIMD2<Float>.zero(Swift 知道类型时可以只写点后面的部分)。
//   struct 属性带默认值 = 免写构造器(memberwise init 自动合成)。
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Metal
import MetalKit
import simd

/// CRT pass 的 Swift 侧:uniform 结构(与 CRT.metal 的 CRTUniforms 逐字节对齐,80B)
/// 与噪点纹理装载。
struct CRTUniforms {
    var time: Float = 0
    var screenCurvature: Float = 0.3           // = 用户值 0.5 × screenCurvatureSize 0.6(master)
    var rasterizationIntensity: Float = 1.0    // M1 换 smoothstep(2,4,screenDensity) 推导
    var chromaColor: Float = 1.0               // 1=透传原色;0=纯磷光单色
    var virtualResolution: SIMD2<Float> = .init(465, 274)
    var scaleNoiseSize: SIMD2<Float> = .init(1, 1)
    var fontColor: SIMD4<Float> = .init(1, 1, 1, 1)
    var backgroundColor: SIMD4<Float> = .init(0, 0, 0, 1)
    var staticNoise: Float = 0
    var rasterMode: Int32 = 1                  // 0 无/1 扫描线/2 像素/3 子像素/4 modern
    var contentScale: SIMD2<Float> = .init(1, 1)   // drawable→内容映射比(letterbox)
    var cursorRectUV: SIMD4<Float> = .zero     // 光标块(内容 UV 空间 x,y,w,h;原点左上)
    var cursorOn: Float = 0                    // >0.5 画光标
    var cursorStyle: Float = 0                 // 0 块/1 下划线/2 竖线
    var flickering: Float = 0                  // 闪烁(默认关,配置驱动)
    var horizontalSyncStrength: Float = 0      // = lint(0.05,0.35,hsync);0=关
    var jitter: Float = 0                      // 抖动(平方效应在 shader 内)
    var glowingLine: Float = 0                 // 移动亮线(此值已 ×0.2)
    var bloomAmount: Float = 0                 // = bloom × 2.5;0=关
    var brightness: Float = 1                  // = lint(0.5,1.5,b);1=中性
    var burnIn: Float = 0                      // >0 启用余辉
    var burnInTime: Float = 0                  // = 1/lint(0.16,1.6,burnIn)
    var burnInLastUpdate: Float = 0
    var powerOnProgress: Float = 1             // 开机动画进度(v1.1):<1 播放中;默认 1=稳定,不影响任何旧输出
    var frameColor: SIMD4<Float> = .init(1, 1, 1, 1)   // CPU 侧按 M_TerminalFrame.qml 公式预混
    var frameSize: Float = 0                   // = _frameSize × 0.05
    var screenRadius: Float = 0                // 圆角(物理像素)
    var ambientLight: Float = 0                // 原值(master:只作用于 frame 层)
    var frameShininess: Float = 0.1            // = _frameShininess × 0.5
    var viewportSize: SIMD2<Float> = .init(1, 1)   // 每帧填 drawable 像素
    var rgbShift: Float = 0                    // 存配置原值;每帧换算 ×4/内容宽px
    var frameOn: Float = 0
    var contentOffset: SIMD2<Float> = .zero    // margin(存原值 0~1;每帧换算 UV)
    var bloomPad: SIMD2<Float> = .zero         // 辉光纹理出血边距(UV;光晕可溢入留白区)
    var degauss: Float = 0                     // 消磁波纹包络(v1.2 #13;0=关)
    var colorPassthrough: Float = 0            // >0.5=普通模式原色直出 → 216
    /// 发光模型(v1.4;主题字段 emissiveModel):0 = convertWithChroma(crterm 原版语义,
    /// 缺省)/ 1 = 自发光模型(背景基底 + 磷光加法层 + 色相保持压缩)。
    /// 详见 CRT.metal 里 emissiveLight/tonemapPreservingHue 两函数上方的长注释。
    var emissiveModel: Float = 0               // → 220
    /// 辉光风格(v1.4;主题字段 bloomStyle):0 = 归一化高斯(缺省)/ 1 = 光晕 halation。
    /// **只在 CPU 侧读**(EffectChain 据此选 blur_fragment / blur_max_fragment),
    /// 着色器不读 —— 但仍须在 CRT.metal 同位置声明以维持二进制合同(先例:frameSize)。
    /// 放这里而不是单开一条属性通路:overlay/harness 都已在传 uniforms,零额外接线。
    var bloomStyle: Float = 0                  // → 224
    /// 白热化(v1.4;主题字段 overdrive/overdriveKnee)——「文字发光」的**自身**那一半:
    /// 零半径逐像素传递函数,按该像素的束驱动量把颜色往白推。与辉光(照亮周围)正交。
    /// 详见 CRT.metal 里 applyOverdrive 上方的长注释(含实测诊断与数值验证)。
    var overdrive: Float = 0                   // → 228;0 = 关(缺省,逐位等同于没这段)
    var overdriveKnee: Float = 0.20            // → 232(两侧同步;0.20 由真 CRT 照片定标)
    /// 光晕形状(v1.4;主题字段 bloomShape):0 = 单层高斯(缺省)/ 1 = 紧核 + 长尾(双尺度)。
    /// 同 bloomStyle:**只在 CPU 侧读**,着色器不读,此处占位维持二进制合同。
    var bloomShape: Float = 0                  // → 236(两侧同步)
    // ---- 背景图片(v1.5.1 用户追加:CRT 模式也能铺背景图)----
    /// >0.5 = texture(4) 绑了背景图,着色器用它替换染色公式里的「屏幕底色」项。
    /// 0(缺省)= 三个字段一概不读,输出逐比特等同于没这段。
    var bgImageOn: Float = 0                   // → 240
    /// aspect-fill 的 UV 缩放(`uv' = (uv-0.5)*scale+0.5`,与合成层 plain_bg_fill_fragment
    /// 同一套语义:按比例盖满画面、长出来的边裁掉,不拉伸)。
    /// ⚠️ 排这个位置是因为 float2 要 **8 字节对齐**:236 不是 8 的倍数,240 才是 ——
    /// 夹在两个 float 中间恰好前后无空洞,两侧结构体大小同为 256(含尾部对齐)。
    var bgImageUVScale: SIMD2<Float> = .init(1, 1)   // 240 → 248
    /// 荧光染色:0 = 保留图片原色(缺省,图当屏幕底图)/ 1 = 整张图过 convertWithChroma
    /// (磷光单色,像真 CRT 在显示这张图)。中间值可插值,目前设置页只给 0/1 两档。
    var bgImageChroma: Float = 0               // 248 → 252
    var _padScreenInset: Float = 0             // 252 → 256(下一个 float2 需 8 字节对齐)
    /// 屏幕内缩(2026-08-07 用户需求「机壳最小带」):屏幕玻璃区从窗口边缘往里缩的量
    /// (每侧,padding 变换语义;x=左右 y=上下)。缺省 .zero = 屏幕充满窗口(1.2 语义,
    /// 原行为逐比特不变)。机壳开启时 overlay 每帧按标题栏高度填 y —— 上下腾出
    /// 等宽机壳带,红绿灯/标题落在带的垂直正中。
    var screenInset: SIMD2<Float> = .zero      // 256 → 264(结构体按 float4 对齐补到 272)
}

enum CRTPass {
    /// 虚拟分辨率推导(G3 设计:从 cell 尺寸自动推导,与任意字体解耦)。
    /// **粒度对齐 crterm 1.2 语义**(2026-07-25 勘差):它的虚拟像素 = 点阵字体的
    /// 字体像素 —— 一格高仅 ~13 虚拟行(Terminus 12px+1 行距),且内置字体
    /// baseScaling ≥ 2.4~3 保证每虚拟像素在屏上 ≥3 逻辑 px,所以扫描线/像素块
    /// 又粗又实。矢量字体按同规则折算:每格 13 行,且虚拟像素不小于 3 逻辑 px;
    /// 每格整数条与行对齐防拍频(拍频=暗带扫过笔画腰部,M1a 实测教训)。
    static func virtualResolution(cols: Int, rows: Int, cellPx: (w: Int, h: Int),
                                  scale: Float = 2.0) -> SIMD2<Float> {
        let cellHLogical = Float(cellPx.h) / scale
        let pitchLogical = max(3.0, cellHLogical / 13.0)
        let ny = max(1, Int((cellHLogical / pitchLogical).rounded()))
        let pitchPx = Float(cellPx.h) / Float(ny)
        let nx = max(1, Int((Float(cellPx.w) / pitchPx).rounded()))
        return .init(Float(cols * nx), Float(rows * ny))
    }

    /// 屏幕级虚拟分辨率(单显示器分屏合成用):pitch 仍从焦点字体推导
    /// (同上规则:每格 13 行、≥3 逻辑 px),但覆盖整块合成画面 ——
    /// 扫描线/像素栅格横贯整个"显示器",与 crterm 的 screen-space 光栅一致。
    static func virtualResolutionScreen(widthPx: Int, heightPx: Int,
                                        cellPx: (w: Int, h: Int), scale: Float) -> SIMD2<Float> {
        guard cellPx.h > 0 else { return .init(Float(widthPx) / 6.0, Float(heightPx) / 6.0) }
        let cellHLogical = Float(cellPx.h) / scale
        let pitchLogical = max(3.0, cellHLogical / 13.0)
        let ny = max(1, Int((cellHLogical / pitchLogical).rounded()))
        let pitchY = Float(cellPx.h) / Float(ny)
        let nx = max(1, Int((Float(cellPx.w) / pitchY).rounded()))
        let pitchX = Float(cellPx.w) / Float(nx)
        return .init(Float(widthPx) / pitchX, Float(heightPx) / pitchY)
    }

    /// 光栅化强度:原版 `smoothstep(2,4,screenDensity)`,density 按**物理像素**算
    /// (1.2 的 screenResolution = 窗口 × devicePixelRatio,已核实;Retina 上
    /// 内置字体 pitch ≥6 物理 px → 强度拉满,这正是 crterm 扫描线「粗而实」的来源)。
    static func rasterizationIntensity(drawableH: Int, vresY: Float, scale: Float = 2.0) -> Float {
        let density = Float(drawableH) / max(vresY, 1)
        let t = min(max((density - 2) / 2, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `#RRGGBB` → 颜色向量。对齐原版 `strToColor`:各分量 **除以 256**(非 255)。
    static func color(hex: String) -> SIMD4<Float>? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD4<Float>(Float((v >> 16) & 0xff) / 256.0,
                            Float((v >> 8) & 0xff) / 256.0,
                            Float(v & 0xff) / 256.0,
                            1.0)
    }

    /// 装载噪点纹理(RGBA 四通道独立数据,**不可预乘 alpha** → 用 MTKTextureLoader)
    static func loadNoiseTexture(device: MTLDevice) -> MTLTexture? {
        guard let url = Bundle.module.url(forResource: "allNoise512", withExtension: "png", subdirectory: "Textures") else {
            FileHandle.standardError.write(Data("噪点纹理资源缺失\n".utf8))
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(URL: url, options: [
            .SRGB: false,                       // 原始数值,不做色彩空间转换
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .allocateMipmaps: false,
        ])
    }
}
