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
    let emojiPipeline: MTLRenderPipelineState

    var glyphAtlasTexture: MTLTexture?
    var emojiAtlasTexture: MTLTexture?
    var glyphCache: [UInt32: GlyphUV] = [:]
    var clusterGlyphCache: [String: GlyphUV] = [:]
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
        var isColor: Bool = false
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

    // Grayscale atlas packing state
    var atlasWidth: Int = 2048
    var atlasHeight: Int = 2048
    var atlasData: [UInt8]
    var atlasCursorX: Int = 0
    var atlasCursorY: Int = 0
    var atlasRowHeight: Int = 0
    var atlasDirty = false
    var atlasDirtyMinX: Int = Int.max
    var atlasDirtyMinY: Int = Int.max
    var atlasDirtyMaxX: Int = 0
    var atlasDirtyMaxY: Int = 0

    // Color (emoji) atlas packing state
    var emojiAtlasWidth: Int = 1024
    var emojiAtlasHeight: Int = 1024
    var emojiAtlasData: [UInt8] // RGBA, 4 bytes per pixel
    var emojiCursorX: Int = 0
    var emojiCursorY: Int = 0
    var emojiRowHeight: Int = 0
    var emojiAtlasDirty = false
    var emojiDirtyMinX: Int = Int.max
    var emojiDirtyMinY: Int = Int.max
    var emojiDirtyMaxX: Int = 0
    var emojiDirtyMaxY: Int = 0

    var scaleFactor: Float = 2.0
    let ascender: Float

    private var bgQuads: [QuadVertex] = []
    private var textQuads: [QuadVertex] = []
    private var emojiQuads: [QuadVertex] = []
    private var gutterQuads: [QuadVertex] = []
    private var cursorQuads: [QuadVertex] = []
    private var lineNumberQuads: [QuadVertex] = []

    private var bgVertexBuffer: MTLBuffer?
    private var textVertexBuffer: MTLBuffer?
    private var emojiVertexBuffer: MTLBuffer?
    private var gutterVertexBuffer: MTLBuffer?
    private var cursorVertexBuffer: MTLBuffer?
    private var lineNumberVertexBuffer: MTLBuffer?
    private var ghostQuads: [QuadVertex] = []
    private var ghostVertexBuffer: MTLBuffer?
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
        self.emojiAtlasData = [UInt8](repeating: 0, count: emojiAtlasWidth * emojiAtlasHeight * 4)

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

        let colorDesc = MTLRenderPipelineDescriptor()
        colorDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        colorDesc.fragmentFunction = library.makeFunction(name: "fragment_color")
        colorDesc.colorAttachments[0] = blendDesc.colorAttachments[0]

        let textDesc = MTLRenderPipelineDescriptor()
        textDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        textDesc.fragmentFunction = library.makeFunction(name: "fragment_text")
        textDesc.colorAttachments[0] = blendDesc.colorAttachments[0]

        let emojiDesc = MTLRenderPipelineDescriptor()
        emojiDesc.vertexFunction = library.makeFunction(name: "vertex_main")
        emojiDesc.fragmentFunction = library.makeFunction(name: "fragment_emoji")
        emojiDesc.colorAttachments[0] = blendDesc.colorAttachments[0]

        do {
            self.colorPipeline = try device.makeRenderPipelineState(descriptor: colorDesc)
            self.textPipeline = try device.makeRenderPipelineState(descriptor: textDesc)
            self.emojiPipeline = try device.makeRenderPipelineState(descriptor: emojiDesc)
        } catch {
            return nil
        }

        self.viewportBuffer = device.makeBuffer(length: MemoryLayout<ViewportUniforms>.size, options: .storageModeShared)
    }

    func draw(in view: MTKView, editor: MatchaEditor, cursorVisible: Bool, inlineHint: String? = nil) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let viewWidth = Float(view.drawableSize.width) / scaleFactor
        let viewHeight = Float(view.drawableSize.height) / scaleFactor

        var viewport = ViewportUniforms(width: viewWidth, height: viewHeight)
        viewportBuffer?.contents().copyMemory(from: &viewport, byteCount: MemoryLayout<ViewportUniforms>.size)

        let cells = editor.getCells()
        let cursors = editor.getCursors()
        let selections = editor.getSelections()
        let gutterRows = editor.getGutterRows()
        let lineNumberLabels = editor.getLineNumberLabels()
        let bracketHighlights = editor.getBracketHighlights()
        let clusterData = editor.getClusterData()

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

        // Pass 2: Content text (monochrome glyphs)
        encoder.setRenderPipelineState(textPipeline)
        encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
        ensureAtlasTexture()
        textQuads.removeAll(keepingCapacity: true)
        emojiQuads.removeAll(keepingCapacity: true)
        textQuads.reserveCapacity(cells.count * 6)
        for i in 0..<cells.count {
            let cell = cells[i]
            let codepoint = cell.glyph_index
            if codepoint <= 32 { continue }

            let uv = ensureGlyph(codepoint: codepoint, clusterData: clusterData)
            if uv.glyphWidth <= 0 { continue }

            let glyphX = cell.x + uv.bearingX
            let glyphY = cell.y + ascender - uv.bearingY

            if uv.isColor {
                appendTextQuad(&emojiQuads,
                               x: glyphX, y: glyphY,
                               w: uv.glyphWidth, h: uv.glyphHeight,
                               uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                               r: 1, g: 1, b: 1, a: 1)
            } else {
                let fgColor = colorToRGBA(cell.fg)
                appendTextQuad(&textQuads,
                               x: glyphX, y: glyphY,
                               w: uv.glyphWidth, h: uv.glyphHeight,
                               uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                               r: fgColor.r, g: fgColor.g, b: fgColor.b, a: fgColor.a)
            }
        }
        if let buffer = Self.uploadVertices(textQuads, device: device, into: &textVertexBuffer),
           let atlasTexture = glyphAtlasTexture
        {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textQuads.count)
        }

        // Pass 2b: Color emoji
        if !emojiQuads.isEmpty {
            encoder.setRenderPipelineState(emojiPipeline)
            encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
            ensureEmojiAtlasTexture()
            if let buffer = Self.uploadVertices(emojiQuads, device: device, into: &emojiVertexBuffer),
               let emojiTex = emojiAtlasTexture
            {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(emojiTex, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: emojiQuads.count)
            }
        }

        // Pass 3: Gutter backgrounds
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

        // Pass 6: Inline ghost text prediction
        if let hint = inlineHint, !hint.isEmpty, !cursors.isEmpty {
            encoder.setRenderPipelineState(textPipeline)
            encoder.setVertexBuffer(viewportBuffer, offset: 0, index: 1)
            ensureAtlasTexture()
            ghostQuads.removeAll(keepingCapacity: true)

            let cursor = cursors[0]
            var ghostX = cursor.x + cursor.w + 1 // start after cursor beam
            let ghostY = cursor.y

            for scalar in hint.unicodeScalars {
                let cp = UInt32(scalar.value)
                let uv = ensureGlyph(codepoint: cp)
                if uv.glyphWidth <= 0 { continue }

                let glyphX = ghostX + uv.bearingX
                let glyphY = ghostY + ascender - uv.bearingY

                appendTextQuad(&ghostQuads,
                               x: glyphX, y: glyphY,
                               w: uv.glyphWidth, h: uv.glyphHeight,
                               uvX: uv.uvX, uvY: uv.uvY, uvW: uv.uvW, uvH: uv.uvH,
                               r: 0.5, g: 0.5, b: 0.5, a: 0.4)
                ghostX += cellWidth
            }

            if let buffer = Self.uploadVertices(ghostQuads, device: device, into: &ghostVertexBuffer),
               let atlasTexture = glyphAtlasTexture
            {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentTexture(atlasTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ghostQuads.count)
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

    // MARK: - Glyph Atlas (grayscale)

    private func ensureAtlasTexture() {
        if glyphAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: atlasWidth, height: atlasHeight, mipmapped: false)
            desc.usage = [.shaderRead]
            glyphAtlasTexture = device.makeTexture(descriptor: desc)
        }

        if atlasDirty, let tex = glyphAtlasTexture {
            let x = atlasDirtyMinX, y = atlasDirtyMinY
            let w = atlasDirtyMaxX - x, h = atlasDirtyMaxY - y
            if w > 0 && h > 0 {
                let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                       size: MTLSize(width: w, height: h, depth: 1))
                atlasData.withUnsafeBufferPointer { ptr in
                    tex.replace(region: region, mipmapLevel: 0,
                                withBytes: ptr.baseAddress! + y * atlasWidth + x,
                                bytesPerRow: atlasWidth)
                }
            }
            atlasDirtyMinX = Int.max; atlasDirtyMinY = Int.max
            atlasDirtyMaxX = 0; atlasDirtyMaxY = 0
            atlasDirty = false
        }
    }

    // MARK: - Emoji Atlas (RGBA)

    private func ensureEmojiAtlasTexture() {
        if emojiAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: emojiAtlasWidth, height: emojiAtlasHeight, mipmapped: false)
            desc.usage = [.shaderRead]
            emojiAtlasTexture = device.makeTexture(descriptor: desc)
        }

        if emojiAtlasDirty, let tex = emojiAtlasTexture {
            let x = emojiDirtyMinX, y = emojiDirtyMinY
            let w = emojiDirtyMaxX - x, h = emojiDirtyMaxY - y
            if w > 0 && h > 0 {
                let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                       size: MTLSize(width: w, height: h, depth: 1))
                let bytesPerRow = emojiAtlasWidth * 4
                emojiAtlasData.withUnsafeBufferPointer { ptr in
                    tex.replace(region: region, mipmapLevel: 0,
                                withBytes: ptr.baseAddress! + (y * emojiAtlasWidth + x) * 4,
                                bytesPerRow: bytesPerRow)
                }
            }
            emojiDirtyMinX = Int.max; emojiDirtyMinY = Int.max
            emojiDirtyMaxX = 0; emojiDirtyMaxY = 0
            emojiAtlasDirty = false
        }
    }

    // MARK: - Glyph Rasterization

    private func isColorFont(_ font: CTFont) -> Bool {
        let traits = CTFontGetSymbolicTraits(font)
        return traits.contains(.traitColorGlyphs)
    }

    private static let clusterSentinel: UInt32 = 0x110000

    private func ensureGlyph(codepoint: UInt32, clusterData: UnsafeBufferPointer<UInt8> = .init(start: nil, count: 0)) -> GlyphUV {
        // Skip glyphCache for cluster codepoints — offsets are unstable across frames
        if codepoint < Self.clusterSentinel, let cached = glyphCache[codepoint] {
            return cached
        }

        // Multi-codepoint cluster: extract string from cluster data buffer
        if codepoint >= Self.clusterSentinel {
            let offset = Int(codepoint - Self.clusterSentinel)
            guard offset < clusterData.count else {
                let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                                  bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
                return uv
            }
            // Read null-terminated UTF-8 string
            var len = 0
            while offset + len < clusterData.count && clusterData[offset + len] != 0 { len += 1 }
            let bytes = Array(clusterData[offset..<offset + len])
            let str = String(bytes: bytes, encoding: .utf8) ?? "\u{FFFD}"
            // Cache by string content, not offset (offsets are unstable across frames)
            if let cached = clusterGlyphCache[str] {
                return cached
            }
            let uv = rasterizeClusterGlyph(key: codepoint, string: str)
            clusterGlyphCache[str] = uv
            return uv
        }

        // Single codepoint path
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

        var renderFont: CTFont = ctFont
        if glyphs[0] == 0 {
            if let scalar = Unicode.Scalar(codepoint) {
                let str = String(scalar) as CFString
                let range = CFRange(location: 0, length: CFStringGetLength(str))
                renderFont = CTFontCreateForString(ctFont, str, range)
                CTFontGetGlyphsForCharacters(renderFont, chars, &glyphs, count)
            }
        }

        let useColorAtlas = isColorFont(renderFont)

        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(renderFont, .default, glyphs, &boundingRect, 1)

        let padding: CGFloat = 2
        let glyphW = Int(ceil(boundingRect.width) + padding * 2)
        let glyphH = Int(ceil(boundingRect.height) + padding * 2)

        if glyphW <= 0 || glyphH <= 0 {
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        if useColorAtlas {
            return rasterizeColorGlyph(codepoint: codepoint, renderFont: renderFont, glyphs: glyphs,
                                       boundingRect: boundingRect, glyphW: glyphW, glyphH: glyphH, padding: padding)
        } else {
            return rasterizeMonoGlyph(codepoint: codepoint, renderFont: renderFont, glyphs: glyphs,
                                      boundingRect: boundingRect, glyphW: glyphW, glyphH: glyphH, padding: padding)
        }
    }

    /// Rasterize a multi-codepoint cluster (flags, ZWJ sequences, keycaps) using CTLine.
    private func rasterizeClusterGlyph(key: UInt32, string: String) -> GlyphUV {
        let attrStr = NSAttributedString(string: string, attributes: [.font: ctFont as NSFont])
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let padding: CGFloat = 2
        let glyphW = Int(ceil(bounds.width) + padding * 2)
        let glyphH = Int(ceil(bounds.height) + padding * 2)

        if glyphW <= 0 || glyphH <= 0 {
            return GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                           bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
        }

        // Always use color atlas for clusters (emoji)
        if emojiCursorX + glyphW > emojiAtlasWidth {
            emojiCursorX = 0
            emojiCursorY += emojiRowHeight + 1
            emojiRowHeight = 0
        }
        if emojiCursorY + glyphH > emojiAtlasHeight {
            return GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                           bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: glyphW, height: glyphH,
                                  bitsPerComponent: 8, bytesPerRow: glyphW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                           bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
        }

        ctx.clear(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        ctx.textPosition = CGPoint(x: padding - bounds.origin.x, y: padding - bounds.origin.y)
        CTLineDraw(line, ctx)

        if let data = ctx.data {
            let ptr = data.bindMemory(to: UInt8.self, capacity: glyphW * glyphH * 4)
            for row in 0..<glyphH {
                for col in 0..<glyphW {
                    let srcIdx = (row * glyphW + col) * 4
                    let dstIdx = ((emojiCursorY + row) * emojiAtlasWidth + (emojiCursorX + col)) * 4
                    emojiAtlasData[dstIdx] = ptr[srcIdx]
                    emojiAtlasData[dstIdx + 1] = ptr[srcIdx + 1]
                    emojiAtlasData[dstIdx + 2] = ptr[srcIdx + 2]
                    emojiAtlasData[dstIdx + 3] = ptr[srcIdx + 3]
                }
            }
        }

        emojiDirtyMinX = min(emojiDirtyMinX, emojiCursorX)
        emojiDirtyMinY = min(emojiDirtyMinY, emojiCursorY)
        emojiDirtyMaxX = max(emojiDirtyMaxX, emojiCursorX + glyphW)
        emojiDirtyMaxY = max(emojiDirtyMaxY, emojiCursorY + glyphH)

        let s = scaleFactor
        let uv = GlyphUV(
            uvX: Float(emojiCursorX) / Float(emojiAtlasWidth),
            uvY: Float(emojiCursorY) / Float(emojiAtlasHeight),
            uvW: Float(glyphW) / Float(emojiAtlasWidth),
            uvH: Float(glyphH) / Float(emojiAtlasHeight),
            bearingX: Float(bounds.origin.x - padding) / s,
            bearingY: Float(bounds.origin.y + bounds.height + padding) / s,
            glyphWidth: Float(glyphW) / s,
            glyphHeight: Float(glyphH) / s,
            isColor: true
        )

        emojiCursorX += glyphW + 1
        emojiRowHeight = max(emojiRowHeight, glyphH)
        emojiAtlasDirty = true
        return uv
    }

    private func rasterizeMonoGlyph(codepoint: UInt32, renderFont: CTFont, glyphs: [CGGlyph],
                                     boundingRect: CGRect, glyphW: Int, glyphH: Int, padding: CGFloat) -> GlyphUV {
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
        let position = CGPoint(x: padding - boundingRect.origin.x, y: padding - boundingRect.origin.y)
        ctx.setFillColor(gray: 1, alpha: 1)
        CTFontDrawGlyphs(renderFont, glyphs, [position], 1, ctx)

        if let data = ctx.data {
            let ptr = data.bindMemory(to: UInt8.self, capacity: glyphW * glyphH)
            for row in 0..<glyphH {
                for col in 0..<glyphW {
                    atlasData[(atlasCursorY + row) * atlasWidth + (atlasCursorX + col)] = ptr[row * glyphW + col]
                }
            }
        }

        atlasDirtyMinX = min(atlasDirtyMinX, atlasCursorX)
        atlasDirtyMinY = min(atlasDirtyMinY, atlasCursorY)
        atlasDirtyMaxX = max(atlasDirtyMaxX, atlasCursorX + glyphW)
        atlasDirtyMaxY = max(atlasDirtyMaxY, atlasCursorY + glyphH)

        let s = scaleFactor
        let uv = GlyphUV(
            uvX: Float(atlasCursorX) / Float(atlasWidth),
            uvY: Float(atlasCursorY) / Float(atlasHeight),
            uvW: Float(glyphW) / Float(atlasWidth),
            uvH: Float(glyphH) / Float(atlasHeight),
            bearingX: Float(boundingRect.origin.x - padding) / s,
            bearingY: Float(boundingRect.origin.y + boundingRect.height + padding) / s,
            glyphWidth: Float(glyphW) / s,
            glyphHeight: Float(glyphH) / s,
            isColor: false
        )

        glyphCache[codepoint] = uv
        atlasCursorX += glyphW + 1
        atlasRowHeight = max(atlasRowHeight, glyphH)
        atlasDirty = true
        return uv
    }

    private func rasterizeColorGlyph(codepoint: UInt32, renderFont: CTFont, glyphs: [CGGlyph],
                                      boundingRect: CGRect, glyphW: Int, glyphH: Int, padding: CGFloat) -> GlyphUV {
        if emojiCursorX + glyphW > emojiAtlasWidth {
            emojiCursorX = 0
            emojiCursorY += emojiRowHeight + 1
            emojiRowHeight = 0
        }
        if emojiCursorY + glyphH > emojiAtlasHeight {
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: glyphW, height: glyphH,
                                  bitsPerComponent: 8, bytesPerRow: glyphW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            let uv = GlyphUV(uvX: 0, uvY: 0, uvW: 0, uvH: 0,
                              bearingX: 0, bearingY: 0, glyphWidth: 0, glyphHeight: 0)
            glyphCache[codepoint] = uv
            return uv
        }

        ctx.clear(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        let position = CGPoint(x: padding - boundingRect.origin.x, y: padding - boundingRect.origin.y)
        CTFontDrawGlyphs(renderFont, glyphs, [position], 1, ctx)

        if let data = ctx.data {
            let ptr = data.bindMemory(to: UInt8.self, capacity: glyphW * glyphH * 4)
            for row in 0..<glyphH {
                for col in 0..<glyphW {
                    let srcIdx = (row * glyphW + col) * 4
                    let dstIdx = ((emojiCursorY + row) * emojiAtlasWidth + (emojiCursorX + col)) * 4
                    emojiAtlasData[dstIdx] = ptr[srcIdx]         // B
                    emojiAtlasData[dstIdx + 1] = ptr[srcIdx + 1] // G
                    emojiAtlasData[dstIdx + 2] = ptr[srcIdx + 2] // R
                    emojiAtlasData[dstIdx + 3] = ptr[srcIdx + 3] // A
                }
            }
        }

        emojiDirtyMinX = min(emojiDirtyMinX, emojiCursorX)
        emojiDirtyMinY = min(emojiDirtyMinY, emojiCursorY)
        emojiDirtyMaxX = max(emojiDirtyMaxX, emojiCursorX + glyphW)
        emojiDirtyMaxY = max(emojiDirtyMaxY, emojiCursorY + glyphH)

        let s = scaleFactor
        let uv = GlyphUV(
            uvX: Float(emojiCursorX) / Float(emojiAtlasWidth),
            uvY: Float(emojiCursorY) / Float(emojiAtlasHeight),
            uvW: Float(glyphW) / Float(emojiAtlasWidth),
            uvH: Float(glyphH) / Float(emojiAtlasHeight),
            bearingX: Float(boundingRect.origin.x - padding) / s,
            bearingY: Float(boundingRect.origin.y + boundingRect.height + padding) / s,
            glyphWidth: Float(glyphW) / s,
            glyphHeight: Float(glyphH) / s,
            isColor: true
        )

        glyphCache[codepoint] = uv
        emojiCursorX += glyphW + 1
        emojiRowHeight = max(emojiRowHeight, glyphH)
        emojiAtlasDirty = true
        return uv
    }

    // MARK: - Geometry Helpers

    private func appendQuad(_ quads: inout [QuadVertex],
                            x: Float, y: Float, w: Float, h: Float,
                            r: Float, g: Float, b: Float, a: Float) {
        let x1 = x + w, y1 = y + h
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
        let x1 = x + w, y1 = y + h
        let u0 = uvX, v0 = uvY, u1 = uvX + uvW, v1 = uvY + uvH
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
        float x; float y; float u; float v;
        float r; float g; float b; float a;
    };

    struct Viewport { float width; float height; };

    struct VertexOut {
        float4 position [[position]];
        float2 texcoord;
        float4 color;
    };

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

    fragment float4 fragment_emoji(VertexOut in [[stage_in]],
                                    texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        return atlas.sample(s, in.texcoord);
    }
    """
}
