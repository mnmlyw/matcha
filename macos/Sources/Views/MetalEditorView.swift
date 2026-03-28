import AppKit
import MetalKit
import MatchaKit

class MetalEditorView: MTKView, MTKViewDelegate, NSTextInputClient {
    private(set) var editor: MatchaEditor
    var renderer: MetalRenderer?
    var cursorBlinkTimer: Timer?
    var cursorVisible = true
    var trackingArea: NSTrackingArea?
    var keyWindowObserver: NSObjectProtocol?

    // Font metrics (in points)
    var cellWidth: CGFloat = 8.4
    var cellHeight: CGFloat = 18.0
    var wideCellWidth: CGFloat = 14.0
    var hangulCellWidth: CGFloat = 14.0
    var font: NSFont
    private var inputHandled = false
    // Word completion state
    var completionWords: [String] = []
    var completionPrefixLen: Int = 0
    var completionSelectedIndex: Int = 0
    var showCompletion: Bool = false
    // Inline ghost text prediction
    var inlineHint: String? = nil
    var inlineHintPrefixLen: Int = 0
    private var markedByteRange: Range<UInt32>?
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)

    init(editor: MatchaEditor) {
        self.editor = editor

        // Set up font
        let fontSize = CGFloat(matcha_config_get_float(editor.config.handle, "font-size"))
        let size = fontSize > 0 ? fontSize : 14.0

        if let cfFamily = matcha_config_get_string(editor.config.handle, "font-family") {
            let family = String(cString: cfFamily)
            matcha_free_string(UnsafeMutablePointer(mutating: cfFamily))
            self.font = NSFont(name: family, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            self.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())

        self.delegate = self
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        let bgColor = matcha_config_get_color(editor.config.handle, "bg-color")
        self.clearColor = MTLClearColor(
            red: Double((bgColor >> 24) & 0xFF) / 255.0,
            green: Double((bgColor >> 16) & 0xFF) / 255.0,
            blue: Double((bgColor >> 8) & 0xFF) / 255.0,
            alpha: 1.0)

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

        // Prevent stretching/blurring during live resize
        self.layerContentsPlacement = .topLeft
        self.layer?.isOpaque = true

        // Register for file drag & drop
        registerForDraggedTypes([.fileURL])

        self.becomeFirstResponder()
        startCursorBlink()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        inlineHintWorkItem?.cancel()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func swapEditor(_ newEditor: MatchaEditor) {
        editor = newEditor
        editor.markActive()
        updateViewport()
        inlineHint = nil
        inlineHintWorkItem?.cancel()
        dismissCompletion()
        clearMarkedTextState()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }

        if let window {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.editor.markActive()
                self?.requestRedraw()
            }
            // Match window background to editor bg color
            window.backgroundColor = NSColor(
                red: CGFloat(clearColor.red),
                green: CGFloat(clearColor.green),
                blue: CGFloat(clearColor.blue),
                alpha: 1.0)
            window.makeFirstResponder(self)
            editor.markActive()
            // Update renderer if screen scale factor differs (multi-display)
            if let screen = window.screen, let r = renderer {
                let newScale = Float(screen.backingScaleFactor)
                if newScale != r.scaleFactor, let device = self.device {
                    let scaledFont = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * CGFloat(newScale))!
                    renderer = MetalRenderer(device: device, view: self, font: scaledFont,
                                             cellWidth: Float(cellWidth), cellHeight: Float(cellHeight),
                                             scaleFactor: newScale)
                }
            }
            updateViewport()
            requestRedraw()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
        // Force immediate redraw during resize to avoid stale frame stretching
        if inLiveResize {
            self.draw()
        } else {
            requestRedraw()
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        requestRedraw()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        requestRedraw()
    }

    private func calculateCellDimensions() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attrs)
        cellWidth = ceil(size.width)
        cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
        wideCellWidth = max(
            cellWidth,
            measureWideCellWidth(samples: ["漢", "あ", "ア", "（", "Ａ"])
        )
        hangulCellWidth = max(cellWidth, measureWideCellWidth(samples: ["한", "가", "힣"]))
    }

    private func measureWideCellWidth(samples: [String]) -> CGFloat {
        let baseFont = font as CTFont
        var widestAdvance = cellWidth

        for sample in samples {
            guard let scalar = sample.unicodeScalars.first else { continue }

            var chars: [UniChar] = []
            let value = scalar.value
            if value <= 0xFFFF {
                chars = [UniChar(value)]
            } else {
                let hi = ((value - 0x10000) >> 10) + 0xD800
                let lo = ((value - 0x10000) & 0x3FF) + 0xDC00
                chars = [UniChar(hi), UniChar(lo)]
            }

            var glyphs = Array(repeating: CGGlyph(), count: chars.count)
            CTFontGetGlyphsForCharacters(baseFont, chars, &glyphs, chars.count)

            var renderFont = baseFont
            if glyphs[0] == 0 {
                let string = sample as CFString
                renderFont = CTFontCreateForString(baseFont, string, CFRange(location: 0, length: CFStringGetLength(string)))
                CTFontGetGlyphsForCharacters(renderFont, chars, &glyphs, chars.count)
            }

            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(renderFont, .default, glyphs, &advance, 1)
            widestAdvance = max(widestAdvance, advance.width)
        }

        return widestAdvance
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
        editor.setWideCellWidth(Float(wideCellWidth))
        editor.setHangulCellWidth(Float(hangulCellWidth))
    }

    private func requestRedraw() {
        needsDisplay = true
    }

    private func clearMarkedTextState() {
        markedByteRange = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    private func plainString(from value: Any) -> String {
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        if let string = value as? String {
            return string
        }
        return "\(value)"
    }

    private func clampUTF16Range(_ range: NSRange, maxLength: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let start = max(0, min(range.location, maxLength))
        let end = max(start, min(range.location + range.length, maxLength))
        return NSRange(location: start, length: end - start)
    }

    private func utf16RangeToByteRange(_ range: NSRange, in content: String) -> Range<UInt32>? {
        let clamped = clampUTF16Range(range, maxLength: content.utf16.count)
        guard clamped.location != NSNotFound else { return nil }
        let startIndex = String.Index(utf16Offset: clamped.location, in: content)
        let endIndex = String.Index(utf16Offset: clamped.location + clamped.length, in: content)
        let byteStart = UInt32(content[..<startIndex].utf8.count)
        let byteEnd = byteStart + UInt32(content[startIndex..<endIndex].utf8.count)
        return byteStart..<byteEnd
    }

    private func byteOffsetToUTF16(_ offset: UInt32, in content: String) -> Int {
        let clamped = min(Int(offset), content.utf8.count)
        return String(decoding: content.utf8.prefix(clamped), as: UTF8.self).utf16.count
    }

    private func currentSelectionByteRange() -> Range<UInt32> {
        if let selection = editor.getSelectionOffsets() {
            return selection
        }
        let cursor = editor.getCursorOffset()
        return cursor..<cursor
    }

    private func replacementByteRange(for replacementRange: NSRange, in content: String) -> Range<UInt32> {
        if let explicitRange = utf16RangeToByteRange(replacementRange, in: content) {
            return explicitRange
        }
        if let marked = markedByteRange {
            return marked
        }
        return currentSelectionByteRange()
    }

    private func applyMarkedSelection(text: String, startOffset: UInt32, selectedRange: NSRange) {
        guard !text.isEmpty else {
            editor.setCursorOffset(startOffset)
            return
        }

        let clamped = clampUTF16Range(selectedRange, maxLength: text.utf16.count)
        guard let relativeRange = utf16RangeToByteRange(clamped, in: text) else {
            editor.setCursorOffset(startOffset)
            return
        }

        let start = startOffset + relativeRange.lowerBound
        let end = startOffset + relativeRange.upperBound
        if clamped.length > 0 {
            editor.setSelectionOffsets(start: start, end: end)
        } else {
            editor.setCursorOffset(start)
        }
    }

    private func screenRect(forEditorRect rect: CGRect) -> NSRect {
        let localRect = NSRect(
            x: rect.origin.x,
            y: bounds.height - rect.origin.y - rect.height,
            width: max(rect.width, 1),
            height: max(rect.height, 1)
        )
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    private func handleTextCommand(named selectorName: String) -> Bool {
        switch selectorName {
        case "insertNewline:":
            editor.newline()
        case "insertTab:":
            editor.insertTab()
        case "insertBacktab:":
            editor.dedent()
        case "deleteBackward:":
            editor.deleteBackward()
        case "deleteForward:":
            editor.deleteForward()
        case "deleteWordBackward:":
            editor.deleteWordBackward()
        case "deleteWordForward:":
            editor.deleteWordForward()
        case "moveLeft:":
            editor.moveLeft()
        case "moveRight:":
            editor.moveRight()
        case "moveUp:":
            editor.moveUp()
        case "moveDown:":
            editor.moveDown()
        case "moveWordLeft:":
            editor.moveWordLeft()
        case "moveWordRight:":
            editor.moveWordRight()
        case "moveToBeginningOfLine:":
            editor.moveLineStart()
        case "moveToEndOfLine:":
            editor.moveLineEnd()
        case "moveToBeginningOfDocument:":
            editor.moveStart()
        case "moveToEndOfDocument:":
            editor.moveEnd()
        case "moveLeftAndModifySelection:":
            editor.selectLeft()
        case "moveRightAndModifySelection:":
            editor.selectRight()
        case "moveUpAndModifySelection:":
            editor.selectUp()
        case "moveDownAndModifySelection:":
            editor.selectDown()
        case "moveWordLeftAndModifySelection:":
            editor.selectWordLeft()
        case "moveWordRightAndModifySelection:":
            editor.selectWordRight()
        case "moveToBeginningOfLineAndModifySelection:":
            editor.selectLineStart()
        case "moveToEndOfLineAndModifySelection:":
            editor.selectLineEnd()
        case "moveToBeginningOfDocumentAndModifySelection:":
            editor.selectStart()
        case "moveToEndOfDocumentAndModifySelection:":
            editor.selectEnd()
        default:
            return false
        }
        requestRedraw()
        return true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateViewport()
        requestRedraw()
    }

    func draw(in view: MTKView) {
        editor.prepareRender()
        renderer?.draw(in: view, editor: editor, cursorVisible: cursorVisible, inlineHint: inlineHint)
    }

    // MARK: - Cursor Blink

    private func startCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            self?.cursorVisible.toggle()
            self?.requestRedraw()
        }
    }

    private func resetCursorBlink() {
        cursorVisible = true
        startCursorBlink()
        requestRedraw()
    }

    // MARK: - Keyboard Input

    private func dismissCompletion() {
        if showCompletion {
            showCompletion = false
            NotificationCenter.default.post(name: .matchaDismissCompletion, object: nil)
        }
    }

    private func triggerCompletion() {
        guard let result = editor.getCompletions() else { return }
        completionWords = result.words
        completionPrefixLen = result.prefixLen
        completionSelectedIndex = 0
        showCompletion = true

        // Get cursor rect for positioning
        let offset = editor.getCursorOffset()
        let rect = editor.rectForOffset(offset) ?? .zero
        NotificationCenter.default.post(name: .matchaShowCompletion, object: nil,
                                        userInfo: ["words": completionWords,
                                                   "prefixLen": completionPrefixLen,
                                                   "x": rect.origin.x,
                                                   "y": rect.origin.y + rect.height])
    }

    private var inlineHintWorkItem: DispatchWorkItem?

    private func refreshInlineHint() {
        inlineHintWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let result = self.editor.getCompletions(), !result.words.isEmpty {
                let best = result.words[0]
                let suffix = String(best.dropFirst(result.prefixLen))
                self.inlineHint = suffix.isEmpty ? nil : suffix
                self.inlineHintPrefixLen = result.prefixLen
            } else {
                self.inlineHint = nil
            }
            self.requestRedraw()
        }
        inlineHintWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }

    private func requeryCompletionIfShowing() {
        guard showCompletion else { return }
        if let result = editor.getCompletions(), !result.words.isEmpty {
            completionWords = result.words
            completionPrefixLen = result.prefixLen
            completionSelectedIndex = 0
            let offset = editor.getCursorOffset()
            let rect = editor.rectForOffset(offset) ?? .zero
            NotificationCenter.default.post(name: .matchaShowCompletion, object: nil,
                                            userInfo: ["words": completionWords,
                                                       "prefixLen": completionPrefixLen,
                                                       "x": rect.origin.x,
                                                       "y": rect.origin.y + rect.height])
        } else {
            dismissCompletion()
        }
    }

    private func acceptInlineHint() {
        guard let hint = inlineHint else { return }
        editor.insert(text: hint)
        inlineHint = nil
        requestRedraw()
    }

    private func acceptCompletion() {
        guard showCompletion, completionSelectedIndex < completionWords.count else { return }
        let word = completionWords[completionSelectedIndex]
        let cursorOffset = editor.getCursorOffset()
        guard completionPrefixLen <= Int(cursorOffset) else { dismissCompletion(); return }
        let prefixStart = cursorOffset - UInt32(completionPrefixLen)
        editor.replaceRange(start: prefixStart, end: cursorOffset, text: word)
        dismissCompletion()
        requestRedraw()
    }

    override func keyDown(with event: NSEvent) {
        editor.markActive()
        resetCursorBlink()

        // Handle completion popup keys
        if showCompletion {
            switch Int(event.keyCode) {
            case 125: // Down
                completionSelectedIndex = (completionSelectedIndex + 1) % min(completionWords.count, 10)
                NotificationCenter.default.post(name: .matchaCompletionNavigate, object: nil,
                                                userInfo: ["index": completionSelectedIndex])
                return
            case 126: // Up
                completionSelectedIndex = (completionSelectedIndex - 1 + min(completionWords.count, 10)) % min(completionWords.count, 10)
                NotificationCenter.default.post(name: .matchaCompletionNavigate, object: nil,
                                                userInfo: ["index": completionSelectedIndex])
                return
            case 48: // Tab — accept completion
                acceptCompletion()
                return
            case 53: // Escape
                dismissCompletion()
                return
            case 36: // Enter — dismiss and insert newline
                dismissCompletion()
                // Fall through to normal handling
            case 51: // Backspace — let it process, then re-query
                break // fall through, re-query below
            default:
                // For word characters, fall through to insert then re-query
                // For non-word characters (space, punctuation), dismiss
                if let chars = event.characters, let ch = chars.unicodeScalars.first {
                    if !CharacterSet.alphanumerics.contains(ch) && ch != "_" {
                        dismissCompletion()
                    }
                } else {
                    dismissCompletion()
                }
            }
        }

        let modifiers = event.modifierFlags

        let hasCmd = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        if hasCmd {
            switch event.charactersIgnoringModifiers {
            case "z":
                if hasShift { editor.redo() } else { editor.undo() }
                return
            case "a":
                editor.selectAll()
                return
            case "c": copySelection(); return
            case "x": cutSelection(); return
            case "v": pasteFromClipboard(); return
            case "f":
                NotificationCenter.default.post(name: .matchaToggleFind, object: editor)
                return
            case "g":
                if hasShift {
                    NotificationCenter.default.post(name: .matchaFindPrev, object: editor)
                } else {
                    NotificationCenter.default.post(name: .matchaFindNext, object: editor)
                }
                return
            case "/":
                editor.toggleComment()
                return
            case "d":
                editor.duplicateLine()
                return
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let n = event.charactersIgnoringModifiers.flatMap({ Int($0) }) {
                    NotificationCenter.default.post(name: .matchaSwitchToTab, object: nil,
                                                    userInfo: ["index": n - 1])
                }
                return
            default: break
            }
        }

        // Tab: accept inline hint if showing (before normal tab handling)
        if event.keyCode == 48 && !modifiers.contains(.command) && !showCompletion && inlineHint != nil {
            acceptInlineHint()
            return
        }

        // Escape: trigger word completion (when no modifiers)
        if event.keyCode == 53 && !modifiers.contains(.command) {
            triggerCompletion()
            return
        }

        inputHandled = false
        interpretKeyEvents([event])
        if inputHandled {
            requeryCompletionIfShowing()
            return
        }

        if KeyEventHandler.dispatch(event: event, editor: editor) {
            editor.updateInfo()
            requestRedraw()
            requeryCompletionIfShowing()
            return
        }

    }

    override func doCommand(by selector: Selector) {
        let handled = handleTextCommand(named: NSStringFromSelector(selector))
        inputHandled = handled
        if handled {
            let name = NSStringFromSelector(selector)
            if name.contains("delete") || name.contains("Backward") || name.contains("Forward") {
                refreshInlineHint()
            } else {
                inlineHint = nil
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Text Input Client

    func insertText(_ string: Any, replacementRange: NSRange) {
        let plain = plainString(from: string)
        let existingMarkedRange = markedByteRange
        let content = editor.getContent() ?? ""

        if let marked = existingMarkedRange {
            editor.replaceRange(start: marked.lowerBound, end: marked.upperBound, text: plain)
            editor.setCursorOffset(marked.lowerBound + UInt32(plain.utf8.count))
        } else if let explicitRange = utf16RangeToByteRange(replacementRange, in: content) {
            editor.replaceRange(start: explicitRange.lowerBound, end: explicitRange.upperBound, text: plain)
            editor.setCursorOffset(explicitRange.lowerBound + UInt32(plain.utf8.count))
        } else {
            editor.insert(text: plain)
        }

        clearMarkedTextState()
        inputHandled = true
        refreshInlineHint()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let plain = plainString(from: string)
        let content = editor.getContent() ?? ""
        let replacedRange = replacementByteRange(for: replacementRange, in: content)

        editor.replaceRange(start: replacedRange.lowerBound, end: replacedRange.upperBound, text: plain)

        let startOffset = replacedRange.lowerBound
        let endOffset = startOffset + UInt32(plain.utf8.count)
        if plain.isEmpty {
            clearMarkedTextState()
            editor.setCursorOffset(startOffset)
        } else {
            markedByteRange = startOffset..<endOffset
            markedSelectedRange = clampUTF16Range(selectedRange, maxLength: plain.utf16.count)
            applyMarkedSelection(text: plain, startOffset: startOffset, selectedRange: markedSelectedRange)
        }

        inputHandled = true
        inlineHint = nil // clear stale hint during IME composition
        requestRedraw()
    }

    func unmarkText() {
        clearMarkedTextState()
        inputHandled = true
        requestRedraw()
    }

    func selectedRange() -> NSRange {
        guard let content = editor.getContent() else {
            return NSRange(location: NSNotFound, length: 0)
        }

        if let selection = editor.getSelectionOffsets() {
            let start = byteOffsetToUTF16(selection.lowerBound, in: content)
            let end = byteOffsetToUTF16(selection.upperBound, in: content)
            return NSRange(location: start, length: end - start)
        }

        let cursor = editor.getCursorOffset()
        let location = byteOffsetToUTF16(cursor, in: content)
        return NSRange(location: location, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked = markedByteRange, let content = editor.getContent() else {
            return NSRange(location: NSNotFound, length: 0)
        }

        let start = byteOffsetToUTF16(marked.lowerBound, in: content)
        let end = byteOffsetToUTF16(marked.upperBound, in: content)
        return NSRange(location: start, length: end - start)
    }

    func hasMarkedText() -> Bool {
        markedByteRange != nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let content = editor.getContent() else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }

        let nsContent = content as NSString
        let clamped = clampUTF16Range(range, maxLength: nsContent.length)
        guard clamped.location != NSNotFound else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }

        actualRange?.pointee = clamped
        return NSAttributedString(string: nsContent.substring(with: clamped))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let content = editor.getContent() else { return 0 }

        let localPoint: NSPoint
        if let window {
            let windowPoint = window.convertPoint(fromScreen: point)
            localPoint = convert(windowPoint, from: nil)
        } else {
            localPoint = point
        }

        let offset = editor.hitTestOffset(x: Float(localPoint.x), y: Float(bounds.height - localPoint.y))
        return byteOffsetToUTF16(offset, in: content)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let content = editor.getContent() ?? ""
        let clamped = clampUTF16Range(range, maxLength: content.utf16.count)
        let offset = utf16RangeToByteRange(NSRange(location: clamped.location, length: 0), in: content)?.lowerBound
            ?? editor.getCursorOffset()
        actualRange?.pointee = NSRange(location: clamped.location == NSNotFound ? 0 : clamped.location, length: 0)

        guard let rect = editor.rectForOffset(offset) else {
            return .zero
        }
        return screenRect(forEditorRect: rect)
    }

    // MARK: - Mouse Input (in points — Zig core works in points)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        editor.markActive()
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
        requestRedraw()
    }

    // MARK: - Clipboard

    @discardableResult
    private func copySelection() -> Bool {
        guard let text = editor.getSelectionText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    private func cutSelection() {
        guard copySelection() else { return }
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

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        // Route through ContentView's open-file flow (respects unsaved tabs)
        NotificationCenter.default.post(name: .matchaOpenFilePath, object: nil,
                                        userInfo: ["path": url.path])
        return true
    }
}
