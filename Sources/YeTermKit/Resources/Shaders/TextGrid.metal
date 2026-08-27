// ─────────────────────────────────────────────────────────────────────────────
// YeTerm —— 复古 CRT 终端 (macOS)
// Copyright (C) 2026 qiuye97
//
// 本文件为 YeTerm 原创(非移植)。随项目以 GPL-3.0-or-later 分发,详见仓库根
// 目录的 LICENSE。
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 文字网格着色器:把几千个格子一口气画上屏
//
// 配合 ContentRenderer.swift 阅读。这里是"实例化绘制"的 GPU 侧:
//   CPU 发来一张实例表(每格的位置/贴纸坐标/颜色),grid_vertex 按
//   instance_id 查表算出四边形顶点;片元着色器两种:背景块直接涂色、
//   字形块从图集采样 alpha 当"漏字板"乘前景色。
// 概念:NDC(归一化设备坐标)—— GPU 的屏幕坐标系是 [-1,1],
//   顶点函数的职责就是把像素坐标换算过去(注意 y 轴翻转)。
// ─────────────────────────────────────────────────────────────────────────────
#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 文本网格渲染(M1a-2):字符网格 → 内容纹理。
// 实例化 quad:背景块(纯色)与字形块(atlas mask × 前景色)两条管线。
// 坐标:实例 rect 为内容纹理像素坐标,原点左上。
// ============================================================================

struct GridUniforms {
    float2 viewportPx;    // 内容纹理像素尺寸
};

struct QuadInstance {
    float4 rectPx;        // x,y,w,h(像素,原点左上)
    float4 uvRect;        // atlas uv x,y,w,h(背景块忽略)
    float4 color;         // 背景块=底色;字形块=前景色
};

struct GridVSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// 6 顶点两三角;vid ∈ 0..5
vertex GridVSOut grid_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant QuadInstance *instances [[buffer(0)]],
                             constant GridUniforms &u [[buffer(1)]]) {
    constexpr float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    QuadInstance inst = instances[iid];
    float2 c = corners[vid];
    float2 px = inst.rectPx.xy + c * inst.rectPx.zw;
    // 像素(左上原点)→ NDC
    float2 ndc = float2(px.x / u.viewportPx.x * 2.0 - 1.0,
                        1.0 - px.y / u.viewportPx.y * 2.0);
    GridVSOut o;
    o.position = float4(ndc, 0, 1);
    o.uv = inst.uvRect.xy + c * inst.uvRect.zw;
    o.color = inst.color;
    return o;
}

// 背景/装饰线:纯色
fragment float4 grid_bg_fragment(GridVSOut in [[stage_in]]) {
    return in.color;
}

// 字形:atlas 里是「白字形+alpha」,取 alpha 作 mask 乘前景色(启用 alpha 混合)。
// 彩色字形(emoji,issue #1):CPU 侧用 alpha=2 哨兵标记 —— 图集里存的是
// **预乘 alpha 的彩色位图**,直接原色输出(除回 alpha 还原成直通色,因为本管线
// 的混合因子按直通 alpha 配:srcRGB×srcAlpha + dst×(1-srcAlpha))。
// 拿它乘前景色只会剩下单色剪影,正是 issue 截图「emoji 只有轮廓」的根因
fragment float4 grid_glyph_fragment(GridVSOut in [[stage_in]],
                                    texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float4 c = atlas.sample(s, in.uv);
    if (in.color.a > 1.5) {
        return float4(c.rgb / max(c.a, 0.0001), c.a);
    }
    return float4(in.color.rgb, in.color.a * c.a);
}

// 终端图片条带(v1.2 #4):RGBA 直贴(uv 全幅 0..1 采样整条带纹理;
// linear 采样 = 图片缩放显示时平滑;预乘 alpha 由管线混合因子处理)
fragment float4 grid_image_fragment(GridVSOut in [[stage_in]],
                                    texture2d<float> img [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return img.sample(s, in.uv);
}
