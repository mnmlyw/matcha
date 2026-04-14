# Matcha

A lightweight, native macOS text editor built with a Zig core and a SwiftUI + Metal shell. See [Why Matcha](docs/why-matcha.md) for an architecture overview.

## Download

[**Download for Mac**](https://github.com/mnmlyw/matcha/releases/latest/download/matcha-macos-arm64.dmg) — open the DMG and drag to Applications.

Requires macOS (Apple Silicon).

## Features

- Light and dark themes with matcha green accents — syncs with system appearance
- Tab bar with drag-to-reorder for multiple open files per window
- Multiple cursors (Cmd+D) with simultaneous editing
- Syntax highlighting for Zig, Swift, C/C++, Python, JavaScript/TypeScript, Rust, Go, Lua, Shell, Markdown, JSON, TOML, and YAML
- Color emoji with grapheme cluster segmentation (flags, families, skin tones)
- CJK and fullwidth character support with automatic font fallback
- Find and replace with case-sensitive and whole-word options
- Command palette (Cmd+Shift+P) and fuzzy file finder (Cmd+P)
- Buffer word completion (Escape)
- Bracket matching, auto-pairing, and auto-indent
- Indent guides, word-boundary line wrapping, current line highlight, trailing whitespace visualization
- Go to Line (Cmd+L), comment toggling, duplicate/move line
- Undo/redo, scroll past end
- Metal-rendered text with glyph atlas and Retina support
- Multi-window, drag-and-drop file opening, Open With support, CLI launcher
- Auto-update notification via GitHub Releases

## Build from Source

Requires Zig and Xcode Command Line Tools (`xcrun`, `swiftc`, `iconutil`).

```sh
zig build app      # build Matcha.app
zig build run      # build and launch
zig build test     # run unit tests
```

## Configuration

Matcha reads `~/.config/matcha/config`:

```
appearance = auto
font-family = SF Mono
font-size = 14
tab-size = 4
insert-spaces = true
line-numbers = true
wrap-lines = true
auto-update = true
```

`appearance` can be `auto` (follows system), `light`, or `dark`. Set `auto-update = false` to disable the update checker.
