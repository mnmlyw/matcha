# Repository Guidelines

## Project Structure & Module Organization
`src/` contains the Zig editor core, split by concern into `buffer/`, `editor/`, `render/`, `highlight/`, `input/`, and `config/`. `src/main.zig` is the public Zig entry point, and `include/matcha.h` exposes the C ABI used by the macOS app. `macos/Sources/` holds the SwiftUI shell, Metal renderer, and bridge wrappers; `macos/Assets.xcassets/` stores app assets. Use `test/fixtures/` for file-backed test data and `demo/` for manual syntax-highlighting samples. Do not commit generated output from `zig-out/` or `.zig-cache/`.

## Build, Test, and Development Commands
Use `zig build` or `make lib` to build the static library and install headers into `zig-out/`. Use `zig build test` or `make test` to run the inline Zig unit tests. Use `zig build app` or `make app` to build `zig-out/Matcha.app` with `swiftc`, and `zig build run` or `make run` to build and open the app. After building the app, `bin/matcha demo/hello.zig` launches the binary directly with a sample file. Use `make clean` to remove build artifacts.

## Coding Style & Naming Conventions
Format Zig sources with `zig fmt build.zig src/**/*.zig pkg/**/*.zig` before review. Follow Zig’s existing conventions: `UpperCamelCase` for files and public types, `lowerCamelCase` for functions and fields, and colocated tests near implementation. Keep exported API changes synchronized between `src/main.zig` and `include/matcha.h`. In Swift, match the current style in `macos/Sources/`: `UpperCamelCase` types, focused view structs, and bridge logic isolated under `Bridge/`.

## Testing Guidelines
Add Zig `test "Module: scenario"` blocks in the same file as the code they cover; existing examples include `test "Editor: undo/redo"` and `test "Parser: parse config"`. Prefer fast unit coverage in `src/`, and use `test/fixtures/` when file I/O matters. When changing SwiftUI, rendering, or bridge code, pair `zig build test` with a manual `zig build app` smoke test.

## Commit & Pull Request Guidelines
Recent commits use imperative, sentence-style subjects such as `Add syntax highlighting...` and `Fix editor state...`. Keep commits scoped to one logical change and describe the visible behavior, not just the refactor. Pull requests should summarize affected areas, list verification commands, link the relevant issue, and include screenshots or a short recording for UI changes.

## C API & Bridge Contract
Adding a new editor operation requires changes in four files: implement in `src/editor/Editor.zig`, export via `src/main_c.zig`, declare in `include/matcha.h`, and wrap in `macos/Sources/Bridge/MatchaEditor.swift`. The C API uses two memory ownership patterns: **borrowed** pointers (e.g., `filename` in `matcha_editor_info_s`, `get_last_error`) that are valid until the next editor mutation and must not be freed, and **allocated** pointers (e.g., `get_selection_text`) that the caller must free with `matcha_free_string`. The editor caches a null-terminated `filename_z` field to avoid allocating on every `get_info` call.

## Architecture Invariants
Cursor columns are **byte offsets**, not codepoint counts; `byteColToVisualCol`/`visualColToByteCol` convert between the two. Line operations (`toggleComment`, `duplicateLine`, `moveLineUp`, `moveLineDown`) modify the piece table in-place and process lines in **reverse order** so that byte positions in undo records remain valid when replayed. The piece table caches `line_count` and `total_length`, invalidated by `refreshCaches` on every insert/delete. The wrap cache uses a prefix-sum array keyed by `edit_counter` and `wrap_col`; it rebuilds automatically when stale.

## Configuration Notes
The app loads user configuration from `~/.config/matcha/config` through `src/config/Parser.zig`. When adding settings, update the parser, defaults, and any Swift bridge reads together.
