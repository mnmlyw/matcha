# Why Matcha

A look at Matcha's architecture, using CotEditor — the well-known open-source macOS text editor built on AppKit — as a reference point.

## Rendering
Matcha draws through a custom **Metal renderer** with two glyph atlases: grayscale (`r8Unorm`) for monochrome text and `bgra8Unorm` for color emoji. Only visible cells are submitted to the GPU. Single-codepoint glyphs go straight through the atlas; multi-codepoint grapheme clusters fall back to CoreText (`CTLineCreateWithAttributedString`) once per unique cluster and are cached by cluster string. There is no AppKit text layout anywhere — no `NSTextStorage`, no text containers, no line fragment rects, no attribute runs.

CotEditor, by contrast, renders through `NSTextView` and runs the full AppKit text layout pipeline on every edit. That pipeline is built for general rich text; Matcha skips it entirely.

## Text Storage
Matcha stores text in a **piece table** with a cached `line_count`, `total_length`, and a line-offset index (`line_starts`). `lineStart()` and `lineEnd()` are O(1) lookups; `posToLineCol()` is O(log N) via binary search. All caches are invalidated in one place (`refreshCaches`) after every insert or delete, so the fast paths stay fast without per-edit copying.

CotEditor uses `NSTextStorage`, an attributed string that re-applies attributes and reallocates on mutation.

## Syntax Highlighting
Matcha highlights with a custom Zig lexer driven by a line-by-line state machine. Tokens are cached per line, and lexer state is snapshotted every 64 lines so incremental rehighlighting only re-runs from the nearest snapshot. Tokens map directly to cell colors in the render pass — no attributed-string intermediate, no layout invalidation.

CotEditor evaluates regex patterns via `NSRegularExpression` across the visible range and applies results as `NSAttributedString` attributes, which re-triggers layout.

## Unicode & Cursor Model
Matcha's cursor columns are **byte offsets**, not codepoint counts. `charWidth` returns 2 for CJK, fullwidth, and emoji codepoints; `nextClusterLen` detects combining marks, regional indicators, ZWJ sequences, variation selectors, and skin modifiers. The wrap, click, cursor, and render paths all iterate by grapheme cluster using the same logic, kept coherent by a wrap cache keyed on `edit_counter` and `wrap_width`.

## Architecture at a Glance

| | Matcha | CotEditor |
|---|---|---|
| Text engine | Custom Metal cell grid | NSTextView (general purpose) |
| Storage | Piece table + cached line index | NSTextStorage |
| Highlighting | Zig lexer → direct cell colors | NSRegularExpression → NSAttributedString |
| Rendering | GPU vertex buffers, viewport culling | CoreText layout + compositing |
| Core language | Zig behind a C ABI | Swift + ARC |
| Lines of code | ~12k | ~50k+ |

## The Tradeoff
Matcha is purpose-built: a Zig core behind a stable C ABI (`include/matcha.h`), a thin SwiftUI shell, and a Metal renderer that writes straight to the GPU. That means no free lunch from AppKit — features like regex find/replace, encoding detection, AppleScript, printing, CJK vertical text, VoiceOver, the services menu, and input methods all have to be built deliberately rather than inherited.

The bet is that a tight, code-editor-shaped core is worth giving up the generality of the platform text stack.
