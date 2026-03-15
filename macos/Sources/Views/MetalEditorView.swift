import AppKit
import MetalKit
import MatchaKit

class MetalEditorView: MTKView, MTKViewDelegate {
    let editor: MatchaEditor
    var renderer: MetalRenderer?
    var cursorBlinkTimer: Timer?
    var cursorVisible = true
    var trackingArea: NSTrackingArea?

    // Font metrics (in points)
    var cellWidth: CGFloat = 8.4
    var cellHeight: CGFloat = 18.0
    var font: NSFont

    init(editor: MatchaEditor) {
        self.editor = editor

        // Set up font
        let fontSize = CGFloat(matcha_config_get_float(editor.handle, "font-size"))
        let size = fontSize > 0 ? fontSize : 14.0

        if let cfFamily = matcha_config_get_string(editor.handle, "font-family") {
            let family = String(cString: cfFamily)
            matcha_editor_free_string(UnsafeMutablePointer(mutating: cfFamily))
            self.font = NSFont(name: family, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            self.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        self.delegate = self
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60
        self.clearColor = MTLClearColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 1.0)

        // Calculate cell dimensions from font (in points)
        calculateCellDimensions()

        // Set up renderer — rasterize glyphs at Retina resolution for crispness
        if let device = self.device {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let scaledFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale)!
            renderer = MetalRenderer(device: device, view: self, font: scaledFont,
                                     cellWidth: Float(cellWidth), cellHeight: Float(cellHeight),
                                     scaleFactor: Float(scale))
        }

        self.becomeFirstResponder()
        startCursorBlink()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
    }

    private func calculateCellDimensions() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attrs)
        cellWidth = ceil(size.width)
        cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
    }

    /// Tell the Zig core about the viewport in **points** (not pixels).
    private func updateViewport() {
        let width = UInt32(bounds.width)
        let height = UInt32(bounds.height)
        editor.setViewport(
            width: width,
            height: height,
            cellWidth: Float(cellWidth),
            cellHeight: Float(cellHeight)
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateViewport()
    }

    func draw(in view: MTKView) {
        editor.prepareRender()
        renderer?.draw(in: view, editor: editor, cursorVisible: cursorVisible)
    }

    // MARK: - Cursor Blink

    private func startCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            self?.cursorVisible.toggle()
        }
    }

    private func resetCursorBlink() {
        cursorVisible = true
        startCursorBlink()
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        resetCursorBlink()
        let modifiers = event.modifierFlags

        let hasCmd = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)
        let hasAlt = modifiers.contains(.option)

        if hasCmd {
            switch event.charactersIgnoringModifiers {
            case "z":
                if hasShift { editor.redo() } else { editor.undo() }
                return
            case "a": editor.selectAll(); return
            case "c": copySelection(); return
            case "x": cutSelection(); return
            case "v": pasteFromClipboard(); return
            case "f":
                NotificationCenter.default.post(name: .matchaToggleFind, object: nil)
                return
            case "g":
                if hasShift {
                    NotificationCenter.default.post(name: .matchaFindPrev, object: nil)
                } else {
                    NotificationCenter.default.post(name: .matchaFindNext, object: nil)
                }
                return
            default: break
            }
        }

        switch Int(event.keyCode) {
        case 123: // Left
            if hasCmd { hasShift ? editor.selectLineStart() : editor.moveLineStart() }
            else if hasAlt { hasShift ? editor.selectWordLeft() : editor.moveWordLeft() }
            else { hasShift ? editor.selectLeft() : editor.moveLeft() }
            return
        case 124: // Right
            if hasCmd { hasShift ? editor.selectLineEnd() : editor.moveLineEnd() }
            else if hasAlt { hasShift ? editor.selectWordRight() : editor.moveWordRight() }
            else { hasShift ? editor.selectRight() : editor.moveRight() }
            return
        case 125: // Down
            if hasCmd { hasShift ? editor.selectLineEnd() : editor.moveEnd() }
            else { hasShift ? editor.selectDown() : editor.moveDown() }
            return
        case 126: // Up
            if hasCmd { hasShift ? editor.selectLineStart() : editor.moveStart() }
            else { hasShift ? editor.selectUp() : editor.moveUp() }
            return
        case 51: editor.deleteBackward(); return
        case 117: editor.deleteForward(); return
        case 36: editor.newline(); return
        case 48: editor.insert(text: "    "); return
        case 116: editor.movePageUp(); return
        case 121: editor.movePageDown(); return
        case 115: editor.moveStart(); return
        case 119: editor.moveEnd(); return
        default: break
        }

        if let chars = event.characters, !chars.isEmpty, !hasCmd {
            editor.insert(text: chars)
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Mouse Input (in points — Zig core works in points)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        let x = Float(loc.x)
        let y = Float(bounds.height - loc.y)

        switch event.clickCount {
        case 2:
            editor.doubleClick(x: x, y: y)
        case 3:
            editor.tripleClick(x: x, y: y)
        default:
            let extend = event.modifierFlags.contains(.shift)
            editor.click(x: x, y: y, extend: extend)
        }
        resetCursorBlink()
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        editor.click(x: Float(loc.x), y: Float(bounds.height - loc.y), extend: true)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = Float(-event.scrollingDeltaX)
        let dy = Float(-event.scrollingDeltaY)
        editor.scroll(dx: dx, dy: dy)
    }

    // MARK: - Clipboard

    private func copySelection() {
        guard let text = editor.getSelectionText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func cutSelection() {
        copySelection()
        editor.deleteBackward()
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        editor.paste(text: text)
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}
