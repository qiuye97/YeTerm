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
// 📖 初学者导读 —— 高斯模糊:辉光的数学
//
// 辉光 = 把画面模糊后叠回原图。模糊 = 每个像素取周围像素的加权平均,
//   权重按高斯(正态分布)曲线 —— 离得越远影响越小。
// 两个必学优化:①"可分离":二维模糊拆成横一趟+竖一趟,N² 次采样变 2N;
//   ②先降采样再小核模糊(见 EffectChain 导读)。
// 血泪教训(注释里也写了):模糊核必须逐像素稠密采样,稀疏跳采会把
//   文字复制成一片"马赛克鬼影"——用户抓到过的真实 bug。
// ─────────────────────────────────────────────────────────────────────────────
#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 辉光模糊(M1b):cool-retro-term 的 bloom 模糊调用 Qt 内置 FastBlur,无源码可抄
// (它直接调 Qt 内置的 FastBlur)—— 此处自写:降采样(1/4 分辨率)+ **稠密**可分离高斯。
//
// 历史教训(用户实测「马赛克玻璃」):曾用 9-tap、tap 间距 = radius/4 的稀疏核,
// 大半径下等于把文字复制成 9×9 个错位淡影 —— 模糊核必须逐像素稠密采样,
// 大半径靠「先降采样再小核模糊」实现(线性上采样天然平滑,观感 ≈ FastBlur/box-shadow)。
// ============================================================================

struct FSQuadOut {
    float4 position [[position]];
    float2 uv;
};

struct BlurUniforms {
    float2 direction;   // 单位步长:(1/w, 0)=H,(0, 1/h)=V(目标纹理像素)
    float sigmaPx;      // 高斯 σ(目标纹理像素);tap 范围 ±2.5σ,逐像素稠密
};

struct PadUniforms {
    float2 pad;         // 出血边距(目标 UV):内容缩进内嵌区,四周留黑边供光晕扩散
};

// 带出血边距的降采样:目标四周 pad 区映射到源纹理外 → clamp_to_zero 采零(黑),
// 后续模糊让光晕自然溢进 pad 区 —— CRT 主 pass 据此实现「留白不切辉光」
fragment float4 pad_downsample_fragment(FSQuadOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        constant PadUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    float2 uv = (in.uv - u.pad) / (float2(1.0) - 2.0 * u.pad);
    return float4(source.sample(s, uv).rgb, 1.0);
}

fragment float4 blur_fragment(FSQuadOut in [[stage_in]],
                              texture2d<float> source [[texture(0)]],
                              constant BlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float sigma = max(u.sigmaPx, 0.5);
    const int taps = clamp(int(ceil(sigma * 2.5)), 1, 24);
    const float inv2s2 = 1.0 / (2.0 * sigma * sigma);

    float3 acc = source.sample(s, in.uv).rgb;
    float wsum = 1.0;
    for (int i = 1; i <= taps; i++) {
        float w = exp(-float(i * i) * inv2s2);
        float2 off = u.direction * float(i);
        acc += (source.sample(s, in.uv + off).rgb + source.sample(s, in.uv - off).rgb) * w;
        wsum += 2.0 * w;
    }
    return float4(acc / wsum, 1.0);
}

// ============================================================================
// 辉光风格 2「光晕(halation)」—— v1.4 新增,与上面的高斯并存,主题可选。
//
// 【学】同一段模糊逻辑,只把「加权平均」换成「加权 max」,观感天差地别:
//   · 加权平均(上面的高斯)= **能量守恒**。亮核的光被摊到周围,峰值必然下降 ——
//     所以辉光越强画面越像蒙了层雾,而不是像在发光。
//   · 加权 max(本函数)= **形态学膨胀(dilate)**。亮核峰值一点不掉,只向外
//     长出一圈按高斯权重衰减的裙边。
//
// 为什么后者更像真显像管:玻璃面板里的光散射(halation)是**额外**加上去的光子,
//   不是把原来的光摊薄 —— 你把脸贴近老显示器看亮字,字芯还是那么亮,只是周围
//   多了一圈晕。能量守恒的模糊物理上描述的是"透过毛玻璃看",不是"发光体的光晕"。
//
// 实现要点:中心权重 exp(0)=1,所以取完 max 无需再归一化 —— 峰值天然等于源峰值。
// ============================================================================
fragment float4 blur_max_fragment(FSQuadOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  constant BlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float sigma = max(u.sigmaPx, 0.5);
    const int taps = clamp(int(ceil(sigma * 2.5)), 1, 24);
    const float inv2s2 = 1.0 / (2.0 * sigma * sigma);

    float3 acc = source.sample(s, in.uv).rgb;          // 中心权重 = 1
    for (int i = 1; i <= taps; i++) {
        float w = exp(-float(i * i) * inv2s2);
        float2 off = u.direction * float(i);
        acc = max(acc, source.sample(s, in.uv + off).rgb * w);
        acc = max(acc, source.sample(s, in.uv - off).rgb * w);
    }
    return float4(acc, 1.0);
}

// ============================================================================
// 光晕形状 2「紧核 + 长尾」—— v1.4 第五项,与上面的单层光晕并存,主题可选。
//
// 【学】为什么单个高斯不够:实测真 CRT 照片的光晕衰减**比指数快、比高斯慢**,
//   远端近似 1/x —— 这是玻璃里多次散射 + 眼内杂散光(veiling glare)的典型形状,
//   叫「紧核 + 长尾」。单个高斯要么核太胖、要么尾巴太短,拟不出来。
//   两个不同宽度的高斯加权和能在有限范围内很好地逼近它。
//
// ⚠️ **为什么不在单趟里同时算两个高斯**(这是个坑,别去踩):
//   可分离模糊是「横一趟 × 竖一趟」。若在每趟里都输出 a·g_t + b·g_w,
//   两趟相乘展开会得到 a²G_t + ab·g_t(x)g_w(y) + ab·g_w(x)g_t(y) + b²G_w ——
//   中间那两个**交叉项**是「横向窄×纵向宽」和「横向宽×纵向窄」,叠起来就是
//   一个**十字形**的伪影。所以必须真正做两遍完整的可分离模糊再合成。
//
// 本实现的省法:高斯的卷积半群性质 —— G_σ1 ∗ G_σ2 = G_√(σ1²+σ2²)。
//   所以先做一遍紧模糊得到 T,再在 T 上做一遍 σ2 = √(σ宽² − σ紧²) 的模糊,
//   得到的正好是 σ宽 的宽模糊 W。省掉一整套"从头再模糊一次"的采样。
//   末趟(竖向)顺便把 T 也采进来合成,故只多一张纹理、不多一趟。
//
// ⚠️ 与白热化的分工别搞混:白热化管**笔画自身**发白(零半径);
//   本项管**光晕的形状**,仍属于「把周围照亮」那一半。
// ============================================================================
struct DualBlurUniforms {
    float2 direction;   // 单位步长
    float sigmaPx;      // 本趟(宽)的 σ
    float wideWeight;   // 宽成分占比:0=纯紧核,1=纯宽(= 退化回单层)
};

/// 末趟:对 source 做宽向模糊,并与 tight(已完成的紧模糊结果)加权合成
fragment float4 blur_combine_fragment(FSQuadOut in [[stage_in]],
                                      texture2d<float> source [[texture(0)]],
                                      texture2d<float> tight [[texture(1)]],
                                      constant DualBlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float sigma = max(u.sigmaPx, 0.5);
    const int taps = clamp(int(ceil(sigma * 2.5)), 1, 24);
    const float inv2s2 = 1.0 / (2.0 * sigma * sigma);

    float3 acc = source.sample(s, in.uv).rgb;
    float wsum = 1.0;
    for (int i = 1; i <= taps; i++) {
        float w = exp(-float(i * i) * inv2s2);
        float2 off = u.direction * float(i);
        acc += (source.sample(s, in.uv + off).rgb + source.sample(s, in.uv - off).rgb) * w;
        wsum += 2.0 * w;
    }
    float3 wide = acc / wsum;
    float3 core = tight.sample(s, in.uv).rgb;
    return float4(mix(core, wide, u.wideWeight), 1.0);
}

/// 同上,但两成分都用加权 max(配合辉光风格「光晕」)
fragment float4 blur_max_combine_fragment(FSQuadOut in [[stage_in]],
                                          texture2d<float> source [[texture(0)]],
                                          texture2d<float> tight [[texture(1)]],
                                          constant DualBlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float sigma = max(u.sigmaPx, 0.5);
    const int taps = clamp(int(ceil(sigma * 2.5)), 1, 24);
    const float inv2s2 = 1.0 / (2.0 * sigma * sigma);

    float3 acc = source.sample(s, in.uv).rgb;
    for (int i = 1; i <= taps; i++) {
        float w = exp(-float(i * i) * inv2s2);
        float2 off = u.direction * float(i);
        acc = max(acc, source.sample(s, in.uv + off).rgb * w);
        acc = max(acc, source.sample(s, in.uv - off).rgb * w);
    }
    float3 core = tight.sample(s, in.uv).rgb;
    // max 语义下"加权和"没有意义 —— 长尾是**额外**的散射光,取 max 才不吞掉紧核峰值
    return float4(max(core, acc * u.wideWeight), 1.0);
}
