import Metal
import MetalKit
import CoreText
import MatchaKit

class MetalRenderer {
    private static let quadStride = MemoryLayout<QuadVertex>.stride

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let colorPipeline: MTLRenderPipelineState
    let textPipeline: MTLRenderPipelineState

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

    struct ViewportUniforms {
        var width: Float
        var height: Float
    }

    // Atlas packing state
    var atlasWidth: Int = 2048
    var atlasHeight: Int = 2048
    var atlasData: [UInt8]
    var atlasCursorX: Int = 0
    var atlasCursorY: Int = 0
    var atlasRowHeight: Int = 0
    var atlasDirty = false
    // Dirty region tracking for partial upload
    var atlasDirtyMinX: Int = Int.max
    var atlasDirtyMinY: Int = Int.max
    var atlasDirtyMaxX: Int = 0
    var atlasDirtyMaxY: Int = 0

    var scaleFactor: Float = 2.0
    let ascender: Float

    private var bgQuads: [QuadVertex] = []
    private var textQuads: [QuadVertex] = []
    private var gutterQuads: [QuadVertex] = []
    private var cursorQuads: [QuadVertex] = []
    private var lineNumberQuads: [QuadVertex] = []

    private var bgVertexBuffer: MTLBuffer?
    private var textVertexBuffer: MTLBuffer?
    private var gutterVertexBuffer: MTLBuffer?
    private var cursorVertexBuffer: MTLBuffer?
    private var lineNumberVertexBuffer: MTLBuffer?
    private var viewportBuffer: MTLBuffer?

    init?(device: MTLDevice, view: MTKView, font: NSFont, cellWidth: Float, cellHeight: Float, scaleFactor: Float = 2.0) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scaleFactor = scaleFactor
        self.ctFont = font as CTFont
        self.ascender = Float(CTFontGetAscent(font as CTFont)) / scaleFactor
        self.atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)

        guard let library = try? device.makeLibrary(source: MetalRenderer.shaderSource, options: nil) else {
            return nil
        }

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        blendDesc.colorAttachments[0].isBlendingEnabled = true
        blendDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Color pipeline (solid quads: backgrounds, selections, cursors)
        let colorDesc = MTLRenderPipelineDescriptor()
        colorDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        colorDesc.fragmentFunction = library.makeFunction(name: "fragment_color")
        colorDesc.colorAttachments[0] = blendDesc.colorAttachments[0]

        // Text pipeline (textured quads: glyphs from atlas)
        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        textDesc.fragmentFunction = library.makeFunction(name: "fragment_text")
        textDesc.colorAttachments[0] = blendDesc.colorAttachments[0]

        do {
            self.colorPipeline = try device.makeRenderPipelineState(descriptor: colorDesc)
            self.textPipeline = try device.makeRenderPipelineState(descriptor: textDesc)
        } catch {
            return nil
        }

        self.viewportBuffer = device.makeBuffer(length: MemoryLayout<ViewportUniforms>.size, options: .storageModeShared)
    }

    func draw(in view: MTKView, editor: MatchaEditor, cursorVisible: Bool) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let viewWidth = Float(view.drawableSize.width) / scaleFactor
        let viewHeight = Float(view.drawableSize.height) / scaleFactor

        // Update viewport uniform
        var viewport = ViewportUniforms(width: viewWidth, height: viewHeight)
        viewportBuffer?.contents().copyMemory(from: &viewport, byteCount: MemoryLayout<ViewportUniforms>.size)

        // Get render data from Zig core
        let cells = editor.getCells()
        let cursors = editor.getCursors()
        let selections = editor.getSelections()
        let gutterRows = editor.getGutterRows()
        let lineNumberLabels = editor.getLineNumberLabels()
        let bracketHighlights = editor.getBracketHighlights()

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        // Pass 1: Cell backgrounds + selection rects + bracket highlights
        encoder.setRenderPipelineState(colorPipeline)
        encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
        bgQuads.removeAll(keepingCapacity: true)
        bgQuads.reserveCapacity((cells.count + selections.count + bracketHighlights.count) * 6)
        for i in 0..<cells.count {
            let cell = cells[i]
            let bgColor = colorToRGBA(cell.bg)
            if bgColor.a > 0.01 {
                appendQuad(&bgQuads, x: cell.x, y: cell.y, w: cell.w, h: cell.h,
                           r: bgColor.r, g: bgColor.g, b: bgColor.b, a: bgColor.a)
            }
        }
        for i in 0..<selections.count {
            let sel = selections[i]
            let rgba = colorToRGBA(sel.color)
            appendQuad(&bgQuads, x: sel.x, y: sel.y, w: sel.w, h: sel.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
        }
        for i in 0..<bracketHighlights.count {
            let bh = bracketHighlights[i]
            let rgba = colorToRGBA(bh.color)
            appendQuad(&bgQuads, x: bh.x, y: bh.y, w: bh.w, h: bh.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
        }
        if let buffer = Self.uploadVertices(bgQuads, device: device, into: &bgVertexBuffer) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bgQuads.count)
        }

        // Pass 2: Content text
        encoder.setRenderPipelineState(textPipeline)
        encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
        ensureAtlasTexture()
        textQuads.removeAll(keepingCapacity: true)
        textQuads.reserveCapacity(cells.count * 6)
        for i in 0..<cells.count {
            let cell = cells[i]
            let codepoint = cell.glyph_index
            if codepoint <= 32 { continue }

            let uv = ensureGlyph(codepoint: codepoint)
            let fgColor = colorToRGBA(cell.fg)

            let glyphX = cell.x + uv.bearingX
            let glyphY = cell.y + ascender - uv.bearingY

            appendTextQuad(&textQuads,
                           x: glyphX, y: glyphY,
                           w: uv.glyphWidth, h: uv.glyphHeight,
                           uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                           r: fgColor.r, g: fgColor.g, b: fgColor.b, a: fgColor.a)
        }
        if let buffer = Self.uploadVertices(textQuads, device: device, into: &textVertexBuffer),
           let atlasTexture = glyphAtlasTexture
        {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textQuads.count)
        }

        // Pass 3: Gutter backgrounds (drawn ON TOP of content to mask overflow)
        encoder.setRenderPipelineState(colorPipeline)
        encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
        gutterQuads.removeAll(keepingCapacity: true)
        gutterQuads.reserveCapacity(gutterRows.count * 6)
        for i in 0..<gutterRows.count {
            let ln = gutterRows[i]
            let rgba = colorToRGBA(ln.color)
            appendQuad(&gutterQuads, x: ln.x, y: ln.y, w: ln.w, h: ln.h,
                       r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
        }
        if let buffer = Self.uploadVertices(gutterQuads, device: device, into: &gutterVertexBuffer) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gutterQuads.count)
        }

        // Pass 4: Line number text
        drawLineNumbers(encoder: encoder, lineNumbers: lineNumberLabels)

        // Pass 5: Cursors
        if cursorVisible {
            encoder.setRenderPipelineState(colorPipeline)
            encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
            cursorQuads.removeAll(keepingCapacity: true)
            cursorQuads.reserveCapacity(cursors.count * 6)
            for i in 0..<cursors.count {
                let cursor = cursors[i]
                let rgba = colorToRGBA(cursor.color)
                appendQuad(&cursorQuads, x: cursor.x, y: cursor.y, w: cursor.w, h: cursor.h,
                           r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a)
            }
            if let buffer = Self.uploadVertices(cursorQuads, device: device, into: &cursorVertexBuffer) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursorQuads.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Line Numbers

    private func drawLineNumbers(encoder: MTLRenderCommandEncoder, lineNumbers: UnsafeBufferPointer<matcha_render_line_number_s>) {
        encoder.setRenderPipelineState(textPipeline)
        encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
        ensureAtlasTexture()

        lineNumberQuads.removeAll(keepingCapacity: true)
        lineNumberQuads.reserveCapacity(lineNumbers.count * 24)

        for i in 0..<lineNumbers.count {
            let ln = lineNumbers[i]
            let gutterW = ln.w
            let rightPad = cellWidth * 0.5
            let lineNumColor = colorToRGBA(ln.color)

            // Extract digits without String allocation
            var num = Int(ln.line)
            var digitCount = 0
            var digitBuf: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0,0,0,0,0,0,0,0,0,0)
            withUnsafeMutablePointer(to: &digitBuf) { ptr in
                ptr.withMemoryRebound(to: UInt32.self, capacity: 10) { buf in
                    repeat {
                        buf[digitCount] = UInt32(num % 10) + 48
                        digitCount += 1
                        num /= 10
                    } while num > 0
                }
            }

            // Render right-to-left (index 0 = ones place = rightmost)
            withUnsafePointer(to: &digitBuf) { ptr in
                ptr.withMemoryRebound(to: UInt32.self, capacity: 10) { buf in
                    for di in 0..<digitCount {
                        let codepoint = buf[di]
                        let uv = ensureGlyph(codepoint: codepoint)
                        let digitX = ln.x + gutterW - Float(di + 1) * cellWidth - rightPad
                        let digitY = ln.y + ascender - uv.bearingY

                        appendTextQuad(&lineNumberQuads,
                                       x: digitX + uv.bearingX, y: digitY,
                                       w: uv.glyphWidth, h: uv.glyphHeight,
                                       uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                                       r: lineNumColor.r, g: lineNumColor.g, b: lineNumColor.b, a: lineNumColor.a)
                    }
                }
            }
        }

        if let buffer = Self.uploadVertices(lineNumberQuads, device: device, into: &lineNumberVertexBuffer),
           let atlasTexture = glyphAtlasTexture
        {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lineNumberQuads.count)
        }
    }

    private static func uploadVertices(_ vertices: [QuadVertex], device: MTLDevice, into buffer: inout MTLBuffer?) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }

        let requiredLength = max(vertices.count * quadStride, quadStride)
        if buffer == nil || buffer!.length < requiredLength {
            var newLength = max(buffer?.length ?? quadStride * 64, quadStride * 64)
            while newLength < requiredLength {
                newLength *= 2
            }
            buffer = device.makeBuffer(length: newLength, options: .storageModeShared)
        }

        guard let vertexBuffer = buffer else { return nil }
        vertices.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                vertexBuffer.contents().copyMemory(from: baseAddress, byteCount: rawBuffer.count)
            }
        }
        return vertexBuffer
    }

    // MARK: - Glyph Atlas

    private func ensureAtlasTexture() {
        // Create texture once
        if glyphAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: atlasWidth,
                height: atlasHeight,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            glyphAtlasTexture = device.makeTexture(descriptor: desc)
        }

        // Partial upload of only the dirty region
        if atlasDirty, let tex = glyphAtlasTexture {
            let x = atlasDirtyMinX
            let y = atlasDirtyMinY
            let w = atlasDirtyMaxX - x
            let h = atlasDirtyMaxY - y
            if w > 0 && h > 0 {
                let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                       size: MTLSize(width: w, height: h, depth: 1))
                let rowStart = y * atlasWidth + x
                atlasData.withUnsafeBufferPointer { ptr in
                    tex.replace(region: region, mipmapLevel: 0,
                                withBytes: ptr.baseAddress! + rowStart,
                                bytesPerRow: atlasWidth)
                }
            }
            atlasDirtyMinX = Int.max
            atlasDirtyMinY = Int.max
            atlasDirtyMaxX = 0
            atlasDirtyMaxY = 0
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
            let hi = ((codepoint - 0x10000) >> 10) + 0xD800
            let lo = ((codepoint - 0x10000) & 0x3FF) + 0xDC00
            chars[0] = UniChar(hi)
            chars[1] = UniChar(lo)
            count = 2
        }

        CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, count)

        // Font fallback: if primary font doesn't have this glyph, find one that does
        var renderFont: CTFont = ctFont
        if glyphs[0] == 0 {
            if let scalar = Unicode.Scalar(codepoint) {
                let str = String(scalar) as CFString
                let range = CFRange(location: 0, length: CFStringGetLength(str))
                renderFont = CTFontCreateForString(ctFont, str, range)
                CTFontGetGlyphsForCharacters(renderFont, chars, &glyphs, count)
            }
        }

        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(renderFont, .default, glyphs, &boundingRect, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(renderFont, .default, glyphs, &advance, 1)

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
        CTFontDrawGlyphs(renderFont, glyphs, [position], 1, ctx)

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

        // Track dirty region for partial upload
        atlasDirtyMinX = min(atlasDirtyMinX, atlasCursorX)
        atlasDirtyMinY = min(atlasDirtyMinY, atlasCursorY)
        atlasDirtyMaxX = max(atlasDirtyMaxX, atlasCursorX + glyphW)
        atlasDirtyMaxY = max(atlasDirtyMaxY, atlasCursorY + glyphH)

        let uvX = Float(atlasCursorX) / Float(atlasWidth)
        let uvY = Float(atlasCursorY) / Float(atlasHeight)
        let uvW = Float(glyphW) / Float(atlasWidth)
        let uvH = Float(glyphH) / Float(atlasHeight)

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

    // MARK: - Geometry Helpers (point-space coordinates, GPU does NDC conversion)

    private func appendQuad(_ quads: inout [QuadVertex],
                            x: Float, y: Float, w: Float, h: Float,
                            r: Float, g: Float, b: Float, a: Float) {
        let x1 = x + w
        let y1 = y + h
        quads.append(QuadVertex(x: x, y: y, u: 0, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y, u: 1, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x, y: y1, u: 0, v: 1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y, u: 1, v: 0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y1, u: 1, v: 1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x, y: y1, u: 0, v: 1, r: r, g: g, b: b, a: a))
    }

    private func appendTextQuad(_ quads: inout [QuadVertex],
                                x: Float, y: Float, w: Float, h: Float,
                                uvX: Float, uvY: Float, uvW: Float, uvH: Float,
                                r: Float, g: Float, b: Float, a: Float) {
        let x1 = x + w
        let y1 = y + h
        let u0 = uvX
        let v0 = uvY
        let u1 = uvX + uvW
        let v1 = uvY + uvH

        quads.append(QuadVertex(x: x, y: y, u: u0, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y, u: u1, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y, u: u1, v: v0, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x1, y: y1, u: u1, v: v1, r: r, g: g, b: b, a: a))
        quads.append(QuadVertex(x: x, y: y1, u: u0, v: v1, r: r, g: g, b: b, a: a))
    }

    private func colorToRGBA(_ color: UInt32) -> (r: Float, g: Float, b: Float, a: Float) {
        let r = Float((color >> 24) & 0xFF) / 255.0
        let g = Float((color >> 16) & 0xFF) / 255.0
        let b = Float((color >> 8) & 0xFF) / 255.0
        let a = Float(color & 0xFF) / 255.0
        return (r, g, b, a)
    }

    // MARK: - Metal Shaders

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

    struct Viewport {
        float width;
        float height;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texcoord;
        float4 color;
    };

    // Unified vertex shader — converts point-space coords to NDC via viewport uniform
    vertex VertexOut vertex_main(const device QuadVertex* vertices [[buffer(0)]],
                                 constant Viewport& viewport [[buffer(1)]],
                                 uint vid [[vertex_id]]) {
        float x = (vertices[vid].x / viewport.width) * 2.0 - 1.0;
        float y = 1.0 - (vertices[vid].y / viewport.height) * 2.0;
        VertexOut out;
        out.position = float4(x, y, 0.0, 1.0);
        out.texcoord = float2(vertices[vid].u, vertices[vid].v);
        out.color = float4(vertices[vid].r, vertices[vid].g, vertices[vid].b, vertices[vid].a);
        return out;
    }

    fragment float4 fragment_color(VertexOut in [[stage_in]]) {
        return in.color;
    }

    fragment float4 fragment_text(VertexOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float alpha = atlas.sample(s, in.texcoord).r;
        return float4(in.color.rgb, in.color.a * alpha);
    }
    """
}
