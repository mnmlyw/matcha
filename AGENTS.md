# Repository Guidelines

## Project Structure & Module Organization
`src/` contains the Zig editor core, split by concern into `buffer/`, `editor/`, `render/`, `highlight/`, `input/`, `font/`, and `config/`. `src/main.zig` is the public Zig entry point, and `include/matcha.h` exposes the C ABI used by the macOS app. `macos/Sources/` holds the SwiftUI shell, Metal renderer, and bridge wrappers; `macos/Assets.xcassets/` stores app assets. `docs/` contains the GitHub Pages landing page. Use `test/fixtures/` for file-backed test data and `demo/` for manual testing samples. Do not commit generated output from `zig-out/` or `.zig-cache/`.

## Build, Test, and Development Commands
Use `zig build` or `make lib` to build the static library and install headers into `zig-out/`. Use `zig build test` or `make test` to run the inline Zig unit tests. Use `zig build app` or `make app` to build `zig-out/Matcha.app` with `swiftc`, and `zig build run` or `make run` to build and open the app. After building the app, `zig-out/Matcha.app/Contents/MacOS/Matcha demo/hello.zig` launches the binary directly with a sample file. Use `make clean` to remove build artifacts. The swiftc target is pinned to macOS 14.0 in `build.zig`, matching `LSMinimumSystemVersion` in `Matcha-Info.plist`.

## Coding Style & Naming Conventions
Format Zig sources with `zig fmt build.zig src/**/*.zig pkg/**/*.zig` before review. Follow Zig's existing conventions: `UpperCamelCase` for files and public types, `lowerCamelCase` for functions and fields, and colocated tests near implementation. Keep exported API changes synchronized between `src/main.zig`, `src/main_c.zig`, and `include/matcha.h`. In Swift, match the current style in `macos/Sources/`: `UpperCamelCase` types, focused view structs, and bridge logic isolated under `Bridge/`.

## Testing Guidelines
Add Zig `test "Module: scenario"` blocks in the same file as the code they cover; existing examples include `test "Editor: undo/redo"` and `test "Parser: parse config"`. Prefer fast unit coverage in `src/`, and use `test/fixtures/` when file I/O matters. When changing SwiftUI, rendering, or bridge code, pair `zig build test` with a manual `zig build app` smoke test.

## Commit & Pull Request Guidelines
Recent commits use imperative, sentence-style subjects such as `Add syntax highlighting...` and `Fix editor state...`. Keep commits scoped to one logical change and describe the visible behavior, not just the refactor. Pull requests should summarize affected areas, list verification commands, link the relevant issue, and include screenshots or a short recording for UI changes.

## C API & Bridge Contract
Adding a new editor operation requires changes in four files: implement in `src/editor/Editor.zig`, export via `src/main_c.zig`, declare in `include/matcha.h`, and wrap in `macos/Sources/Bridge/MatchaEditor.swift`. The C API uses two memory ownership patterns: **borrowed** pointers (e.g., `filename` in `matcha_editor_info_s`, `get_last_error`) that are valid until the next editor mutation and must not be freed, and **allocated** pointers (e.g., `get_selection_text`) that the caller must free with `matcha_free_string`. The editor caches a null-terminated `filename_z` field to avoid allocating on every `get_info` call. Config functions (`matcha_config_get_*`) require a `matcha_config_t` handle, not `matcha_editor_t` — use `editor.config.handle` in Swift, not `editor.handle`.

## Architecture Invariants
Cursor columns are **byte offsets**, not codepoint counts; `byteColToVisualCol`/`visualColToByteCol` convert between the two. Line operations (`toggleComment`, `duplicateLine`, `moveLineUp`, `moveLineDown`) modify the piece table in-place and process lines in **reverse order** so that byte positions in undo records remain valid when replayed. The piece table caches `line_count`, `total_length`, and a **line offset index** (`line_starts`) — all invalidated by `refreshCaches` on every insert/delete. `lineStart()` and `lineEnd()` are O(1) lookups; `posToLineCol()` uses binary search (O(log N)). The wrap cache uses a prefix-sum array keyed by `edit_counter` and `wrap_width`; it rebuilds automatically when stale. Word-boundary wrapping must be consistent across the render loop (`RenderState.compute`), cursor metrics (`byteColToPixelMetrics`), click handling (`pixelXToByteCol`), and the wrap cache (`rebuildWrapCache`) — all four must use the same space-tracking logic and `nextClusterLen` for grapheme cluster boundaries.

## Dirty Tracking
Editor uses a **signed version counter** (`current_version`) for modified-state tracking. Forward edits increment via `markDirty()` (called exactly once after each `undo_stack.commit()`), undo decrements by 1, redo increments by 1. `save_version` records the version at last save. `save_reachable` tracks whether the saved state is still reachable via undo — it becomes `false` when a new edit branches history and the saved state was in the destroyed redo path (i.e., `save_version > branch_point`). Internal buffer mutations (`deleteSelectionNoCommit`, `insertNoCommit`) call `invalidateCaches()` only, not `markDirty()`, so grouped operations count as a single version step.

## Unicode & Rendering
`charWidth` in `UnicodeIterator.zig` returns 2 for CJK/fullwidth/emoji codepoints. `nextClusterLen` detects grapheme cluster boundaries (combining marks, regional indicators, ZWJ sequences, variation selectors, skin modifiers). All cursor, click, and wrap functions iterate by grapheme cluster. Multi-codepoint clusters are stored in `RenderState.cluster_strings` and encoded as `glyph_index = 0x110000 + offset`. The Metal renderer uses two atlases: grayscale (`r8Unorm`) for monochrome text and RGBA (`bgra8Unorm`) for color emoji. Color fonts are detected via `CTFontGetSymbolicTraits(.traitColorGlyphs)`. Multi-codepoint clusters render via `CTLineCreateWithAttributedString`.

## Theming
`Config.Appearance` can be `.light`, `.dark`, or `.auto`. The `.auto` default detects macOS system appearance at launch via `matcha_config_set_system_dark`. `Config.applyAppearance()` sets all color fields (bg, fg, cursor, selection, gutter, chrome, syntax theme). Chrome colors (`chrome_bg_color`, `chrome_fg_color`, etc.) are read by Swift UI views via `matcha_config_get_color`. The config parser runs twice: first to determine appearance, then `applyAppearance()`, then re-parsed so individual color overrides (e.g., `bg-color = #1a1a1a`) take precedence over the theme.

## Tab Management
`TabManager` holds multiple `MatchaEditor` instances with per-editor Combine subscriptions (tracked by tab UUID, cleaned up on close). All instances are tracked via a static weak-reference list for multi-window quit protection. Each tab has a stable `UUID` for SwiftUI identity. Notifications use `object: nil` (window-scoped); ContentView guards with `isKeyWindow` to prevent cross-window routing. When closing modified tabs, a Save/Don't Save/Cancel dialog appears; close aborts if save fails. Drag-and-drop file opening routes through the `matchaOpenFilePath` notification to respect unsaved-tab logic.

## Release Process
Tag, build, sign, package DMG, and upload: `zig build app && codesign --deep --force --sign - zig-out/Matcha.app`, create DMG with Applications symlink, `gh release create vX.Y.Z matcha-macos-arm64.dmg`. Use the consistent filename `matcha-macos-arm64.dmg` (no version) so the download URL never changes.

## Configuration Notes
The app loads user configuration from `~/.config/matcha/config` through `src/config/Parser.zig`. When adding settings, update the parser, defaults, and any Swift bridge reads together. The `appearance` setting controls theming; individual color keys override the theme.
