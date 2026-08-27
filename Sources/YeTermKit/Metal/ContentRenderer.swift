// ─────────────────────────────────────────────────────────────────────────────
// 📖 初学者导读 —— 把"字符网格"画成图片的人(阅读顺序第 8 站)
//
// 这个文件:终端内核(SwiftTerm)里的数据是一个二维格子——每格记着
//   "什么字、什么颜色、什么样式"。本类逐格读出来,画成一张 GPU 位图(纹理),
//   交给 CRT 层加特效。这是「任意字体×中文×全特效」(本项目最大卖点)的
//   技术根基:特效只认这张图,不关心字体,所以任何字体都能上特效。
//
// GPU 绘制的思路(和 Canvas 逐个 drawText 完全不同):
//   把每个格子变成一条"实例"数据(位置/图集坐标/颜色),一次性甩给 GPU,
//   GPU 用同一个小四边形画几千次(instanced draw)。类比:不是一封封发邮件,
//   而是做一张 Excel 名单交给邮局批量发 —— CPU 只做"填表"。
//
// 两个性能设计:
//   ▸ 行级脏缓存 rowCaches:只有变化的行重新"填表",其余行直接复用
//     (打一个字只重建一行,成本从 O(整屏) 降到 O(1 行))。
//   ▸ 三缓冲轮转 bufferRings:GPU 可能还在读上一帧的表,不能原地覆写,
//     三张表轮着用(类比无锁双缓冲,多一份保险)。
//
// 语法看点:
//   `struct QuadInstance` —— 值类型结构体,内存布局和 C 一样紧凑,
//     能直接 memcpy 进 GPU 缓冲(Java 里得靠 ByteBuffer 手拼)。
//   `SIMD4<Float>` —— 四维向量,GPU 数学的基本单位。
//   `[weak/unowned]` 没出现,但 `mutating`/`inout` 值语义很多:Swift 的
//     struct 赋值即拷贝(写时复制),和 Java 的引用语义是两种世界观。
// ─────────────────────────────────────────────────────────────────────────────
import AppKit
import CoreText
import Metal
import simd
import SwiftTerm

/// 内容渲染器(M1a-2):字符网格 → 内容纹理。cool-retro-term 内容层的 Metal 等价物。
/// 每帧成本 = 遍历网格构建实例(纯查表)+ 一次 instanced draw —— 无 CoreText 全幅重绘、无捕获。
final class ContentRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ctx: MetalContext

    private var atlas: GlyphAtlas?
    private var atlasFontName = ""
    private var atlasFontSize: CGFloat = 0
    private var atlasScale: CGFloat = 0
    private var atlasMatrixA: CGFloat = 1    // 字体矩阵横向缩放(fontWidth),变了要重建图集

    private(set) var cellPx: (w: Int, h: Int) = (0, 0)
    private var contentTexture: MTLTexture?

    private var bgPipeline: MTLRenderPipelineState?
    private var glyphPipeline: MTLRenderPipelineState?
    private var imagePipeline: MTLRenderPipelineState?   // 图片条带直贴(v1.2 #4)

    private struct QuadInstance {
        var rectPx: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var color: SIMD4<Float>
    }
    private struct GridUniforms {
        var viewportPx: SIMD2<Float>
    }

    // 按行实例缓存(性能核心):只重建脏行,其余行直接拼接 —— 单行变化的
    // CPU 成本从 O(整屏) 降到 O(一行)+扁平拷贝
    private struct RowCache {
        var bg: [QuadInstance] = []
        var glyph: [QuadInstance] = []
        var line: [QuadInstance] = []
        // 终端图片条带(v1.2 #4):独立纹理,不进 instanced 批 —— 单独 draw
        var images: [(tex: MTLTexture, rectPx: SIMD4<Float>)] = []
        // 上游 BufferLine.generation 快照:行内容原地变化(如图片 attach)不走
        // rangeChanged 事件,靠这个计数器兜底失效(上游注释明言为此设计)
        var generation: UInt64 = 0
        var valid = false
    }

    // 图片条带纹理缓存:key = 条带对象(弱引用,条带随 scrollback 释放时条目自清)
    // 【学】NSMapTable weakToStrong = "key 没人要了就自动删条目"的字典,防纹理泄漏
    private let imageTextureCache = NSMapTable<AnyObject, AnyObject>.weakToStrongObjects()
    private var rowCaches: [RowCache] = []
    private var lastSelection: Selection?

    // 常驻实例缓冲池:三缓冲轮转(避免每帧 makeBuffer 抖动;
    // 轮转 3 帧后才复用同一 buffer,规避 wait:false 下 GPU 未读完就被 CPU 覆写)
    private var bufferRings: [[MTLBuffer?]] = [[nil, nil, nil], [nil, nil, nil], [nil, nil, nil]]
    private var ringCursor = 0

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.device = ctx.device
        self.queue = ctx.queue
    }

    /// 显存账本条目(VRAMProbe 诊断用,只读;不参与渲染)。
    /// 图集是**每个 ContentRenderer 各自一份**(每 pane / 标签栏 / OSD 各一个),
    /// 这条账正是为了把那份重复摊到明面上。
    var probeTextures: [(String, MTLTexture?)] {
        var out: [(String, MTLTexture?)] = [("pane.内容纹理", contentTexture),
                                            ("pane.字形图集", atlas?.texture)]
        if let e = imageTextureCache.objectEnumerator() {
            for obj in e {
                if let t = obj as? MTLTexture { out.append(("pane.终端图片", t)) }
            }
        }
        return out
    }

    /// 实例缓冲池(三缓冲轮转)占的显存
    var probeBufferBytes: Int {
        bufferRings.flatMap { $0 }.compactMap { $0?.allocatedSize }.reduce(0, +)
    }

    /// 图集使用率 + 这个 renderer 用的字体(诊断:多 pane 同字体 = 图集可共享)
    var probeAtlasUsage: String? {
        guard let a = atlas else { return nil }
        let u = a.probeUsage
        let pct = Double(u.usedRows) / Double(u.capacityRows) * 100
        return String(format: "%@ %.0fpt: %d 字形/用掉 %d 行像素(共 %d, %.0f%%), cell=%dx%d",
                      atlasFontName, atlasFontSize, u.glyphs, u.usedRows, u.capacityRows,
                      pct, cellPx.w, cellPx.h)
    }

    /// IME 预编辑(拼音):画进特效层,替代 M0 的「掀开」权宜
    struct Preedit {
        let text: String
        let col: Int
        let row: Int
    }

    /// 选区(缓冲区绝对坐标,start/end 未排序 —— 语义同 SwiftTerm SelectionService)。
    /// 渲染 = **反色**(Konsole/crterm 同款:选中格前景/背景互换,亮块黑字),
    /// 进行缓存;选区变化只重建受影响行。
    struct Selection {
        let start: Position
        let end: Position
        let yDisp: Int      // 视口首行的缓冲区行号(视口行 r ↔ 缓冲行 yDisp+r)

        static func equals(_ a: Selection?, _ b: Selection?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return x.start == y.start && x.end == y.end && x.yDisp == y.yDisp
            default: return false
            }
        }

        /// 覆盖的视口行区间(clamp 后;nil = 不在视口内)
        func viewportRows(rows: Int) -> ClosedRange<Int>? {
            let lo = max(0, min(start.row, end.row) - yDisp)
            let hi = min(rows - 1, max(start.row, end.row) - yDisp)
            return lo <= hi ? lo...hi : nil
        }

        /// 该缓冲行的选中列区间。逻辑逐行照抄上游 AppleTerminalView.selectedColumnsRange
        /// (含正反向拖选与行尾 extra 补格),保证高亮与 getSelection() 复制的文本一致。
        func columnsRange(bufferRow row: Int, cols: Int) -> Range<Int>? {
            let sR = start.row, eR = end.row, sC = start.col, eC = end.col
            var loc = 0, len = 0
            if sR == eR {
                guard row == sR else { return nil }
                if sC < eC {
                    loc = sC; len = eC - sC + (eC == cols - 1 ? 1 : 0)
                } else if sC > eC {
                    loc = eC; len = sC - eC
                }
            } else if eR > sR {
                if row == sR { loc = sC; len = cols - sC }
                else if row > sR && row < eR { loc = 0; len = cols }
                else if row == eR { loc = 0; len = eC + (eC == cols - 1 ? 1 : 0) }
            } else {
                if row == eR { loc = eC; len = cols - eC }
                else if row > eR && row < sR { loc = 0; len = cols }
                else if row == sR { loc = 0; len = sC + (sC == cols - 1 ? 1 : 0) }
            }
            guard len > 0 else { return nil }
            let lower = max(0, min(loc, cols))
            let upper = max(lower, min(cols, loc + len))
            return lower < upper ? lower..<upper : nil
        }
    }

    /// 渲染整个网格。font/scale 变化时自动重建图集。
    /// 返回内容纹理(bgra8Unorm,cols*cellW × rows*cellH 像素)。
    /// `wait`:harness 需在回读前等待 GPU 完成;GUI 传 false——
    /// 后续 CRT pass 在同一 queue 上 FIFO 串行,天然有序,主线程无需停等。
    func render(terminal: Terminal, font: NSFont, scale: CGFloat,
                preedit: Preedit? = nil, selection: Selection? = nil,
                linkHighlight: [(row: Int, range: Range<Int>)]? = nil,
                failedRows: [Int]? = nil,
                transparentDefaultBg: Bool = false,
                dirtyRows: IndexSet? = nil, wait: Bool = true) -> MTLTexture? {
        // 图集生命周期(字体/字号/scale/字宽矩阵变化 → 重建并全量失效)
        let matrixA = CTFontGetMatrix(font as CTFont).a
        if atlas == nil || atlasFontName != font.fontName || atlasFontSize != font.pointSize
            || atlasScale != scale || atlasMatrixA != matrixA {
            cellPx = GlyphAtlas.cellSize(font: font, scale: scale)
            atlas = GlyphAtlas(device: device, font: font, cellPx: cellPx, scale: scale)
            atlasFontName = font.fontName
            atlasFontSize = font.pointSize
            atlasScale = scale
            atlasMatrixA = matrixA
            rowCaches.removeAll()
        }
        guard let atlas else { return nil }

        let cols = terminal.cols, rows = terminal.rows
        guard cols > 0, rows > 0 else { return nil }
        let texW = cols * cellPx.w, texH = rows * cellPx.h

        if contentTexture == nil || contentTexture!.width != texW || contentTexture!.height != texH {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                width: texW, height: texH,
                                                                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            contentTexture = device.makeTexture(descriptor: desc)
            rowCaches.removeAll()
        }
        guard let target = contentTexture else { return nil }

        // ---- 脏行缓存:只重建失效行 ----
        if rowCaches.count != rows {
            rowCaches = Array(repeating: RowCache(), count: rows)
        }
        if let dirty = dirtyRows {
            for r in dirty where r >= 0 && r < rows { rowCaches[r].valid = false }
        } else {
            for i in rowCaches.indices { rowCaches[i].valid = false }   // nil = 全量
        }
        // 选区变化 → 新旧选区覆盖的行失效(反色进行缓存;拖选每步只重建差异行)
        if !Selection.equals(selection, lastSelection) {
            for range in [selection?.viewportRows(rows: rows),
                          lastSelection?.viewportRows(rows: rows)].compactMap({ $0 }) {
                for r in range { rowCaches[r].valid = false }
            }
            lastSelection = selection
        }

        let cw = Float(cellPx.w), chh = Float(cellPx.h)
        // generation 兜底失效:图片 attach 等"原地变异"不发脏行事件(v1.2 #4 实测),
        // 逐行比对上游计数器,不一致即重建(纯整数比较,O(rows) 可忽略)
        for row in 0..<rows where rowCaches[row].valid {
            if let line = terminal.getLine(row: row), line.generation != rowCaches[row].generation {
                rowCaches[row].valid = false
            }
        }
        // 行构建(图集扩容护栏,2026-08-07):buildRow 里首次遇到的字形会栅格化,
        // 可能把图集撑到扩容 —— 而 uv 是按图集边长**归一化**的,一扩容,**本帧
        // 已建好的那些行**存的 uv 就全指错了(前半屏字形错位/空白一帧)。
        // 故:建完一轮比对 generation,变了就把本帧成果整体作废重来。
        // 至多重来一次 —— 第二轮所有字形都已在图集里,不会再触发扩容。
        var atlasGen = atlas.generation
        for _ in 0..<2 {
            // 预热 IME 预编辑字形:拼音覆盖层是在行拼接**之后**才取 uv 的,若让它
            // 在那时才首次栅格化并撑到扩容,已拼好的整屏 uv 会被带歪。提前到这里
            // 触发,扩容就落在下面的 generation 检查点之内。
            if let p = preedit {
                for ch in p.text {
                    _ = atlas.slot(text: String(ch), wide: Self.isWideChar(ch),
                                   bold: false, italic: false)
                }
            }
            for row in 0..<rows where !rowCaches[row].valid {
                rowCaches[row] = buildRow(row: row, terminal: terminal, atlas: atlas,
                                          cols: cols, cw: cw, chh: chh, selection: selection)
            }
            if atlas.generation == atlasGen { break }
            atlasGen = atlas.generation
            for i in rowCaches.indices { rowCaches[i].valid = false }
        }

        // 扁平拼接(纯数组拷贝,无解码/查表)
        var bgInstances: [QuadInstance] = []
        var glyphInstances: [QuadInstance] = []
        var lineInstances: [QuadInstance] = []
        bgInstances.reserveCapacity(rowCaches.reduce(0) { $0 + $1.bg.count } + 64)
        glyphInstances.reserveCapacity(rowCaches.reduce(0) { $0 + $1.glyph.count } + 64)

        // 预编辑挤压后移(v1.1.2 用户实测勘差):行中间打拼音时,光标列之后的
        // 既有字符整体右移拼音宽度、超出屏宽的裁掉(iTerm2/系统终端同款行为),
        // 拼音不再叠在既有字符上。只在拼接层现算平移,不碰行缓存 —— 预编辑
        // 消失后下一帧自然复原,无缓存污染。
        var preeditShift: (row: Int, startX: Float, shiftX: Float)?
        if let p = preedit, !p.text.isEmpty, p.row >= 0, p.row < rows {
            let cells = p.text.reduce(0) { $0 + (Self.isWideChar($1) ? 2 : 1) }
            preeditShift = (p.row, Float(p.col) * cw, Float(cells) * cw)
        }
        let texWf = Float(texW)
        for (row, cache) in rowCaches.enumerated() {
            if let ps = preeditShift, ps.row == row, ps.shiftX > 0 {
                func shifted(_ arr: [QuadInstance]) -> [QuadInstance] {
                    arr.compactMap { q in
                        var q = q
                        if q.rectPx.x >= ps.startX - 0.5 {      // 光标列及之后 → 右移
                            q.rectPx.x += ps.shiftX
                            if q.rectPx.x >= texWf { return nil }   // 移出屏外的裁掉
                        }
                        return q
                    }
                }
                bgInstances.append(contentsOf: shifted(cache.bg))
                glyphInstances.append(contentsOf: shifted(cache.glyph))
                lineInstances.append(contentsOf: shifted(cache.line))
            } else {
                bgInstances.append(contentsOf: cache.bg)
                glyphInstances.append(contentsOf: cache.glyph)
                lineInstances.append(contentsOf: cache.line)
            }
        }

        // ---- IME 预编辑(拼音)覆盖层:淡底 + 字形 + 下划线,从光标格起排 ----
        if let p = preedit, !p.text.isEmpty, p.row >= 0, p.row < rows {
            let y = Float(p.row) * chh
            var col = p.col
            let startCol = col
            let fg = AnsiColor.defaultFg
            for ch in p.text {
                let wide = Self.isWideChar(ch)
                let w = wide ? 2 : 1
                if col + w > cols { break }
                let x = Float(col) * cw
                bgInstances.append(QuadInstance(rectPx: .init(x, y, cw * Float(w), chh),
                                                uvRect: .zero,
                                                color: .init(fg * 0.22, 1)))
                if let slot = atlas.slot(text: String(ch), wide: wide, bold: false, italic: false) {
                    glyphInstances.append(QuadInstance(rectPx: .init(x, y, cw * Float(w), chh),
                                                       uvRect: slot.uv,
                                                       color: slot.isColor ? .init(1, 1, 1, 2)
                                                                           : .init(fg, 1)))
                }
                col += w
            }
            if col > startCol {
                lineInstances.append(QuadInstance(
                    rectPx: .init(Float(startCol) * cw, y + chh - Float(max(2, cellPx.h / 10)),
                                  Float(col - startCol) * cw, Float(max(2, cellPx.h / 12))),
                    uvRect: .zero,
                    color: .init(fg, 1)))
            }
        }

        // ---- ⌘悬停链接下划线(v1.1 #5)覆盖层:每次现画、不进行缓存 ----
        // 重绘时机由 SwiftTerm 保证:悬停高亮变化 → 其 invalidateLinkHighlight →
        // rangeChanged 事件 → 行置脏,这里只管"当前有高亮就画线"。
        // 白色下划线经 CRT 染色即主题荧光色,与预编辑下划线同一质感。
        if let links = linkHighlight {
            let fg = AnsiColor.defaultFg
            for l in links where l.row >= 0 && l.row < rows && !l.range.isEmpty {
                lineInstances.append(QuadInstance(
                    rectPx: .init(Float(l.range.lowerBound) * cw,
                                  Float(l.row) * chh + chh - Float(max(2, cellPx.h / 10)),
                                  Float(l.range.count) * cw,
                                  Float(max(2, cellPx.h / 12))),
                    uvRect: .zero,
                    color: .init(fg, 1)))
            }
        }

        // ---- 失败命令 ✗ 标记(v1.2 #3)覆盖层:失败命令的提示符行左缘一根
        // 红色荧光短竖条 —— 画进内容纹理,经 CRT 管线自带辉光/扫描线,风格统一。
        // 纯红在单色主题(chroma=0)下会被染成主题荧光色,依旧醒目;彩色主题下即红。
        if let fails = failedRows {
            for row in fails where row >= 0 && row < rows {
                lineInstances.append(QuadInstance(
                    rectPx: .init(0, Float(row) * chh + chh * 0.15,
                                  Float(max(2, cellPx.w / 4)), chh * 0.7),
                    uvRect: .zero,
                    color: .init(1, 0.25, 0.2, 1)))
            }
        }

        // ---- 编码 ----
        do {
            try ensurePipelines()
        } catch {
            FileHandle.standardError.write(Data("TextGrid 管线创建失败: \(error)\n".utf8))
            return nil
        }
        guard let bgPipe = bgPipeline, let glyphPipe = glyphPipeline,
              let cmd = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // 透明清屏(v1.2 #16 普通模式背景图):默认底色格本就不画色块(下方
        // buildRow 的 bg != defaultBg 判定),清屏透明后这些格子露出合成层的
        // 背景图;字形以覆盖度混合落在透明底上 = 天然预乘 alpha 形式
        let bg = AnsiColor.defaultBg
        pass.colorAttachments[0].clearColor = transparentDefaultBg
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = GridUniforms(viewportPx: .init(Float(texW), Float(texH)))

        // 三缓冲轮转 + 倍增扩容 + memcpy
        ringCursor = (ringCursor + 1) % 3
        func upload(_ instances: [QuadInstance], ring: Int) -> MTLBuffer? {
            let length = MemoryLayout<QuadInstance>.stride * instances.count
            var slot = bufferRings[ring][ringCursor]
            if slot == nil || slot!.length < length {
                var cap = max(slot?.length ?? 16384, 16384)
                while cap < length { cap *= 2 }
                slot = device.makeBuffer(length: cap, options: .storageModeShared)
                bufferRings[ring][ringCursor] = slot
            }
            guard let buf = slot else { return nil }
            instances.withUnsafeBytes { p in
                buf.contents().copyMemory(from: p.baseAddress!, byteCount: length)
            }
            return buf
        }
        func draw(_ instances: [QuadInstance], buffer: MTLBuffer?, pipeline: MTLRenderPipelineState) {
            guard !instances.isEmpty, let buf = buffer else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
        draw(bgInstances, buffer: upload(bgInstances, ring: 0), pipeline: bgPipe)
        draw(glyphInstances, buffer: upload(glyphInstances, ring: 1), pipeline: glyphPipe)
        draw(lineInstances, buffer: upload(lineInstances, ring: 2), pipeline: bgPipe)

        // ---- 终端图片条带(v1.2 #4):每条带独立纹理 → 逐条单实例 draw ----
        // 条带数量级 = 图片高度的行数(几十以内),draw call 开销可忽略
        if let imgPipe = imagePipeline, rowCaches.contains(where: { !$0.images.isEmpty }) {
            enc.setRenderPipelineState(imgPipe)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            for cache in rowCaches {
                for d in cache.images {
                    var inst = QuadInstance(rectPx: d.rectPx,
                                            uvRect: .init(0, 0, 1, 1),
                                            color: .init(1, 1, 1, 1))
                    enc.setVertexBytes(&inst, length: MemoryLayout<QuadInstance>.stride, index: 0)
                    enc.setFragmentTexture(d.tex, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                }
            }
        }

        enc.endEncoding()
        cmd.commit()
        if wait {
            cmd.waitUntilCompleted()
        }
        return target
    }

    private func ensurePipelines() throws {
        guard bgPipeline == nil || glyphPipeline == nil || imagePipeline == nil else { return }
        let vertex = try ctx.function("grid_vertex", library: "TextGrid")

        func make(fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = try ctx.function(fragment, library: "TextGrid")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                let att = desc.colorAttachments[0]!
                att.isBlendingEnabled = true
                att.sourceRGBBlendFactor = .sourceAlpha
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.sourceAlphaBlendFactor = .one
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            // 走 MetalContext 统一漏斗 → 命中管线二进制缓存(v1.2 #1)
            return try ctx.makePipeline(desc)
        }
        bgPipeline = try make(fragment: "grid_bg_fragment", blending: false)
        glyphPipeline = try make(fragment: "grid_glyph_fragment", blending: true)
        imagePipeline = try make(fragment: "grid_image_fragment", blending: true)
    }

    /// 自测钩子(PerfProbe 用):返回一个「重建指定行」的闭包,走的是与真实渲染
    /// **同一段** buildRow 代码 —— 探针必须测真实路径,另抄一份就测了个寂寞。
    /// 只做 CPU 侧实例构建,不提交 GPU;Metal 设备不可用时返回 nil。
    static func makeRowProbe(cols: Int, fontName: String = "Menlo",
                             fontSize: CGFloat = 14, scale: CGFloat = 2)
        -> ((Int, Terminal) -> Int)? {
        guard let ctx = MetalContext() else { return nil }
        let r = ContentRenderer(ctx: ctx)
        let font = TermHost.resolveFont(name: fontName, size: fontSize)
        r.cellPx = GlyphAtlas.cellSize(font: font, scale: scale)
        guard let atlas = GlyphAtlas(device: ctx.device, font: font,
                                     cellPx: r.cellPx, scale: scale) else { return nil }
        r.atlas = atlas
        let cw = Float(r.cellPx.w), chh = Float(r.cellPx.h)
        // 返回实例总数只为**制造副作用**,防止优化器把整个调用消掉
        return { row, terminal in
            let c = r.buildRow(row: row, terminal: terminal, atlas: atlas,
                               cols: cols, cw: cw, chh: chh)
            return c.glyph.count + c.bg.count + c.line.count
        }
    }

    /// 单行实例构建(脏行缓存的重建单元)
    private func buildRow(row: Int, terminal: Terminal, atlas: GlyphAtlas,
                          cols: Int, cw: Float, chh: Float, selection: Selection? = nil) -> RowCache {
        var cache = RowCache()
        cache.valid = true
        guard let line = terminal.getLine(row: row) else { return cache }
        cache.generation = line.generation
        let selRange = selection.flatMap { $0.columnsRange(bufferRow: $0.yDisp + row, cols: cols) }
        let y = Float(row) * chh
        for col in 0..<cols {
            let cd = line[col]
            if cd.width == 0 { continue }        // 宽字符 filler
            let wide = cd.width == 2
            let x = Float(col) * cw
            let w = cw * (wide ? 2 : 1)
            let attr = cd.attribute
            var (fg, bg) = AnsiColor.effective(attr: attr)
            if let sr = selRange, sr.contains(col) {
                // 选区配色(2026-08-27):自定义模式换底色,文字色未设则保留原色;
                // 反色模式(缺省)= 前景/背景互换(亮块黑字,历史行为)
                if let sel = AnsiColor.selectionOverride {
                    bg = sel.bg
                    fg = sel.fg ?? fg
                } else {
                    swap(&fg, &bg)
                }
            }

            if bg != AnsiColor.defaultBg {
                cache.bg.append(QuadInstance(rectPx: .init(x, y, w, chh),
                                             uvRect: .zero,
                                             color: .init(bg, 1)))
            }

            // ⚠️ 必须走 terminal 带侧表的解码(2026-08-06「p10k 图标 󰜷 空白」根修):
            // SwiftTerm 对非 BMP 字符(UTF-16 双码元 —— 第 15/16 平面 Nerd 图标、
            // emoji)不存码位,CharData.code 里是侧表索引(0x400001 起);
            // cd.getCharacter() 无上下文还原不出来、兜底返回空格 → 整格被当空白跳过
            let chr = terminal.getCharacter(for: cd)
            if chr != " " && chr != "\0" && !attr.style.contains(.invisible) {
                if let slot = atlas.slot(text: String(chr), wide: wide,
                                         bold: attr.style.contains(.bold),
                                         italic: attr.style.contains(.italic)) {
                    // 彩色字形(emoji,issue #1):alpha=2 哨兵让 shader 原色直出,
                    // 不吃前景染色(选中/反色下 emoji 也保持彩色,Terminal.app 同款)
                    cache.glyph.append(QuadInstance(rectPx: .init(x, y, w, chh),
                                                    uvRect: slot.uv,
                                                    color: slot.isColor ? .init(1, 1, 1, 2)
                                                                        : .init(fg, 1)))
                }
            }

            if attr.style.contains(.underline) {
                cache.line.append(QuadInstance(rectPx: .init(x, y + chh - Float(max(2, cellPx.h / 10)), w, Float(max(2, cellPx.h / 12))),
                                               uvRect: .zero,
                                               color: .init(fg, 1)))
            }
            if attr.style.contains(.crossedOut) {
                cache.line.append(QuadInstance(rectPx: .init(x, y + chh / 2, w, Float(max(2, cellPx.h / 12))),
                                               uvRect: .zero,
                                               color: .init(fg, 1)))
            }
        }

        // ---- 终端图片条带(v1.2 #4)----
        // SwiftTerm 把图片按行切条挂在 BufferLine.images(internal → Mirror 反射,
        // 只发生在脏行重建时,行缓存摊销后每帧零反射)。条带 NSImage → MTLTexture
        // 有对象级缓存,同一条带只转换一次。宽高:AppleImage 存逻辑点,×scale 转像素。
        for img in imagesOf(line: line) {
            guard let tex = imageTexture(for: img) else { continue }
            let wPx = Float(CGFloat(img.pixelWidth) * atlasScale)
            cache.images.append((tex: tex,
                                 rectPx: .init(Float(img.col) * cw, y, wPx, chh)))
        }
        return cache
    }

    /// Mirror 挖 BufferLine.images(上游 internal;探针有哨兵,属性改名立刻红)
    private func imagesOf(line: BufferLine) -> [TerminalImage] {
        for child in Mirror(reflecting: line).children where child.label == "images" {
            return (child.value as? [TerminalImage]) ?? []
        }
        return []
    }

    /// 条带 → MTLTexture(BGRA8 非 sRGB,守全链色彩纪律);对象级缓存
    private func imageTexture(for img: TerminalImage) -> MTLTexture? {
        let key = img as AnyObject
        if let cached = imageTextureCache.object(forKey: key) as? MTLTexture { return cached }
        // AppleImage.image(NSImage)也是 internal → 同一把 Mirror 钥匙
        var nsImage: NSImage?
        for child in Mirror(reflecting: img).children where child.label == "image" {
            nsImage = child.value as? NSImage
        }
        guard let nsImage,
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx2 = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: info) else { return nil }
        ctx2.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: buf, bytesPerRow: w * 4)
        imageTextureCache.setObject(tex, forKey: key)
        return tex
    }

    /// 热重载
    func invalidatePipelines() {
        bgPipeline = nil
        glyphPipeline = nil
        imagePipeline = nil
    }

    /// 预编辑宽字符启发式(拼音场景够用;正式网格宽度一律以 CharData.width 为准)
    static func isWideChar(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
