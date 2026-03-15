import Metal
import MetalKit
import CoreText
import MatchaKit

class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let bgPipeline: MTLRenderPipelineState
    let textPipeline: MTLRenderPipelineState
    let cursorPipeline: MTLRenderPipelineState

    var glyphAtlasTexture: MTLTexture?
    var glyphCache: [UInt32: GlyphUV] = [:]
    let ctFont: CTFont
    let cellWidth: Float
    let cellHeight: Float

    struct GlyphUV {
        var uvX: Float
        var uvY: Float
        var uvW: Float
        var uvH: Float
        var bearingX: Float
        var bearingY: Float
        var glyphWidth: Float
        var glyphHeight: Float
    }

    struct QuadVertex {
        var x: Float
        var y: Float
        var u: Float
        var v: Float
        var r: Float
        var g: Float
        var b: Float
        var a: Float
    }

    // Atlas packing state
    var atlasWidth: Int = 2048
    var atlasHeight: Int = 2048
    var atlasData: [UInt8]
    var atlasCursorX: Int = 0
    var atlasCursorY: Int = 0
    var atlasRowHeight: Int = 0
    var atlasDirty = true

    var scaleFactor: Float = 2.0

    init?(device: MTLDevice, view: MTKView, font: NSFont, cellWidth: Float, cellHeight: Float, scaleFactor: Float = 2.0) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scaleFactor = scaleFactor
        self.ctFont = font as CTFont
        self.atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)

        // Create shader library
        guard let library = try? device.makeLibrary(source: MetalRenderer.shaderSource, options: nil) else {
            return nil
        }

        // Background pipeline (solid color quads)
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "bg_vertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "bg_fragment")
        bgDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        bgDesc.colorAttachments[0].isBlendingEnabled = true
        bgDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bgDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bgDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        bgDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Text pipeline (textured quads, alpha from atlas)
        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.vertexFunction = library.makeFunction(name: "text_vertex")
        textDesc.fragmentFunction = library.makeFunction(name: "text_fragment")
        textDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        textDesc.colorAttachments[0].isBlendingEnabled = true
        textDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        textDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        textDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Cursor pipeline (same as bg)
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = library.makeFunction(name: "bg_vertex")
        cursorDesc.fragmentFunction = library.makeFunction(name: "bg_fragment")
        cursorDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        cursorDesc.colorAttachments[0].isBlendingEnabled = true
        cursorDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cursorDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cursorDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        cursorDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
            self.textPipeline = try device.makeRenderPipelineState(descriptor: textDesc)
            self.cursorPipeline = try device.makeRenderPipelineState(descriptor: cursorDesc)
        } catch {
            return nil
        }
    }

    func draw(in view: MTKView, editor: MatchaEditor, cursorVisible: Bool) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Zig core works in points; convert to NDC using point-space dimensions
        let viewWidth = Float(view.drawableSize.width) / scaleFactor
        let viewHeight = Float(view.drawableSize.height) / scaleFactor

        // Get render data from Zig core
        let cells = editor.getCells()
        let cursors = editor.getCursors()
        let selections = editor.getSelections()
        let lineNumbers = editor.getLineNumbers()
        let bracketHighlights = editor.getBracketHighlights()

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // Pass 1: Cell backgrounds + selection rects (no gutter yet)
        encoder.setRenderPipelineState(bgPipeline)

        var bgQuads: [QuadVertex] = []
        for i in 0..<cells.count {
            let cell = cells[i]
            let bgColor = colorToRGBA(cell.bg)
            if bgColor.a > 0.01 {
                appendQuad(&bgQuads, x: cell.x, y: cell.y, w: cell.w, h: cell.h,
                           r: bgColor.r, g: bgColor.g, b: bgColor.b, a: bgColor.a,
                           viewWidth: viewWidth, viewHeight: viewHeight)
            }
        }

        // Selection rects
        for i in 0..<selections.count {
            let sel = selections[i]
            let rgba = colorToRGBA(sel.color)
            appendQuad(&bgQuads, x: sel.x, y: sel.y, w: sel.w, h: sel.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
                       viewWidth: viewWidth, viewHeight: viewHeight)
        }

        // Bracket highlights
        for i in 0..<bracketHighlights.count {
            let bh = bracketHighlights[i]
            let rgba = colorToRGBA(bh.color)
            appendQuad(&bgQuads, x: bh.x, y: bh.y, w: bh.w, h: bh.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
                       viewWidth: viewWidth, viewHeight: viewHeight)
        }

        if !bgQuads.isEmpty {
            let buffer = device.makeBuffer(bytes: bgQuads, length: bgQuads.count * MemoryLayout<QuadVertex>.stride, options: .storageModeShared)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bgQuads.count)
        }

        // Pass 2: Content text
        encoder.setRenderPipelineState(textPipeline)
        ensureAtlasTexture()

        var textQuads: [QuadVertex] = []
        for i in 0..<cells.count {
            let cell = cells[i]
            let codepoint = cell.glyph_index
            if codepoint <= 32 { continue } // skip control chars and space

            let uv = ensureGlyph(codepoint: codepoint)
            let fgColor = colorToRGBA(cell.fg)

            let ascender = Float(CTFontGetAscent(ctFont)) / scaleFactor
            let glyphX = cell.x + uv.bearingX
            let glyphY = cell.y + ascender - uv.bearingY

            appendTextQuad(&textQuads,
                           x: glyphX, y: glyphY,
                           w: uv.glyphWidth, h: uv.glyphHeight,
                           uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                           r: fgColor.r, g: fgColor.g, b: fgColor.b, a: fgColor.a,
                           viewWidth: viewWidth, viewHeight: viewHeight)
        }

        if !textQuads.isEmpty, let atlasTexture = glyphAtlasTexture {
            let buffer = device.makeBuffer(bytes: textQuads, length: textQuads.count * MemoryLayout<QuadVertex>.stride, options: .storageModeShared)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textQuads.count)
        }

        // Pass 3: Gutter backgrounds (drawn ON TOP of content to mask any overflow)
        encoder.setRenderPipelineState(bgPipeline)
        var gutterQuads: [QuadVertex] = []
        for i in 0..<lineNumbers.count {
            let ln = lineNumbers[i]
            let rgba = colorToRGBA(ln.color)
            appendQuad(&gutterQuads, x: ln.x, y: ln.y, w: ln.w, h: ln.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
                       viewWidth: viewWidth, viewHeight: viewHeight)
        }
        if !gutterQuads.isEmpty {
            let buffer = device.makeBuffer(bytes: gutterQuads, length: gutterQuads.count * MemoryLayout<QuadVertex>.stride, options: .storageModeShared)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gutterQuads.count)
        }

        // Pass 4: Line number text (on top of gutter)
        drawLineNumbers(encoder: encoder, lineNumbers: lineNumbers, viewWidth: viewWidth, viewHeight: viewHeight, editor: editor)

        // Pass 5: Cursors
        if cursorVisible {
            encoder.setRenderPipelineState(cursorPipeline)
            var cursorQuads: [QuadVertex] = []
            for i in 0..<cursors.count {
                let cursor = cursors[i]
                let rgba = colorToRGBA(cursor.color)
                appendQuad(&cursorQuads, x: cursor.x, y: cursor.y, w: cursor.w, h: cursor.h,
                           r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a,
                           viewWidth: viewWidth, viewHeight: viewHeight)
            }
            if !cursorQuads.isEmpty {
                let buffer = device.makeBuffer(bytes: cursorQuads, length: cursorQuads.count * MemoryLayout<QuadVertex>.stride, options: .storageModeShared)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursorQuads.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Line Numbers

    private func drawLineNumbers(encoder: MTLRenderCommandEncoder, lineNumbers: UnsafeBufferPointer<matcha_render_rect_s>, viewWidth: Float, viewHeight: Float, editor: MatchaEditor) {
        // Render line numbers as text using the text pipeline
        encoder.setRenderPipelineState(textPipeline)
        ensureAtlasTexture()

        var textQuads: [QuadVertex] = []
        let lineNumColor: (r: Float, g: Float, b: Float, a: Float) = (0.424, 0.439, 0.525, 1.0) // gutter text color

        let scrollY = editor.getScrollY()

        for i in 0..<lineNumbers.count {
            let ln = lineNumbers[i]
            // y = line * cell_h - scroll_y, so line = (y + scroll_y) / cell_h
            let actualLine = Int((ln.y + scrollY) / ln.h) + 1

            let numStr = String(actualLine)
            let gutterW = ln.w
            let rightPad = cellWidth * 0.5

            // Render each digit right-aligned in the gutter
            for (charIdx, char) in numStr.enumerated() {
                let codepoint = UInt32(char.asciiValue ?? 48)
                let uv = ensureGlyph(codepoint: codepoint)

                let ascender = Float(CTFontGetAscent(ctFont)) / scaleFactor
                let digitX = gutterW - Float(numStr.count - charIdx) * cellWidth - rightPad
                let digitY = ln.y + ascender - uv.bearingY

                appendTextQuad(&textQuads,
                               x: digitX + uv.bearingX, y: digitY,
                               w: uv.glyphWidth, h: uv.glyphHeight,
                               uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                               r: lineNumColor.r, g: lineNumColor.g, b: lineNumColor.b, a: lineNumColor.a,
                               viewWidth: viewWidth, viewHeight: viewHeight)
            }
        }

        if !textQuads.isEmpty, let atlasTexture = glyphAtlasTexture {
            let buffer = device.makeBuffer(bytes: textQuads, length: textQuads.count * MemoryLayout<QuadVertex>.stride, options: .storageModeShared)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textQuads.count)
        }
    }

    // MARK: - Glyph Atlas

    private func ensureAtlasTexture() {
        if glyphAtlasTexture == nil || atlasDirty {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: atlasWidth,
                height: atlasHeight,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            glyphAtlasTexture = device.makeTexture(descriptor: desc)
        }

        if atlasDirty, let tex = glyphAtlasTexture {
            tex.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: atlasWidth, height: atlasHeight, depth: 1)),
                mipmapLevel: 0,
                withBytes: atlasData,
                bytesPerRow: atlasWidth
            )
            atlasDirty = false
        }
    }

    private func ensureGlyph(codepoint: UInt32) -> GlyphUV {
        if let cached = glyphCache[codepoint] {
            return cached
        }

        // Rasterize glyph using CoreText
        var chars = [UniChar](repeating: 0, count: 2)
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        var count = 1

        if codepoint <= 0xFFFF {
            chars[0] = UniChar(codepoint)
        } else {
            let hi = (codepoint - 0x10000) >> 10 + 0xD800
            let lo = (codepoint - 0x10000) & 0x3FF + 0xDC00
            chars[0] = UniChar(hi)
            chars[1] = UniChar(lo)
            count = 2
        }

        CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, count)

        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .default, glyphs, &boundingRect, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .default, glyphs, &advance, 1)

        let padding: CGFloat = 2
        let glyphW = Int(ceil(boundingRect.width) + padding * 2)
        let glyphH = Int(ceil(boundingRect.height) + padding * 2)

        if glyphW <= 0 || glyphH <= 0 {
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        // Allocate space in atlas
        if atlasCursorX + glyphW > atlasWidth {
            atlasCursorX = 0
            atlasCursorY += atlasRowHeight + 1
            atlasRowHeight = 0
        }

        if atlasCursorY + glyphH > atlasHeight {
            // Atlas full
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        // Render glyph to bitmap
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: glyphW, height: glyphH,
                                  bitsPerComponent: 8, bytesPerRow: glyphW,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))

        let originX = padding - boundingRect.origin.x
        let originY = padding - boundingRect.origin.y
        let position = CGPoint(x: originX, y: originY)

        ctx.setFillColor(gray: 1, alpha: 1)
        CTFontDrawGlyphs(ctFont, glyphs, [position], 1, ctx)

        // Copy bitmap to atlas
        if let data = ctx.data {
            let ptr = data.bindMemory(to: UInt8.self, capacity: glyphW * glyphH)
            for row in 0..<glyphH {
                for col in 0..<glyphW {
                    let srcIdx = row * glyphW + col
                    let dstIdx = (atlasCursorY + row) * atlasWidth + (atlasCursorX + col)
                    atlasData[dstIdx] = ptr[srcIdx]
                }
            }
        }

        let uvX = Float(atlasCursorX) / Float(atlasWidth)
        let uvY = Float(atlasCursorY) / Float(atlasHeight)
        let uvW = Float(glyphW) / Float(atlasWidth)
        let uvH = Float(glyphH) / Float(atlasHeight)

        // Glyph was rasterized at scaled size; convert metrics back to points
        let s = scaleFactor
        let uv = GlyphUV(
            uvX: uvX, uvY: uvY, uvW: uvW, uvH: uvH,
            bearingX: Float(boundingRect.origin.x - padding) / s,
            bearingY: Float(boundingRect.origin.y + boundingRect.height + padding) / s,
            glyphWidth: Float(glyphW) / s,
            glyphHeight: Float(glyphH) / s
        )

        glyphCache[codepoint] = uv
        atlasCursorX += glyphW + 1
        atlasRowHeight = max(atlasRowHeight, glyphH)
        atlasDirty = true

        return uv
    }

    // MARK: - Geometry Helpers

    private func appendQuad(_ quads: inout [QuadVertex],
                            x: Float, y: Float, w: Float, h: Float,
                            r: Float, g: Float, b: Float, a: Float,
                            viewWidth: Float, viewHeight: Float) {
        let x0 = (x / viewWidth) * 2.0 - 1.0
        let y0 = 1.0 - (y / viewHeight) * 2.0
        let x1 = ((x + w) / viewWidth) * 2.0 - 1.0
        let y1 = 1.0 - ((y + h) / viewHeight) * 2.0

        quads.append(QuadVertex(x: x0, y: y0, u: 0, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y0, u: 1, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x0, y: y1, u: 0, v: 1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y0, u: 1, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y1, u: 1, v: 1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x0, y: y1, u: 0, v: 1, r: r, g: g, b: b, a: a))
    }

    private func appendTextQuad(_ quads: inout [QuadVertex],
                                x: Float, y: Float, w: Float, h: Float,
                                uvX: Float, uvY: Float, uvW: Float, uvH: Float,
                                r: Float, g: Float, b: Float, a: Float,
                                viewWidth: Float, viewHeight: Float) {
        let x0 = (x / viewWidth) * 2.0 - 1.0
        let y0 = 1.0 - (y / viewHeight) * 2.0
        let x1 = ((x + w) / viewWidth) * 2.0 - 1.0
        let y1 = 1.0 - ((y + h) / viewHeight) * 2.0

        let u0 = uvX
        let v0 = uvY
        let u1 = uvX + uvW
        let v1 = uvY + uvH

        quads.append(QuadVertex(x: x0, y: y0, u: u0, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y0, u: u1, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x0, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y0, u: u1, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y1, u: u1, v: v1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x0, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
    }

    private func colorToRGBA(_ color: UInt32) -> (r: Float, g: Float, b: Float, a: Float) {
        let r = Float((color >> 24) & 0xFF) / 255.0
        let g = Float((color >> 16) & 0xFF) / 255.0
        let b = Float((color >> 8) & 0xFF) / 255.0
        let a = Float(color & 0xFF) / 255.0
        return (r, g, b, a)
    }

    // MARK: - Metal Shaders (inline source)

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex {
        float x;
        float y;
        float u;
        float v;
        float r;
        float g;
        float b;
        float a;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texcoord;
        float4 color;
    };

    // Background / cursor vertex shader
    vertex VertexOut bg_vertex(const device QuadVertex* vertices [[buffer(0)]],
                               uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(vertices[vid].x, vertices[vid].y, 0.0, 1.0);
        out.texcoord = float2(vertices[vid].u, vertices[vid].v);
        out.color = float4(vertices[vid].r, vertices[vid].g, vertices[vid].b, vertices[vid].a);
        return out;
    }

    fragment float4 bg_fragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    // Text vertex shader (same geometry, but samples atlas)
    vertex VertexOut text_vertex(const device QuadVertex* vertices [[buffer(0)]],
                                 uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(vertices[vid].x, vertices[vid].y, 0.0, 1.0);
        out.texcoord = float2(vertices[vid].u, vertices[vid].v);
        out.color = float4(vertices[vid].r, vertices[vid].g, vertices[vid].b, vertices[vid].a);
        return out;
    }

    fragment float4 text_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float alpha = atlas.sample(s, in.texcoord).r;
        return float4(in.color.rgb, in.color.a * alpha);
    }
    """
}
