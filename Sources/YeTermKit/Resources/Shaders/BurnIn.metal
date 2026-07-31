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
// 📖 初学者导读 —— 余辉累积:CRT 的"残影记忆"
//
// 老显像管的磷粉被点亮后会缓慢变暗,画面滚动就留下"余辉拖尾"。
// 实现:一张"累积纹理"记着历史亮度,每次内容更新时 —— 旧累积按时间
//   衰减一点、再与新内容取较大值(max)。配合 EffectChain 的乒乓双缓冲
//   (读旧写新,两张轮换)。这是 GPU 上做"有状态动画"的标准套路。
// ─────────────────────────────────────────────────────────────────────────────
#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 余辉累积(M1b):逐行移植自 cool-retro-term 的 shaders/burn_in.frag。
// 乒乓双缓冲:读上一帧累积(burnInSource)+ 当前内容(txt_source)→ 写新累积。
// alpha 通道 =「刚点亮的像素」掩码(阻止刚写的字立即参与衰减/拖影)。
// ============================================================================

struct FSQuadOut {
    float4 position [[position]];
    float2 uv;
};

struct BurnInUniforms {
    float burnInLastUpdate;   // 本次更新时刻(秒)
    float prevLastUpdate;     // 上次更新时刻(秒)
    float burnInTime;         // 衰减速率 = 1 / lint(0.16, 1.6, burnIn)
    float _pad;
    float4 cursorRect;        // 16 光标块(合成 UV x,y,w,h;w=0 无光标)
    float cursorStyle;        // 32 0 块 / 1 下划线 / 2 竖线(拖影按实际形状)
    float _pad2;
    float _pad3;
    float _pad4;              // → 48B(与 EffectChain.swift 逐字节一致)
};

static inline float rgb2grey(float3 v) { return dot(v, float3(0.21, 0.72, 0.04)); }

fragment float4 burnin_accumulate_fragment(FSQuadOut in [[stage_in]],
                                           texture2d<float> txtSource [[texture(0)]],
                                           texture2d<float> prevAcc [[texture(1)]],
                                           constant BurnInUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float4 accColor = prevAcc.sample(s, in.uv);
    float3 txtColor = txtSource.sample(s, in.uv).rgb;

    // 光标拖尾(v1.1 #6 三轮,用户实测勘差):我们的光标是 GPU 参数光标、
    // 不在内容纹理里 —— crterm 的光标画在内容层所以天然有余辉拖尾。
    // 补法:累积时把光标块当亮块叠进来,拖影与 crterm 一致;实时光标仍走
    // uniform(锐利、闪烁/平滑滑移不受影响)。
    if (u.cursorRect.z > 0.0) {
        float2 rel = (in.uv - u.cursorRect.xy) / u.cursorRect.zw;
        if (rel.x >= 0.0 && rel.x < 1.0 && rel.y >= 0.0 && rel.y < 1.0) {
            bool shape = u.cursorStyle < 0.5 ? true :          // 块
                         u.cursorStyle < 1.5 ? rel.y > 0.85 :  // 下划线
                                               rel.x < 0.12;   // 竖线
            if (shape) {
                txtColor = float3(1.0);
            }
        }
    }

    // burn_in.frag:24-31
    float blurDecay = clamp((u.burnInLastUpdate - u.prevLastUpdate) * u.burnInTime, 0.0, 1.0);
    blurDecay = max(0.0, blurDecay - accColor.a);
    float3 color = max(accColor.rgb - float3(blurDecay), txtColor);
    float currMask = step(rgb2grey(color), rgb2grey(txtColor));

    return float4(color, currMask);
}
