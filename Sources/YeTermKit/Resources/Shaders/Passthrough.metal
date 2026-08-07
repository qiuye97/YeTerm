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
// 📖 初学者导读 —— 最简着色器:直通 + 白色(兼"全屏三角形"教学样本)
//
// passthrough_fragment 原样搬运纹理(当年用它逐像素验证整条管线的
//   上传/采样/回读没有偏差);solid_white_fragment 涂纯白(分屏荧光线用)。
// fsq_vertex 是著名的"全屏三角形"技巧:3 个顶点的超大三角形盖满屏幕,
//   位运算 (vid<<1)&2 生成 (0,0)(2,0)(0,2) 三个角 —— 面试可以吹的小魔术。
// ─────────────────────────────────────────────────────────────────────────────
#include <metal_stdlib>
using namespace metal;

// M0-S4 引导用:全屏三角形 + 直采透传。
// 作用:单独验证「上传→采样→回读」链路(BGRA 次序/y 翻转/bytesPerRow 全在此现形)。

struct FSQuadOut {
    float4 position [[position]];
    float2 uv;
};

// 无顶点缓冲的全屏三角形:3 个顶点覆盖整个屏幕
vertex FSQuadOut fsq_vertex(uint vid [[vertex_id]]) {
    FSQuadOut o;
    float2 pos = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(pos.x, 1.0 - pos.y);              // 纹理原点在左上,翻转 y
    return o;
}

fragment float4 passthrough_fragment(FSQuadOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    return source.sample(s, in.uv);
}

// 分屏荧光分割线:纯白实色(内容空间白 = 满亮度荧光,经 CRT 染色成荧光线并吃辉光)
fragment float4 solid_white_fragment(FSQuadOut in [[stage_in]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}

// ============================================================================
// 普通模式背景图片(v1.2 #16):仅 CRT 总开关关闭时生效。
// 分工:铺图 fragment 每帧跑(合成第一笔);特效 fragment 只在**选图时**跑一次,
// 结果缓存成纹理(PlainBackground.swift)—— 每帧零额外特效开销。
// ============================================================================

// aspect-fill 裁剪参数:uv' = (uv-0.5)*uvScale+0.5 —— 图片按比例放大到盖满
// 画面,长出来的边裁掉(照片 App「填充」语义;uvScale 由图片/画面宽高比算出)
struct PlainBGFillUniforms {
    float2 uvScale;
};

// 合成第一笔:把背景图铺满整个画面(pane 内容随后以透明混合叠上来)
fragment float4 plain_bg_fill_fragment(FSQuadOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       constant PlainBGFillUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = (in.uv - 0.5) * u.uvScale + 0.5;
    return float4(source.sample(s, uv).rgb, 1.0);
}

struct PlainBGGradeUniforms {
    float mode;     // 1=暗化(×dim,滑块驱动)2=黑白胶片(灰度×0.55)
    float dim;      // 暗化乘数(CPU 侧 PlainBackground.dimMultiplier 算好;
                    // 滑块 0.5 档 = 0.35 = v1.2 起的固定观感,仅 mode=1 读)
};

// 一次性调色预处理(暗化/黑白胶片)。
// 【学】dot(c, 亮度权重) 是标准灰度公式:人眼对绿最敏感,权重最大
fragment float4 plain_bg_grade_fragment(FSQuadOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        constant PlainBGGradeUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 c = source.sample(s, in.uv).rgb;
    if (u.mode > 1.5) {
        float g = dot(c, float3(0.299, 0.587, 0.114));
        c = float3(g) * 0.55;
    } else {
        c *= u.dim;
    }
    return float4(c, 1.0);
}

struct PlainBGPixelUniforms {
    float4 palette[16];   // 复古调色板(最多 16 色,rgb 有效)
    float4 meta;          // x=调色板色数(0=无调色板,均匀量化) y=抖动幅度 z/w=小图宽高(纹素)
};

// Bayer 4×4 有序抖动矩阵:像素画的经典视觉特征 —— 渐变区域用固定点阵
// 图案交错过渡,替代均匀量化的"烂色带"。数值是标准 Bayer 序(0~15)
constant float kBayer4[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
};

// 一次性像素风转换(v2,借鉴 pixelit 等开源像素画工具的算法):
// 源是已降采样的粗网格小图,nearest 放大出大色块;每块先按 Bayer 阈值
// 抖动偏移,再映射到**精选复古调色板**的最近色(感知加权距离,绿权重最大)
// —— 均匀量化出"脏色",精选调色板才有像素画的和谐复古感。
fragment float4 plain_bg_pixelate_fragment(FSQuadOut in [[stage_in]],
                                           texture2d<float> source [[texture(0)]],
                                           constant PlainBGPixelUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float3 c = source.sample(s, in.uv).rgb;
    // 块坐标(小图纹素)查 Bayer 阈值:同一色块内阈值一致,放大后图案随块走
    int2 cell = int2(floor(in.uv * u.meta.zw));
    float t = kBayer4[(cell.y & 3) * 4 + (cell.x & 3)] / 16.0 - 0.5;
    c = saturate(c + t * u.meta.y);
    int n = int(u.meta.x);
    if (n <= 0) {
        // 原色档:无调色板,均匀量化(抖动仍然生效)
        return float4(floor(c * 6.0 + 0.5) / 6.0, 1.0);
    }
    float best = 1e9;
    float3 bestC = c;
    for (int i = 0; i < n; i++) {
        float3 d = c - u.palette[i].rgb;
        float dist = dot(d * d, float3(0.30, 0.59, 0.11));   // 感知加权(人眼对绿最敏)
        if (dist < best) { best = dist; bestC = u.palette[i].rgb; }
    }
    return float4(bestC, 1.0);
}
