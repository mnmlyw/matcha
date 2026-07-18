# Security & Performance Audit — 2026-07-17

Findings from a full audit of the Zig core, C ABI boundary, Swift shell, and
rendering pipeline. Each item was verified against the code at commit `791385e`
(v0.5.4). Checkboxes track fix status. Line numbers are approximate anchors and
will drift as files change.

Suggested fix order: S1 → S2 → S4 → P1 → P4 → S3 → S5 → P2 → P3 → P5, then the
rest opportunistically.

**Status (2026-07-17):** S1, S2, S3, S4, S5, P1, P2, P3, P4, P5 fixed and
verified (Zig unit tests, Swift XCTest suite via `zig build swift-test`, and
`zig build app`). Each fix has regression tests that were confirmed to fail
against the pre-fix code and pass against the fix. Notable follow-on
findings from the fix work itself:
- P4's Swift-side fix and S3's ABI-backed byte↔UTF-16 conversion together
  eliminated full-buffer fetches in `selectedRange`, `markedRange`,
  `characterIndex`, and `firstRect` too (beyond what P4 originally scoped).
- P3's `wrap_dirty_line` single-line-edit hint (Editor.zig) is reused
  as-is to drive P5's highlight-cache invalidation, since both caches key
  off the identical "which line(s) changed" signal.
- P1 benchmarked at ~10x on a 40k-insert workload against an 80k-line
  document (47s → ~4s wall clock, compile time included in both).

---

## Security & data integrity

### High

- [x] **S1. Non-atomic save can destroy the user's file**
  `src/editor/Editor.zig:227` — `saveAs` truncates the target with `createFile`
  then streams content. A crash, power loss, or disk-full mid-write leaves the
  file truncated/partial and the original is gone (on `NoSpaceLeft` the error
  is surfaced but the on-disk copy is already destroyed).
  **Fix:** write to a temp file in the same directory, fsync, then atomically
  rename over the target. Preserve permissions of the original file.

- [x] **S2. Use-after-free / double-free in `saveAs` filename update (OOM-gated)**
  `src/editor/Editor.zig:232-235` — old filename is freed *before*
  `try self.allocator.dupe(u8, path)`. If the dupe fails, `self.filename`
  dangles with `filename_owned` still true; the next `matcha_editor_get_info`
  (borrowed pointer per ABI contract) reads freed memory and
  `deinit`/`openFile` double-frees.
  **Fix:** dup-first-with-errdefer, free old last — same pattern `openFile`
  already uses.

- [x] **S3. IME edits silently corrupt files containing invalid UTF-8**
  `macos/Sources/Views/MetalEditorView.swift:735` (insertText explicit-range
  path), `:753-756` (setMarkedText), helper `utf16RangeToByteRange` `:317-325`;
  `macos/Sources/Bridge/MatchaEditor.swift:214` — byte ranges for
  `replaceRange` are computed against the lossily decoded String
  (`String(decoding:as: UTF8.self)`), where each invalid source byte became a
  3-byte U+FFFD, skewing every subsequent offset by +2 per invalid byte.
  Repro: open a file with a stray Latin-1 byte (e.g. `0xE9`) near the top,
  move below it, use press-and-hold accent picker or IME reconversion → wrong
  bytes overwritten silently. The `getContent()` doc comment already warns
  against this use.
  **Fix:** compute byte offsets against the true buffer bytes (add an ABI call
  that maps UTF-16 offsets ↔ byte offsets on the Zig side, or expose raw bytes
  for the mapping), or detect invalid UTF-8 at load and refuse the
  offset-mapping fast path.

### Medium

- [x] **S4. Forward-delete over truncated UTF-8 eats bytes from the next line**
  `src/buffer/UnicodeIterator.zig:98` — `nextClusterLen` never clamps the first
  codepoint's claimed byte length to the slice: a lone leading byte (e.g.
  `0xF0`) at end-of-line reports len 4. `deleteForward`
  (`src/editor/Editor.zig:457-469`) applies that length to the *document*,
  deleting the newline plus 2 bytes of the following line (silent corruption;
  on the last line it surfaces `error.InvalidRange`). The ZWJ branch clamps
  (`if (end > data.len) end = data.len`); the initial length does not.
  **Fix:** clamp `end` to `data.len` right after `first_byte_len` is added.

- [x] **S5. Config `font-size` accepts `inf`/absurd values, flows into CoreText**
  `src/config/Parser.zig:92-94` — only guard is `v > 0`; `parseFloat` accepts
  `inf` and `1e308`. Value reaches font/atlas creation at launch via
  `matcha_config_get_float` → `MatchaConfig.fontSize`
  (`macos/Sources/Bridge/MatchaConfig.swift:42-44`) → crash/hang before the
  user can fix the config in-app. `tab-size` on neighboring lines is properly
  range-capped (1–32).
  **Fix:** clamp to a sane range (e.g. 4–256) and reject non-finite values.

- [ ] **S6. Clipboard truncates at embedded NUL; `matcha_free_string` frees with understated length**
  `macos/Sources/Bridge/MatchaEditor.swift:196` — `String(cString:)` stops at
  the first NUL, so copying a selection spanning `\0` loses everything after
  it. `src/main_c.zig:434-446` — `matcha_free_string` uses `std.mem.span`
  (also NUL-scanned), so the freed slice length is wrong for NUL-containing
  strings; benign under `c_allocator` today but heap corruption if the
  allocator ever changes (e.g. GPA for leak checking).
  **Fix:** make `matcha_editor_get_selection_text` return an explicit length
  like `matcha_editor_get_content` does, and free with the real length.

### Low

- [ ] **S7. Safety-checked `@intCast` panics reachable from the C ABI**
  `src/main_c.zig:383` (`out_len.* = @intCast(content.len)`) and the render
  getters at `:732, :740, :804, :812, :820, :828, :837` — buffers can grow past
  4 GiB via paste (open is capped at 100 MB but growth is unbounded); the u32
  narrowing then panic-aborts (UB in ReleaseFast) instead of erroring through
  the ABI.
  **Fix:** cap buffer growth, or return an error/0 on overflow instead of
  `@intCast`.

- [ ] **S8. UpdateChecker opens release URL with no scheme/host validation**
  `macos/Sources/App/UpdateChecker.swift:44-57, 71-74` — `html_url` from the
  GitHub API JSON goes to `NSWorkspace.shared.open` unchecked; a hostile value
  (repo takeover / API compromise) could launch an arbitrary URL-scheme
  handler. Transport itself is fine (HTTPS, default ATS, JSON-only, no code
  download, 24 h throttle).
  **Fix:** require `scheme == "https" && host == "github.com"` before opening.

- [ ] **S9. FileFinder relative-path computed with replace-all, not prefix strip**
  `macos/Sources/Views/FileFinderView.swift:205` —
  `replacingOccurrences(of: root + "/", with: "")` removes *every* occurrence.
  Root `/a/b` containing `/a/b/mirror/a/b/x.txt` yields `mirror/x.txt`, and
  `open()` (`:158`) then opens/creates a different file than selected.
  **Fix:** `hasPrefix` + `dropFirst`.

- [ ] **S10. Grouped ops lack rollback; failed `commit` leaves `current_ops` populated (OOM-gated)**
  `src/editor/UndoStack.zig:128-145` + `src/editor/Editor.zig` —
  `toggleComment`, `duplicateLine`, `moveLineUp`, `moveLineDown`,
  `handleAutoPair` don't roll back on mid-loop allocation failure (unlike
  `insertTab`/`dedent`), and if `commit`'s append fails, `current_ops` isn't
  cleared, so ops duplicate into the next group and undo replays them twice at
  stale positions.
  **Fix:** mirror the `insertTab` rollback + `discardCurrentGroup()` pattern;
  clear `current_ops` on commit failure.

- [ ] **S11. Token-cache OOM path leads to out-of-bounds index**
  `src/render/RenderState.zig:75-80` + `:669-670` — if `invalidate`'s
  `ensureTotalCapacity` fails it returns with `entries` empty but records the
  `edit_counter`; `lineTokens` then indexes `entries.items[line]` unchecked →
  index-OOB panic / UB in ReleaseFast. OOM-only.
  **Fix:** don't record the edit counter on failure, or bounds-check in
  `lineTokens`.

- [ ] **S12. Multi-cursor undo restores cursor to the wrong position**
  `src/editor/Editor.zig:594, :1323` — `setCursorBefore(primary)` only latches
  while `current_ops` is empty, but the first extra cursor's
  `deleteSelectionNoCommit` overwrites it before any op is recorded. Undo of a
  multi-cursor edit lands on whichever extra cursor was processed first.
  **Fix:** latch the primary cursor before any per-cursor processing begins.

- [ ] **S13. App hardening posture (informational)**
  No `.entitlements`, no App Sandbox, no hardened runtime; release is ad-hoc
  signed (`codesign --sign -`); `CFBundleDocumentTypes` claims
  `public.data`/`public.item` (`macos/Matcha-Info.plist:60-62`). Any bug
  reachable from file contents runs with full user privileges; no notarization
  chain for the DMG.
  **Fix (long-term):** Developer ID signing + notarization + hardened runtime;
  consider sandboxing.

- [ ] **S14. Config load errors silently swallowed**
  `macos/Sources/Bridge/MatchaConfig.swift:15` discards the result of
  `matcha_config_load_file`; `src/main_c.zig:35` collapses all parse errors to
  `false`. A >1 MB or unreadable config silently falls back to defaults.
  **Fix:** surface a one-time notice (status bar / alert) when the config
  fails to load.

- [ ] **S15. `PieceTable.byteAt` mutates shared hint state via `@constCast` (documented footgun)**
  `src/buffer/PieceTable.zig:270-283` — read-path queries write
  `hint_piece_idx`/`hint_piece_offset`; safe single-threaded (verified), but
  any future off-main-thread ABI call yields torn hints → wrong bytes
  returned.
  **Fix:** document the main-thread-only contract in `matcha.h`, or make the
  hint update atomic/removable.

---

## Performance

### High

- [x] **P1. `refreshCaches` rescans the entire document on every insert/delete**
  `src/buffer/PieceTable.zig:361-385`, called unconditionally from `insert`
  (`:147`) and `delete` (`:217`) — every byte of every piece is walked to
  rebuild `line_starts` on each keystroke; with the 100 MB cap that's a 100 MB
  scan per typed character. This is the dominant per-keystroke cost.
  **Fix:** incremental update — lines at/after the edit shift by a constant
  delta; only the edited line's entries change.

- [x] **P2. No piece coalescing: one new piece per keystroke**
  `src/buffer/PieceTable.zig:124-147` — typing appends contiguously to
  `add_buffer` but always creates a new `Piece`, so N keystrokes → N pieces,
  making every piece walk O(N) and compounding P1. Also makes `replaceAll`
  O(matches × document) (`src/editor/Editor.zig:1989-2023`), and its undo
  equally slow.
  **Fix:** extend the previous piece in place when it is `.add` and ends
  exactly at `add_start`.

- [x] **P3. Word-wrap cache rebuilds from a full file copy per keystroke**
  `src/editor/Editor.zig:2334-2420` — keyed on `(edit_counter, wrap_width)`,
  so every edit triggers `getContent` (full O(n) alloc+copy) plus a full
  cluster-width rescan; also re-triggered per step of a live window resize,
  and `MetalEditorView.setFrameSize` (`:201-206`) forces a synchronous draw
  per resize step.
  **Fix:** incremental rebuild of only the edited line's row count; debounce
  resize recomputes.

- [x] **P4. Swift fetches + decodes the entire buffer on every keystroke**
  `macos/Sources/Views/MetalEditorView.swift:730` — `insertText`
  unconditionally calls `getContentCached()`, whose cache is keyed on the
  version counter and therefore misses every keystroke; the value is only
  needed in the rare explicit-`replacementRange` branch. Post-keystroke
  `selectedRange()`/`markedRange()` queries add two more full-buffer copies in
  Zig (`src/main_c.zig:376-385` double-copies: `getContent` + `allocSentinel`)
  plus an O(cursor-offset) prefix decode per `byteOffsetToUTF16` call
  (`MetalEditorView.swift:327-330`).
  **Fix:** fetch content lazily only in the explicit-range branch; single-copy
  the sentinel path in main_c.zig; answer UTF-16 offset queries from the Zig
  side without materializing the whole document.

- [x] **P5. Highlighting caches invalidated wholesale — O(file) re-lex per edit**
  `src/render/RenderState.zig:143-147, 218-228, 636-660` — any edit discards
  the line-state checkpoint cache; the next frame re-lexes every line from 0
  to the viewport (typing at the bottom of a 500k-line file rescans all of
  it). The token cache (`:69-90, :170-178`) likewise frees every line's
  tokens per edit.
  **Fix:** invalidate from the edited line forward only; keep checkpoints
  above the edit.

### Medium

- [ ] **P6. Completions are O(file) with per-word allocs, synchronous per keystroke**
  `src/editor/Editor.zig:1456-1525` (full `getContent` copy + whole-file word
  scan + dupe of every seen word), extra copy in `src/main_c.zig:466-475`,
  driven synchronously from every handled key while the popup is open
  (`macos/Sources/Views/MetalEditorView.swift:554-570, :697, :704`).
  **Fix:** maintain an incremental word index, or scan a bounded window and/or
  move the query off the key-handling path.

- [ ] **P7. No dirty tracking: cursor blink re-runs the full render pipeline at ~2 Hz**
  `macos/Sources/Views/MetalEditorView.swift:460-477` (0.53 s timer →
  `requestRedraw`), `src/editor/Editor.zig:2038` (`prepareRender`
  unconditionally recomputes) — every blink tick regenerates all viewport
  cells, selection/bracket geometry, and re-uploads all six vertex buffers
  even with zero state change. Constant CPU/battery drain per open window.
  **Fix:** track dirty state; on blink-only ticks update just the cursor
  uniform/quad.

- [ ] **P8. No CPU/GPU frame synchronization on shared buffers**
  `macos/Sources/Renderer/MetalRenderer.swift:406-439` (uploadVertices),
  `:452-467, :481-497` (texture `replace`), `:336-338` (commit without wait) —
  each frame overwrites the same `.storageModeShared` buffers/textures the
  previous in-flight frame may still read → flicker/garbled quads under load.
  **Fix:** in-flight semaphore with double/triple-buffered vertex buffers.

- [ ] **P9. Glyph atlas: no eviction; when full, per-frame CoreText re-rasterization forever**
  `macos/Sources/Renderer/MetalRenderer.swift:500-604` (append-only growth to
  8192², freed space never reclaimed; 64 MB gray + 256 MB RGBA CPU copies),
  `:638-645, :809-823` (rasterization failure deliberately not cached) — once
  full, every missing glyph re-runs `CTFontGetGlyphsForCharacters`/`CTLine`
  work per cell per frame while rendering blank.
  **Fix:** cache failures as "missing" sentinel; add LRU eviction or atlas
  reset-and-repack on fill.

- [ ] **P10. Per-frame cost is O(longest visible line), not O(viewport)**
  `src/render/RenderState.zig:309-401, :434-487`;
  `src/editor/Editor.zig:2135-2208` — the per-line loop measures every cluster
  to end-of-line even far past the right edge, and cursor/bracket/trailing-WS
  metrics rescan from byte 0 each frame. A multi-MB single-line file freezes
  the UI on every blink tick.
  **Fix:** early-exit the cluster walk once past the visible right edge (plus
  cursor position); cache line-prefix metrics between frames.

- [ ] **P11. FileFinder fuzzy filter runs on the main thread over 50k paths per keystroke**
  `macos/Sources/Views/FileFinderView.swift:17-31` (computed property:
  lowercase-allocate + match + sort of the whole list), re-evaluated per
  keystroke, per body render, per arrow-key event (`:108`), per selection
  change (`:89`).
  **Fix:** cache lowercased paths once, debounce + filter off-main-thread,
  memoize results per query string.

- [ ] **P12. Unbounded undo history**
  `src/editor/UndoStack.zig:128-154` — no depth or byte cap; large
  paste/replaceAll groups are retained forever → session memory grows without
  bound.
  **Fix:** cap by total bytes and/or group count, dropping oldest.

- [ ] **P13. Word-wrap rewind desyncs syntax coloring on wrapped rows**
  `src/render/RenderState.zig:311-321` (rewind), `:364-376` (`token_idx`
  monotonic), `:336-339` — on a word-boundary wrap the cells rewind but the
  token index doesn't, so multi-token wrapped words lose highlighting at the
  start of the wrapped row; rewound clusters are also re-appended to
  `cluster_strings` (memory waste).
  **Fix:** rewind `token_idx` (or re-seek by byte pos) along with `col`; don't
  re-append cluster strings for rewound cells.

### Low

- [ ] **P14. `search_content_cache` retains a full document copy indefinitely**
  `src/editor/Editor.zig:2600-2612` — one Cmd-F in a 100 MB file permanently
  doubles resident memory for that tab. **Fix:** free/shrink after the find
  session ends.

- [ ] **P15. `selectNextOccurrence`/`getCompletions` allocate fresh full copies**
  `src/editor/Editor.zig:1245, :1476` — instead of reusing the
  `searchContent` cache built for this purpose (`:2600`).

- [ ] **P16. `openFile` holds 2× file size transiently**
  `src/editor/Editor.zig:179-182` + `src/buffer/PieceTable.zig:44-58` —
  content is read, then `initWithContent` dupes it before the first copy is
  freed. **Fix:** have `initWithContent` take ownership.

- [ ] **P17. `ensureCursorVisible` allocates a full line copy per keystroke/movement**
  `src/editor/Editor.zig:2123-2132, :2845-2877` — O(line) alloc+scan on every
  edit and arrow key; pathological on huge single-line files.

- [ ] **P18. Per-frame allocations for multi-codepoint cluster cells**
  `macos/Sources/Renderer/MetalRenderer.swift:629-636` — null-scan + Array
  copy + String decode + dict lookup per visible cluster cell per frame
  (offsets are unstable across frames). **Fix:** stable cluster IDs from the
  Zig side, or per-frame memo keyed on offset.

- [ ] **P19. `MatchaConfig.fontFamily` does dupeZ + copy + free per property access**
  `macos/Sources/Bridge/MatchaConfig.swift:29-40`. **Fix:** cache in Swift.

- [ ] **P20. `src/font/Atlas.zig` is dead code**
  Fixed 1024², no growth/eviction, unreachable from the app
  (`src/main_c.zig:845`). Remove or finish before wiring up.

---

## Process

- [ ] **X1. Documented release flow builds Debug**
  `AGENTS.md` release process runs `zig build app` with no `-Doptimize`;
  `b.standardOptimizeOption` defaults to Debug (safety checks + Debug-speed
  Zig). `build.zig:134` marks Debug builds `0.0.0-dev`, so a mistake is
  visible in the About box, but the docs should specify
  `-Doptimize=ReleaseSafe` (recommended over ReleaseFast given the
  ABI-reachable `@intCast` panics in S7).

---

## Verified sound (no action needed)

Explicitly checked and confirmed correct:

- Reverse-order undo invariant for line ops (`toggleComment`,
  `duplicateLine`, `moveLineUp/Down`, multi-cursor ops) — holds.
- Four-way word-wrap consistency (`RenderState.compute`,
  `byteColToPixelMetricsWithData`, `pixelXToByteCol`, `rebuildWrapCache`) —
  identical wrap condition, space tracking, and cluster iteration; the wrap
  cache's arithmetic carry is exactly equivalent to the positional rewind.
- Borrowed-pointer discipline across the ABI (`filename`, `get_last_error`
  copied to Swift Strings immediately); struct layouts match `matcha.h`
  field-for-field; every export null-guards with `orelse`.
- Offset clamping on all incoming ABI positions (hostile offsets can't go
  out of bounds).
- Config parser limits: 1 MB file cap, bounded color parsing (3/6/8 hex
  digits, overflow caught), malformed lines skipped, `tab-size` range-checked.
- `openFile` 100 MB cap; failed opens preserve the current document.
- FileFinder traversal: no symlink cycles (enumerator doesn't follow), 50k
  result cap, dangerous roots refused, scan off-main-thread.
- Drag-and-drop restricted to file URLs; Apple Events coerced to
  `typeFileURL`; no arbitrary scheme handling.
- UpdateChecker transport: HTTPS, default ATS (no plist exceptions),
  JSON-only parsing, no code download/execution, 24 h throttle, respects
  `auto-update = false`.
- No ABI calls off the main thread; no retain cycles (blink timer and
  notification observers use `[weak self]`, cleaned up in `deinit`).
- Lexer is strictly O(line) with carried cross-line state — no intra-lexer
  quadratic blowup (the O(file) costs are in the cache layers, P5).
- Vertex buffers viewport-culled and growth-capped with shrink-back.
- Cluster-sentinel (`0x110000 + offset`) consumption in Swift is fully
  bounds-checked.
