// ─────────────────────────────────────────────────────────────────────────────
// YeTerm —— 复古 CRT 终端 (macOS)
// Copyright (C) 2026 qiuye97
//
// 本文件的 CRT 特效数学**移植自 cool-retro-term**(github.com/Swordfish90/
// cool-retro-term)的 GLSL 着色器,原作 Copyright (C) Filippo Scognamiglio 等,
// 授权 GPL-3.0-or-later。因此本文件及整个 YeTerm 亦以 GPL-3.0-or-later 分发。
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— CRT 主着色器:全部复古特效的发生地(GPU 编程从这学起)
//
// 这是一段 MSL(Metal Shading Language,长得像 C++)代码,跑在 GPU 上。
// 核心概念一句话:下面的 crt_fragment 函数**每个像素各跑一次**——
//   一帧 200 万像素就是 200 万次并行调用(GPU 有几千个核,这是它的主场)。
//   函数拿到自己的坐标 uv(0~1),决定"我这个像素该是什么颜色"。
// 类比 Web:相当于给整个页面套一层 WebGL 自定义 filter,每像素算颜色。
//
// 读法建议(跟着 crt_fragment 从上往下,就是特效的叠加顺序):
//   弧度扭曲 distortCoordinates → 水平抖动/闪烁 → 雪花噪点/移动亮线 →
//   采样内容纹理(含 RGB 色差) → 余辉合成 → 光标反色 → 扫描线/像素栅格
//   applyRasterization → 荧光染色 convertWithChroma → 辉光叠加 →
//   机壳/反射带 computeFrame。每段都注明了 cool-retro-term 原版出处。
//
// ⚠️ 开头的 CRTUniforms 结构体与 Swift 侧 CRTPass.swift 必须逐字节一致
//   (CPU 填参数、GPU 读参数的"二进制合同",详见那边导读)。
// ─────────────────────────────────────────────────────────────────────────────
#include <metal_stdlib>
using namespace metal;

// ============================================================================
// CRT 后处理(M0 子集)—— 逐行移植自 cool-retro-term master:
//   cool-retro-term  shaders/terminal_static.frag  (distortCoordinates :36-41)
//   cool-retro-term  shaders/terminal_dynamic.frag (applyRasterization :66-117,
//                                       convertWithChroma :123-132, 噪点项 :144-149)
// M0 只做:屏幕弧度 + 光栅化(扫描线/像素/子像素)+ chroma 着色 + 雪花噪点(调试变体)。
// M1b 补齐:burn-in / bloom / glowingLine / jitter / h-sync / flicker(顶点级)/ frame,
//   并把 rasterMode 等换成 function constants(对应原版 ~100 个 .qsb 变体):
//   [[function_constant(0)]] CRT_RASTER_MODE
//   [[function_constant(1)]] CRT_BURN_IN
//   [[function_constant(2)]] CRT_DISPLAY_FRAME
//   [[function_constant(3)]] CRT_CHROMA
// 色彩纪律:全链 sRGB 编码值直算(bgra8Unorm,非 _srgb)。
// ============================================================================

struct FSQuadOut {
    float4 position [[position]];
    float2 uv;
};

// 与 Swift 侧 CRTUniforms 逐字段对齐(总 112 字节)
struct CRTUniforms {
    float time;                    //  0
    float screenCurvature;         //  4
    float rasterizationIntensity;  //  8
    float chromaColor;             // 12
    float2 virtualResolution;      // 16
    float2 scaleNoiseSize;         // 24
    float4 fontColor;              // 32
    float4 backgroundColor;        // 48
    float staticNoise;             // 64
    int   rasterMode;              // 68  (0 无 / 1 扫描线 / 2 像素 / 3 子像素 / 4 modern=无)
    float2 contentScale;           // 72  drawable→内容纹理的映射比(≥1;letterbox,内容 1:1 像素呈现)
    float4 cursorRectUV;           // 80  光标块(内容纹理 UV 空间 x,y,w,h;原点左上)
    float cursorOn;                // 96  >0.5 画光标(闪烁由 CPU 侧相位决定)
    float cursorStyle;             // 100 0=块 1=下划线 2=竖线(macOS 终端三态)
    float flickering;              // 104 画面闪烁(原版顶点级,此处按 1.1.1 fallback 在片元算)
    float horizontalSyncStrength;  // 108 = lint(0.05,0.35,horizontalSync);0=关
    float jitter;                  // 112 抖动(平方效应:位移已含 jitter,再乘一次)
    float glowingLine;             // 116 移动亮线(喂入前 ×0.2,QML 同款)
    float bloomAmount;             // 120 = 配置 bloom × 2.5(QML 同款);0=关
    float brightness;              // 124 = lint(0.5,1.5,配置 brightness);1=中性
    float burnIn;                  // 128 >0 启用余辉合成
    float burnInTime;              // 132 = 1/lint(0.16,1.6,burnIn)(秒)
    float burnInLastUpdate;        // 136 最近累积时刻(秒)
    float powerOnProgress;         // 140 开机动画进度(v1.1):<1 播放中,≥1 稳定(默认)
    float4 frameColor;             // 144 机壳颜色(CPU 侧按 M_TerminalFrame.qml 公式预混)
    float frameSize;               // 160 = _frameSize × 0.05(弧度 padding 同用)
    float screenRadius;            // 164 圆角半径(物理像素,= lint(4,120,_r)×scale)
    float ambientLight;            // 168 环境光(原值;master 语义:只作用于 frame 层)
    float frameShininess;          // 172 = _frameShininess × 0.5
    float2 viewportSize;           // 176 drawable 物理像素尺寸
    float rgbShift;                // 184 色差位移(内容 UV;CPU 侧 = 配置值×4/内容宽px)
    float frameOn;                 // 188 >0.5 启用机壳层
    float2 contentOffset;          // 192 内容留白 margin(= marginPx/contentPx,UV)
    float2 bloomPad;               // 200 辉光纹理出血边距(UV)→ 208
    float degauss;                 // 208 消磁波纹包络(v1.2 #13;0=关,CPU 侧 0.8s 指数衰减)
    float colorPassthrough;        // 212 >0.5=普通终端模式:内容原色直出,零染色 → 216
    float emissiveModel;           // 216 发光模型 0=convertWithChroma(默认)/1=自发光 → 220
    float bloomStyle;              // 220 辉光风格 0=高斯/1=halation。**着色器不读**,
                                   //     CPU 侧 EffectChain 据此选 blur 函数;此处仅占位
                                   //     维持二进制合同(先例:frameSize)→ 224
    float overdrive;               // 224 白热化强度 0=关(缺省)~1;笔画芯往白推的最大幅度
    float overdriveKnee;           // 228 白热化起点(束驱动量阈值,低于此不发白)→ 232
    float bloomShape;              // 232 光晕形状 0=单层/1=紧核+长尾。**着色器不读**,
                                   //     同 bloomStyle 由 CPU 侧 EffectChain 消费 → 236
    // ── 背景图片(v1.5.1 用户追加:CRT 模式也能铺背景图)────────────────────
    // 缺省 bgImageOn=0 时下面三个字段一概不读,染色退化成原来的 backgroundColor
    // —— 逐比特等同于没有这段(已用 --render-demo 对拍确认)。
    float bgImageOn;               // 236 >0.5 = texture(4) 绑了背景图 → 240
    float2 bgImageUVScale;         // 240 aspect-fill 的 UV 缩放(float2 要 8 字节对齐,
                                   //     故排在两个 float 中间,前后无空洞)→ 248
    float bgImageChroma;           // 248 0=保留图片原色(缺省)/1=整张图荧光染色 → 252
                                   //     (结构体按 float4 的 16 字节对齐补到 256)
};

// 二进制合同的编译期保险(v1.5.1 加):Swift 侧 CRTPass.swift 的同名结构体
// stride 必须同为 256。两边任一处漏改字段,着色器**编译当场就炸**,而不是等到画面
// 神秘错乱才回头猜 —— float2/float4 的对齐规则最容易在追加字段时踩空
// (offsetof 在 MSL 里不可用,只能钉总大小;逐字段偏移由两侧的注释和探针盯着)。
static_assert(sizeof(CRTUniforms) == 256, "CRTUniforms 与 Swift 侧 stride 不一致");

static inline float min2(float2 v) { return min(v.x, v.y); }
static inline float rgb2grey(float3 v) { return dot(v, float3(0.21, 0.72, 0.04)); }

// terminal_static.frag:36-41 / terminal_frame.frag:22-27(padded 版,两处语义必须一致)
static inline float2 distortCoordinates(float2 coords, float screenCurvature, float frameSize) {
    float2 padded = coords * (float2(1.0) + frameSize * 2.0) - frameSize;
    float2 cc = padded - float2(0.5);
    float dist = dot(cc, cc) * screenCurvature;
    return padded + cc * (1.0 + dist) * dist;
}

static inline float prod2(float2 v) { return v.x * v.y; }
static inline float rand2(float2 v) { return fract(sin(dot(v, float2(12.9898, 78.233))) * 43758.5453); }

// terminal_frame.frag:29-36
static float roundedRectSdfPixels(float2 p, float2 topLeft, float2 bottomRight,
                                  float radiusPixels, float2 viewportSize) {
    float2 sizePixels = (bottomRight - topLeft) * viewportSize;
    float2 centerPixels = (topLeft + bottomRight) * 0.5 * viewportSize;
    float2 localPixels = p * viewportSize - centerPixels;
    float2 halfSize = sizePixels * 0.5 - float2(radiusPixels);
    float2 d = abs(localPixels) - halfSize;
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radiusPixels;
}

static inline float2 positiveLog(float2 x) {
    return clamp(log(max(x, float2(1e-6))), float2(0.0), float2(100.0));
}

// 1.2 世代 TerminalFrame.qml 片元逐行移植(用户在用的版本;master 的 SDF 机壳已退役):
// 暗角 + 对数边框高光 + 屏内边缘阴影;出屏区不透明度 ~0.9-1.0,余下份额透出
// 反射带(屏幕光映照机壳的通道)。输出预乘 alpha(与原版 gl_FragColor 一致)。
static float4 computeFrame(float2 staticCoords, float2 coords, constant CRTUniforms &u) {
    // 性能短路(v1.1 #3 追加,数学等价):机壳只在屏幕边缘/屏外有贡献。
    // 屏内到边距离 d>0.2 时,screenShadow 的两因子均 ≥ log(0.2·coeff+1),
    // coeff≥10(amb≤1)⇒ 因子 ≥ log(3)≈1.10 ⇒ ss.x·ss.y ≥ 1 ⇒ alpha 恒 0
    // ⇒ 返回值恒 (0,0,0,0)。中心 ~36% 像素跳过全部 log/pow/sqrt 超越函数。
    // (改动前后逐像素 cmp 相同才允许保留 —— 见 gpuopt 等价性验证记录)
    float2 dEdge = min(coords, float2(1.0) - coords);
    if (min(dEdge.x, dEdge.y) > 0.2) {
        return float4(0.0);
    }
    float amb = 0.2 + 0.6 * clamp(u.ambientLight, 0.0, 1.0);   // lint(0.2,0.8,ambient)
    float coeff = 20.0 - 10.0 * amb;                            // lint(20,10,_ambientLight)

    float2 vig = staticCoords * (float2(1.0) - staticCoords.yx);
    float vignette = pow(max(vig.x * vig.y, 0.0) * 15.0, 0.25);
    float3 color = u.frameColor.rgb * (1.0 - vignette);

    float2 fs = positiveLog(-coords * coeff + float2(1.0))
              + positiveLog(coords * coeff - float2(coeff - 1.0));
    float frameShadow = sqrt(max(max(fs.x, fs.y), 0.0));
    color *= frameShadow;

    float2 outLow = float2(1.0) - step(float2(0.0), coords);
    float2 outHigh = step(float2(1.0), coords);
    float alpha = clamp(outLow.x + outLow.y + outHigh.x + outHigh.y, 0.0, 1.0);
    alpha *= mix(1.0, 0.9, frameShadow);

    float2 ss = positiveLog(coords * coeff + float2(1.0))
              * positiveLog(-coords * coeff + float2(coeff + 1.0));
    float screenShadow = 1.0 - ss.x * ss.y;
    alpha = clamp(max(0.8 * screenShadow, alpha), 0.0, 1.0);

    return float4(color * alpha, alpha);
}

// 光栅化。扫描线/像素 = **1.2 世代公式**(ShaderTerminal_1.1.1 static:429-446,
// 用户参照物;v1.1 #6 勘差):smoothstep 三角波剖面、暗带压到 50% —— 这才是
// crterm"粗而实"条纹的亮度剖面。master 的 pixelLow/High 版(±16%)弱一倍,
// 曾靠"背景噪点误吃光栅化"的私生层序撑观感,层序修正后必须换回真公式。
// 子像素(mode 3)是 master 新增模式,保留 master 公式(terminal_dynamic.frag)。
static float3 applyRasterization(float2 screenCoords, float3 texel,
                                 float2 virtualRes, float intensity, int mode) {
    if (mode == 0 || mode == 4 || intensity <= 0.0) {
        return texel;
    }

    if (mode == 1 || mode == 2) {                      // 扫描线 / 像素栅格(1.2 版)
        float2 rc = fract(screenCoords * virtualRes);
        float valY = smoothstep(0.0, 0.5, rc.y) - smoothstep(0.5, 1.0, rc.y);
        float result = mix(0.5, 1.0, valY);
        if (mode == 2) {
            float valX = smoothstep(0.0, 0.5, rc.x) - smoothstep(0.5, 1.0, rc.x);
            result *= mix(0.5, 1.0, valX);
        }
        // intensity = 物理像素密度渐变(低密度防摩尔纹,master 语义,两版通用)
        return texel * mix(1.0, result, intensity);
    } else if (mode == 3) {                            // 子像素(RGB 磷光条)
        const float INTENSITY = 0.30;
        const float BRIGHTBOOST = 0.30;
        const float SUBPIXELS = 3.0;
        float3 offsets = float3(3.141592654) * float3(0.5, 0.5 - 2.0 / 3.0, 0.5 - 4.0 / 3.0);

        float2 omega = float2(3.141592654) * float2(2.0) * virtualRes;
        float2 angle = screenCoords * omega;
        float3 xfactors = (SUBPIXELS + sin(angle.x + offsets)) / (SUBPIXELS + 1.0);

        float3 result = texel * xfactors;
        float3 pixelHigh = ((1.0 + BRIGHTBOOST) - (0.2 * result)) * result;
        float3 pixelLow  = ((1.0 - INTENSITY) + (0.1 * result)) * result;

        float2 coords = fract(screenCoords * virtualRes) * 2.0 - float2(1.0);
        float mask = 1.0 - abs(coords.y);

        float3 rasterizationColor = mix(pixelLow, pixelHigh, mask);
        return mix(texel, rasterizationColor, intensity);
    }
    return texel;
}

// terminal_dynamic.frag:123-132
//
// v1.5.1 背景图片:原式最后一步是 `mix(backgroundColor, 前景色, 内容亮度)` ——
// 那个 backgroundColor 就是"屏幕上没被电子束打亮的地方是什么颜色"。**背景图要做的
// 事,恰好就是把这一项换成图片的像素**,别的一律不动:
//   · 内容亮度 grey=1 的笔画芯 → 输出仍是纯磷光前景色,图一点也混不进来
//     ⇒ 无论背景图多亮多花,文字永远是原本那个颜色,不会被"洗掉";
//   · grey=0 的空白格 → 输出即图片本色 ⇒ 图正常显示;
//   · 白热化(applyOverdrive)的驱动量取自 txt_color(内容),图不在其中 ⇒ 图不会被推白
//     —— v1.4.1「白底主题被白热化洗没」那类事故在这里天然不成立;
//   · 辉光/雪花/亮度/闪烁全在这一步之后叠加 ⇒ 文字的光照在图上,物理层序不变。
// 故新增 `convertWithChromaBG`(显式传背景色),老的 `convertWithChroma` 变成
// "背景色 = u.backgroundColor" 的薄壳 —— **没有背景图时两者逐比特相同**。
static inline float3 convertWithChromaBG(float3 inColor, float3 bgColor, constant CRTUniforms &u) {
    float grey = rgb2grey(inColor);
    float denom = max(grey, 0.0001);
    float3 foregroundColor = mix(u.fontColor.rgb, inColor * u.fontColor.rgb / denom, u.chromaColor);
    return mix(bgColor, foregroundColor, grey);
}

static inline float3 convertWithChroma(float3 inColor, constant CRTUniforms &u) {
    return convertWithChromaBG(inColor, u.backgroundColor.rgb, u);
}

// ============================================================================
// 发光模型风格 2「自发光(emissive)」—— v1.4 新增,与 convertWithChroma 并存,主题可选。
//
// 【学】一句话:**"额外加进来的光"该怎么加**。
//   两种模型的染色(内容亮度 → 磷光色)完全一样,分歧只在辉光/噪点这些
//   **叠加在正文之上的光**:
//   · 风格 0(crterm 原版)= 颜料。辉光先被 `clamp(…, 0, 0.5)` 砍平,再逐通道
//     加上去;某个通道满了就单独停在 1 —— 通道比例被改写 = **掉饱和 = 发白**。
//     所以辉光一开大,绿字就往白里走。
//   · 风格 1(本模型)= 光。辉光**不砍**,以软肩(Reinhard)并入光层;整体超过 1 时
//     按**最大分量等比压缩**,通道比例原样保留 —— 亮起来只是更亮,不会褪色。
//
// ⚠️⚠️ 重要更正(2026-07-30,用户提供真 VT220 照片实测后):
//   **别信下面那句"物理依据",也别把风格 1 当成"更正确的那个"。**
//   实测真 CRT 照片的饱和度-亮度曲线是**倒 U**:亮度 80~120 时饱和度 0.64 达峰,
//   往上一路掉到 240+ 时只剩 **0.11** —— 最亮的像素 RGB ≈ (227,255,255),基本是白的。
//   而风格 1 按设计保色相,饱和度在高亮端仍是 0.706;风格 0 是 0.687。
//   **也就是说:真 CRT 的亮处确实褪色发白,风格 0(颜料)方向才对。**
//   原因三条,都是真的:①磷光体不是单色的(P31/P22 绿的发射谱有宽度,高束流下展宽 +
//   面板玻璃荧光);②束打得越猛光斑越大、磷光体饱和,芯部上不去而周围溢出;
//   ③**最主要**:相机与人眼在高亮端本身就掉饱和(相机过曝时电荷在感光点间溢出、
//   去马赛克把三通道一起推高;人眼有 veiling glare,高亮度下饱和辨别力塌缩)。
//   结论:**缺省保持风格 0**,风格 1 留作可选(某些场景用户可能就喜欢那个纯色感)。
//   真正缺的是"过曝发白"这条独立能力 —— 两种模型都还不具备(见分析文档)。
//
// 下面这段是当初的设计动机,保留以说明风格 1 在做什么,但它**不是**"更像真 CRT"的论据:
// 物理依据:显像管的磷光体发射谱固定,电子束电流只决定强度 —— 亮的绿字和暗的
//   绿字是同一个绿,不是"掺了白的绿"。(⚠️ 这条只对"磷光体本身的发射"成立,
//   不对"你看到/拍到的画面"成立 —— 见上面的更正。)
//
// ⚠️ 设计上刻意的两条保守选择(2026-07-30 实测教训,别"顺手优化"回去):
//   ① **染色沿用与风格 0 数学等价的公式**,不另搞一套。曾试过"背景色当基底 +
//      磷光层加法",两个坑:(a) 重复计数 —— 内容纹理里已经画了每格背景色;
//      (b) 亮背景(如 #11009c 蓝底,B 分量 0.63)+ 光层必然超 1,末尾等比压缩把
//      R/G 一起除下去,实测最大亮度 215→145、P99 160→98,文字糊进背景。
//   ② `backgroundColor` uniform **不是黑色**,是 contrast/saturation 预混出的
//      「静息辉光」(黑底绿字时约 (0.017,0.06,0.028) 暗绿)。把它当 0 去掉,画面
//      会丢掉底噪 —— 实测中位亮度 18.7→7.1,整幅发死。
//   结论:辉光关闭时两种风格**输出相同**,这是正确的 —— 差异本就只存在于叠加的光。
// ============================================================================

/// 色相保持的高光压缩:最大分量 ≤1 时**恒等**,>1 时整体等比压回 1。
/// 逐通道 clamp 会改变通道比例(如 (1.5,0.3,0.3)→(1.0,0.3,0.3),红绿比 5:1 掉到
/// 3.3:1 = 掉饱和 = 发白);等比压缩保持 5:1,只是不再更亮。
static inline float3 tonemapPreservingHue(float3 c) {
    float m = max(c.r, max(c.g, c.b));
    return (m > 1.0) ? (c / m) : c;
}

/// 把颜色拆成「强度」与「归一化色度」,再乘磷光色 → 该层的发光贡献。
/// 色度公式与 convertWithChroma 的前景项数学等价:
///   fontColor × mix(1, in/lum, chroma) × lum  ==  mix(fontColor, in×fontColor/lum, chroma) × lum
static inline float3 emissiveLight(float3 inColor, constant CRTUniforms &u) {
    float lum = rgb2grey(inColor);
    if (lum <= 0.0001) {
        return float3(0.0);
    }
    float3 chroma = inColor / lum;
    return u.fontColor.rgb * mix(float3(1.0), chroma, u.chromaColor) * lum;
}

// ============================================================================
// 白热化(overdrive)—— v1.4 第三项,「文字发光」的**自身**那一半。
//
// 【学】把「文字发光」拆成两件互不相干的事(用户 2026-07-30 提的架构,拆得对):
//   ① **文字自身发光** = 笔画芯部被电子束打得过狠 → 磷光体饱和 + 玻璃散射 + 相机/
//      人眼在高亮端掉饱和 ⇒ 看起来**发白**。空间尺度 = **零**(就地,不涉及邻居)。
//   ② **把周围照亮** = 光在面板玻璃里散射出去 ⇒ 笔画外面一圈**磷光色**的光晕。
//      空间尺度 = 比笔画大得多(实测 0.6~1.7 倍墨迹高)。
//   —— 这就是 bloom 这一个旋钮以前干两份活的问题所在:想要①就必须把②开到最大。
//
// 为什么必须是「逐像素、零半径」(实测诊断,2026-07-30):
//   老做法里"发白"是辉光的副产品 —— 辉光纹理是 **1/4 分辨率的邻域模糊**,
//   所以发白程度取决于**周围字有多密**而不是这个像素自己有多亮。实测:
//   我们的饱和度在亮度 150~200 区间是**平的**(0.696/0.700),只在最顶端突然掉到
//   0.618 且带内离散度翻倍(4.3%→10.6%);而真 CRT 照片是从中等亮度就平滑单调下行
//   (0.418→0.327→0.261→0.190)。平坦 + 顶端突变 = 用户看到的「发白发得不均匀」。
//   改成逐像素传递函数后:每根笔画芯部一样白、孤立字符与密排字符表现一致,
//   而且抗锯齿笔画的强度本来就从芯到边递减 ⇒ **自动**得到「中心高亮发白、边缘渐变绿」。
//
// 驱动量取 `max3(texel)` = 「最亮那支枪的束流」(内容纹理),不用亮度:
//   蓝字的 luma 权重只有 0.04,用亮度算的话满驱动的蓝字永远不会过曝 —— 不对。
//
// ⚠️ **别改成「按染色后的输出亮度取驱动量」**(2026-07-31 试过,当场回退):
//   动机是修「Macintosh 128K 文字看不清」—— 白底黑字主题上内容的**亮**像素
//   映射成**深色文字**,按内容亮度取驱动量会专挑文字往白里推,把字洗没。
//   但改用输出亮度会引入更大的回归:`convertWithChroma` 是
//   `mix(背景色, 前景色, 内容亮度)`,背景像素的输出亮度**不是 0**
//   (那是 contrast 预混出的「静息辉光」),于是**整片背景被白热化提亮** ——
//   实测 Commodore 64(深蓝底)83% 像素变化、VT220/5151/Monochrome Green 各 4~6%。
//   正解是**在 CPU 侧按前景/背景亮度关系直接把白底主题的 overdrive 归零**
//   (见 CRTConfig.apply),驱动量这里维持内容纹理不动 —— 暗底主题逐像素不变。
//
// 数值验证:磷光绿染色后笔画芯 ≈ (0.28,1.00,0.46),取 w=0.7 推向白得
//   (0.784,1.00,0.838) = 8bit (200,255,214),饱和度 0.216;
//   真 CRT 照片 220-240 亮度桶实测 (202,253,246)、饱和度 0.202 —— 基本重合。
//
// ⚠️ 只作用在**笔画自身**,不作用在辉光上(故调用点在 bloom 相加之**前**)。
//   照片里也正是这样:芯白、外圈光晕仍是绿的。
// ============================================================================
static inline float3 applyOverdrive(float3 color, float3 texel,
                                    float amount, float knee) {
    if (amount <= 0.0) {
        return color;                       // 缺省 0:逐位等同于没有这段
    }
    float drive = max(texel.r, max(texel.g, texel.b));
    float w = smoothstep(knee, 1.0, drive) * amount;
    return mix(color, float3(1.0), w);
}

/// 软肩(Reinhard):小值几乎不变、大值渐近 1,**标量除法故色相保持**。
/// 取代风格 0 的 `clamp(…, 0, 0.5)` —— 那个硬砍是逐通道的,会改写通道比例。
static inline float3 softShoulder(float3 c) {
    float m = max(c.r, max(c.g, c.b));
    return c / (1.0 + m);
}

fragment float4 crt_fragment(FSQuadOut in [[stage_in]],
                             texture2d<float> source [[texture(0)]],
                             texture2d<float> noiseTex [[texture(1)]],
                             texture2d<float> bloomTex [[texture(2)]],
                             texture2d<float> burnInTex [[texture(3)]],
                             texture2d<float> bgImageTex [[texture(4)]],
                             constant CRTUniforms &u [[buffer(0)]]) {
    constexpr sampler texSampler(address::clamp_to_edge, filter::linear);
    constexpr sampler noiseSampler(address::repeat, filter::linear);   // 噪点纹理 wrap=repeat(原版同)

    float2 uv = in.uv;
    float2 cc = float2(0.5) - uv;
    float dist = length(cc);                            // dynamic.frag:136(噪点中心加权用)

    // 闪烁 + 水平同步抖动:原版在 terminal_dynamic.vert:39-51 算(varying 传下),
    // 此处按 1.1.1 的 fragment fallback 等价实现(全屏 uniform 值,每像素重算成本可忽略)
    float vBrightness = 1.0;
    float vDistortionScale = 0.0;
    float vDistortionFreq = 0.0;
    if (u.flickering > 0.0 || u.horizontalSyncStrength > 0.0) {
        float2 fCoords = float2(fract(u.time / 2.048), fract(u.time / 1048.576));
        float4 fNoise = noiseTex.sample(noiseSampler, fCoords);
        vBrightness = 1.0 + (fNoise.g - 0.5) * u.flickering;
        float randval = u.horizontalSyncStrength - fNoise.r;
        vDistortionScale = step(0.0, randval) * randval * u.horizontalSyncStrength;
        vDistortionFreq = mix(4.0, 40.0, fNoise.g) * step(0.0001, u.horizontalSyncStrength);
    }

    // 屏幕弧度(1.2 语义:屏幕充满窗口,无 frameSize 内缩;机壳以暗角/阴影叠画在边缘)
    float2 curved = distortCoordinates(uv, u.screenCurvature, 0.0);
    float isScreen = min2(step(float2(0.0), curved) - step(float2(1.0), curved));

    // ── 开机动画(v1.1,YeTerm 原创,crterm 无此特效)──────────────────────
    // 物理模型:显像管通电,偏转线圈磁场逐渐建立 —— 电子束先聚成中心亮点,
    // 水平偏转先起(点拉成横亮线),垂直偏转跟上(亮线展开成整幅画面),
    // 束能量从集中到摊开 → 画面短暂过亮再回落稳定。
    // 实现:把"光束画面"在弧度后的屏幕坐标系里做反向缩放(beamCurved),
    // 机壳/玻璃(curved/isScreen)不动 —— 塌缩发生在玻璃后面,和真显像管一致。
    // 【学】三段进度用 smoothstep(a,b,p) 切分:p 走到 a~b 区间时输出平滑的 0→1,
    //      区间外恒 0 或恒 1 —— 相当于给动画分"关键帧"再自动补间(类比 CSS
    //      animation 的 keyframes + ease)。稳定态(progress≥1)所有系数为
    //      恒等值(乘 1/加 0),逐像素输出与没有此特效时完全一致。
    float pwr = clamp(u.powerOnProgress, 0.0, 1.0);
    float beamMask = 1.0;       // 玻璃内、光束外的"死黑"区(束没扫到 = 无光)
    float beamGain = 1.0;       // 束能集中的过亮增益
    float beamHot = 0.0;        // 塌缩亮线的白热化程度
    float pwrAmbient = 1.0;     // 环境光中心辉映随屏幕点亮渐入
    float pwrReflect = 1.0;     // 机壳反射带随屏幕点亮渐入
    float2 beamCurved = curved;
    if (u.powerOnProgress < 1.0) {
        float px = smoothstep(0.0, 0.25, pwr);      // 0~0.25:亮点 → 水平亮线
        float py = smoothstep(0.25, 0.85, pwr);     // 0.25~0.85:垂直展开成画面
        float sx = mix(0.006, 1.0, px * px);        // 水平束宽(0.6% → 全宽)
        float sy = mix(0.0035, 1.0, py * py);       // 垂直束高(一条线 → 全高)
        beamCurved = (curved - float2(0.5)) / float2(sx, sy) + float2(0.5);
        beamMask = min2(step(float2(0.0), beamCurved) - step(float2(1.0), beamCurved));
        beamHot = 0.8 * (1.0 - py) * (1.0 - py);   // 平方衰减:展开一开始就快速让位给内容
        // 0.85~1.0:过亮回落(能量摊开后趋于额定亮度)
        beamGain = 1.0 + 1.4 * (1.0 - py) + 0.35 * (1.0 - smoothstep(0.7, 1.0, pwr));
        pwrAmbient = pwr * pwr;
        pwrReflect = mix(0.1, 1.0, py);
        // 偏转未稳时的水平同步失稳:轻微摆动,随进度平方衰减
        vDistortionScale += 0.10 * (1.0 - pwr) * (1.0 - pwr);
        vDistortionFreq = max(vDistortionFreq, 12.0);
    }

    // ── 消磁(v1.2 #13,YeTerm 原创彩蛋)──────────────────────────────────
    // 物理:按下 degauss,消磁线圈的交变磁场扰乱电子束偏转 —— 画面从中心
    // 荡开一圈圈波纹并快速平复。波纹作用在 beamCurved(束坐标):玻璃/机壳
    // 纹丝不动,扭的是玻璃后面的画面,与真 CRT 一致。包络由 CPU 侧衰减。
    if (u.degauss > 0.001) {
        float2 dcc = beamCurved - float2(0.5);
        float dd = length(dcc);
        float wave = sin(dd * 36.0 - u.time * 42.0) * 0.013 * u.degauss;
        beamCurved += (dcc / max(dd, 1e-4)) * wave;
    }
    float2 screenCoords = clamp(beamCurved, 0.0, 1.0);

    // 机壳层(dynamic.frag:152-155 + 175-177 的合成语义)
    float4 frameCol = float4(0.0);
    if (u.frameOn > 0.5) {
        frameCol = computeFrame(uv, curved, u);
    }

    // 水平同步:coords.x 加时变正弦位移(dynamic.frag:141-142)
    float dst = sin((screenCoords.y + u.time) * vDistortionFreq);
    screenCoords.x += dst * vDistortionScale;

    // 雪花噪点(dynamic.frag:144-149;time 固定则输出确定)。
    // 性能短路(数学等价):噪点与抖动全关时 noiseTexel 的贡献恒为 0
    // (.a×0 与 (ba-0.5)×j²|j=0),中性值 0.5 代入结果逐位相同,免一次纹理采样。
    float4 noiseTexel = float4(0.5);
    if (u.staticNoise > 0.0 || u.jitter > 0.0) {
        noiseTexel = noiseTex.sample(noiseSampler,
            u.scaleNoiseSize * uv + float2(fract(u.time / 0.051), fract(u.time / 0.237)));
    }
    float extra = 0.0001;
    // 1.2 语义(v1.1 #6 勘差):水平同步失步的瞬间雪花噪点暴增(noise += scale×7)
    // —— "坏电视"失步时画面炸雪花的戏剧效果,master 已删,用户在用的 1.2 有
    if (u.staticNoise > 0.0) {
        extra += noiseTexel.a * (u.staticNoise + vDistortionScale * 7.0) * (1.0 - dist * 1.3);
    }

    // 移动亮线(dynamic.frag:119-121,150;glowingLine 已在 CPU 侧 ×0.2)
    if (u.glowingLine > 0.0) {
        extra += fract(smoothstep(-120.0, 0.0,
            screenCoords.y * u.virtualResolution.y
            - (u.virtualResolution.y + 120.0) * fract(u.time * 0.15))) * u.glowingLine;
    }
    // 机壳遮罩噪点/亮线(dynamic.frag:152-155)
    extra *= (1.0 - frameCol.a);

    // letterbox 映射:内容纹理 1:1 像素呈现(含 margin 留白偏移),余量为背景色 ——
    // 消除「非整数拉伸 + linear 采样」造成的笔画抽稀(拦腰截断的残余根源)
    float2 c = screenCoords * u.contentScale - u.contentOffset;
    float inContent = (c.x >= 0.0 && c.y >= 0.0 && c.x <= 1.0 && c.y <= 1.0) ? 1.0 : 0.0;

    // 抖动:采样坐标微偏移。1.2 语义 = **线性**(0.007×j,ShaderTerminal_1.1.1:283-284);
    // master 改成平方效应(再乘一次 j)—— 默认 j=0.1 时两者差 10 倍,用户参照物是 1.2(v1.1 #6 勘差)
    float2 jitterOffset = (noiseTexel.ba - float2(0.5)) * float2(0.007, 0.002) * u.jitter;
    float2 sampleCoords = clamp(c + jitterOffset * u.contentScale, 0.0, 1.0);

    float3 txt_color = source.sample(texSampler, sampleCoords).rgb * inContent;

    // RGB 色差(static.frag:61-68,权重照抄;位移已换算为内容 UV)
    if (u.rgbShift > 0.0) {
        float2 disp = float2(u.rgbShift, 0.0);
        float3 rightColor = source.sample(texSampler, clamp(sampleCoords + disp, 0.0, 1.0)).rgb;
        float3 leftColor  = source.sample(texSampler, clamp(sampleCoords - disp, 0.0, 1.0)).rgb;
        txt_color.r = leftColor.r * 0.10 + rightColor.r * 0.30 + txt_color.r * 0.60;
        txt_color.g = leftColor.g * 0.20 + rightColor.g * 0.20 + txt_color.g * 0.60;
        txt_color.b = leftColor.b * 0.30 + rightColor.b * 0.10 + txt_color.b * 0.60;
        txt_color *= inContent;
    }

    // 余辉合成(dynamic.frag:161-166;采样弧度后内容坐标,与原版 staticCoords 语义一致)
    if (u.burnIn > 0.0) {
        float4 txt_blur = burnInTex.sample(texSampler, clamp(c, 0.0, 1.0));
        float blurDecay = clamp((u.time - u.burnInLastUpdate) * u.burnInTime, 0.0, 1.0);
        float3 burnInColor = 0.65 * (txt_blur.rgb - float3(blurDecay)) * (1.0 - txt_blur.a);
        txt_color = max(txt_color, burnInColor * inContent);
    }

    // GPU 光标(内容空间坐标 → 随弧度弯曲;在光栅化/chroma 之前 → 扫描线与染色一并作用)
    // 反色呈现:字符从光标下透出(用户需求);三种形状:块/下划线/竖线
    if (u.cursorOn > 0.5) {
        float2 rel = (c - u.cursorRectUV.xy) / u.cursorRectUV.zw;   // 光标格内局部坐标
        bool inRect = rel.x >= 0.0 && rel.x < 1.0 && rel.y >= 0.0 && rel.y < 1.0;
        bool shape = inRect && (u.cursorStyle < 0.5 ? true :          // 0 块
                                u.cursorStyle < 1.5 ? rel.y > 0.85 :  // 1 下划线
                                                      rel.x < 0.12);  // 2 竖线
        if (shape) {
            txt_color = float3(1.0) - txt_color;
        }
    }

    // 光栅化作用在内容坐标上(与文本行严格对齐;弧度时随 staticCoords 弯曲,与原版一致)
    txt_color = applyRasterization(c, txt_color, u.virtualResolution, u.rasterizationIntensity, u.rasterMode);

    // ── 背景图片(v1.5.1):CRT 模式的「屏幕底图」──────────────────────────
    // 拿它替换染色公式里的背景色项(理由见 convertWithChromaBG 上方长注释)。
    // 采样坐标用 screenCoords 而非 uv —— 那是**弧度扭曲 + 水平失步之后**的屏幕
    // 坐标,于是图跟着显像管一起鼓、一起失步抖,像是真的显示在这块玻璃后面,
    // 而不是贴在玻璃外面的一张纸。后面 isScreen/机壳/开机塌缩也照旧作用于它。
    float3 screenBg = u.backgroundColor.rgb;
    if (u.bgImageOn > 0.5) {
        float2 bguv = (screenCoords - float2(0.5)) * u.bgImageUVScale + float2(0.5);
        float3 img = bgImageTex.sample(texSampler, clamp(bguv, 0.0, 1.0)).rgb;
        // 荧光染色档(用户可选):整张图按磷光色重染 = "真 CRT 正在显示这张图"。
        // 关 = 保留原色,图只是屏幕底色,磷光文字发光浮在它上面。
        if (u.bgImageChroma > 0.0) {
            img = mix(img, convertWithChroma(img, u), u.bgImageChroma);
        }
        // 图也吃扫描线/像素栅格:它是"显示出来的东西",不是贴在管子外面的纸。
        // 用内容坐标 c(与文字同一套栅格)——暗带落在同样的位置,不会与文字打架。
        img = applyRasterization(c, img, u.virtualResolution, u.rasterizationIntensity, u.rasterMode);
        screenBg = img;
    }

    // 普通终端模式(v1.2 用户实测勘差):convertWithChroma 即使 chroma=1 也会把
    // fontColor 乘进所有颜色、backgroundColor 混进暗部(p10k 彩色块被文字颜色
    // 串染)—— 直通模式内容原色直出;余量/留白区填 backgroundColor(与主体同源
    // 同值,消异色边框)
    float3 finalColor;

    // ── 发光模型风格 2(v1.4,主题可选;emissiveModel=0 时下面 else 分支与
    //    改动前逐字节相同)。层序严格照抄风格 0 的 1.2 勘差结论:
    //    辉光吃亮度、雪花噪点不吃亮度但吃闪烁 —— 这条是 v1.1 #6 的血泪教训,
    //    换发光模型不是换层序,别在这里"顺手改进"。
    if (u.emissiveModel > 0.5 && u.colorPassthrough <= 0.5) {
        // ① 染色:直接复用 convertWithChroma —— 与风格 0 **逐比特相同**。
        //    (刻意如此,理由见上方长注释的"两条保守选择")
        //    v1.5.1:背景色项换成 screenBg(无背景图时 = u.backgroundColor,逐比特不变)
        float3 light = convertWithChromaBG(txt_color, screenBg, u);
        light = applyOverdrive(light, txt_color, u.overdrive, u.overdriveKnee);  // 白热化(仅笔画自身)
        // ② 辉光:软肩并入,不做 clamp(0,0.5) 硬砍 —— 这是与风格 0 的真正分歧点
        if (u.bloomAmount > 0.0) {
            float2 buv = u.bloomPad + c * (float2(1.0) - 2.0 * u.bloomPad);
            float3 bl = bloomTex.sample(texSampler, clamp(buv, 0.0, 1.0)).rgb;
            light += softShoulder(emissiveLight(bl, u) * u.bloomAmount);
        }
        light *= (u.brightness > 0.0 ? u.brightness : 1.0);      // ③ 亮度(层序同风格 0:不作用于噪点)
        light += u.fontColor.rgb * extra;                        // ④ 雪花/亮线也是光
        light *= vBrightness;                                    // ⑤ 闪烁(作用于整体)
        // ⑥ 溢出做色相保持的等比压缩(风格 0 此处是隐式逐通道 clamp,亮处掉饱和)
        finalColor = tonemapPreservingHue(light);
    } else {
    finalColor = (u.colorPassthrough > 0.5)
        ? mix(u.backgroundColor.rgb, txt_color, inContent)
        : convertWithChromaBG(txt_color, screenBg, u);   // v1.5.1:背景色项 → 屏幕底图

    // 白热化(v1.4):笔画自身过曝发白。直通模式不参与(那是普通终端,无 CRT 物理)。
    // 位置在辉光相加**之前** —— 只白笔画芯,不白外圈光晕(照片里光晕仍是绿的)
    if (u.colorPassthrough <= 0.5) {
        finalColor = applyOverdrive(finalColor, txt_color, u.overdrive, u.overdriveKnee);
    }

    // 辉光合成:对齐用户在用的 1.2 世代语义(ShaderTerminal_1.1.1 static 段)——
    // ① 在光栅化/染色**之后**叠加:光晕永远平滑,不被扫描线/像素栅格调制;
    // ② 染色用老版乘法公式 fontColor × mix(grey, in, chroma)(非 master 的 /grey 版);
    // ③ 模糊纹理带出血边距(bloomPad):留白区仍能采到自然衰减的光晕,无锐切。
    if (u.bloomAmount > 0.0) {
        float2 buv = u.bloomPad + c * (float2(1.0) - 2.0 * u.bloomPad);
        float3 bl = bloomTex.sample(texSampler, clamp(buv, 0.0, 1.0)).rgb;
        float3 tinted = u.fontColor.rgb * mix(float3(rgb2grey(bl)), bl, u.chromaColor);
        finalColor += clamp(tinted * u.bloomAmount, 0.0, 0.5);
    }

    finalColor *= (u.brightness > 0.0 ? u.brightness : 1.0);   // 亮度(1.2 static 层:不作用于噪点)

    // 1.2 层序勘差(v1.1 #6):雪花噪点/移动亮线属 dynamic 层,叠加在光栅化与
    // 染色**之后**、以磷光色直加 —— crterm 的雪花是浮在屏幕上的"信号噪声",
    // 不嵌进扫描线暗带、不吃 brightness(但吃 flicker,层序照抄 1.1.1)。
    // 此前加在光栅化之前 = master 也没有的私生语义,雪花被压进像素栅格。
    finalColor += u.fontColor.rgb * extra;

    finalColor *= vBrightness;      // 闪烁(dynamic 层:作用于含噪点的整体画面)
    }   // ── 发光模型分支结束(风格 0 = 上面这段,与 v1.3 逐字节一致)

    // 开机动画收束:亮线白热化(加法过曝 —— 保留内容对比,像真过曝而非蒙白纱)
    // + 束能过亮 + 束外死黑
    if (u.powerOnProgress < 1.0) {
        float3 hot = mix(u.fontColor.rgb, float3(1.0), 0.55) * 1.5;
        finalColor = (finalColor * beamGain + hot * beamHot) * beamMask;
    }

    // 环境光中心辉映(1.2 dynamic:ambientLight×0.2 × (1−dist)²,叠在机壳之前)
    finalColor += float3(u.ambientLight * 0.2) * (1.0 - dist) * (1.0 - dist) * pwrAmbient;

    if (u.frameOn > 0.5) {
        // 反射带(屏幕外,1.2 static 的 reflectionMask 语义):**镜像坐标**采完整
        // 内容+辉光 —— 屏幕光映照机壳;机壳以 ~0.9-1.0 不透明度叠其上,
        // 透出的份额即「屏幕颜色映在边框上」的活效果;死黑边带退役
        if (isScreen < 0.5) {
            float2 mCurved = float2(
                curved.x < 0.0 ? -curved.x : (curved.x > 1.0 ? 2.0 - curved.x : curved.x),
                curved.y < 0.0 ? -curved.y : (curved.y > 1.0 ? 2.0 - curved.y : curved.y));
            float2 mc = clamp(mCurved, 0.0, 1.0) * u.contentScale - u.contentOffset;
            float inMC = (mc.x >= 0.0 && mc.y >= 0.0 && mc.x <= 1.0 && mc.y <= 1.0) ? 1.0 : 0.0;
            float3 mtxt = source.sample(texSampler, clamp(mc, 0.0, 1.0)).rgb * inMC;
            float3 mcol = convertWithChroma(mtxt, u);
            float2 mbuv = u.bloomPad + mc * (float2(1.0) - 2.0 * u.bloomPad);
            float3 mbl = bloomTex.sample(texSampler, clamp(mbuv, 0.0, 1.0)).rgb;
            float3 mblTint = u.fontColor.rgb * mix(float3(rgb2grey(mbl)), mbl, u.chromaColor);
            float3 reflection = mcol + clamp(mblTint * u.bloomAmount, 0.0, 0.5);
            // 开机时反射带随屏幕点亮渐入(屏幕暗 → 机壳无光可反)
            finalColor = reflection * (u.brightness > 0.0 ? u.brightness : 1.0) * pwrReflect;
        }
        finalColor = mix(finalColor, frameCol.rgb, frameCol.a);
    } else {
        finalColor *= isScreen;
    }

    return float4(finalColor, 1.0);
}
