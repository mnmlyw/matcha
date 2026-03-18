# Matcha

A minimal, native macOS text editor built with a Zig core and a SwiftUI + Metal shell.

## Download

Grab the latest release from [GitHub Releases](https://github.com/mnmlyw/matcha/releases). Open the DMG and drag Matcha to Applications.

Requires macOS (Apple Silicon).

## Features

- Tab bar for multiple open files per window
- Syntax highlighting for Zig, Swift, C/C++, Python, JavaScript/TypeScript, Rust, Go, Shell, Markdown, JSON, TOML, and YAML
- CJK and fullwidth character support with automatic font fallback
- Find and replace with case-sensitive and whole-word options
- Bracket matching, auto-pairing, and auto-indent
- Word-boundary line wrapping, current line highlight, trailing whitespace visualization
- Go to Line (Cmd+L), comment toggling, duplicate/move line
- Undo/redo, scroll past end
- Metal-rendered text with glyph atlas and Retina support
- Multi-window, drag-and-drop file opening, CLI launcher
- User configuration via `~/.config/matcha/config`

## Build from Source

Requires Zig and Xcode Command Line Tools (`xcrun`, `swiftc`, `iconutil`).

```sh
zig build app      # build Matcha.app
zig build run      # build and launch
zig build test     # run unit tests
```

Open a file directly:

```sh
zig-out/Matcha.app/Contents/MacOS/Matcha path/to/file
```

## Configuration

Matcha reads `~/.config/matcha/config`:

```
font-family = "SF Mono"
font-size = 14
tab-size = 4
insert-spaces = true
line-numbers = true
wrap-lines = true
```

## Architecture

The editor core is a static library (`libmatcha.a`) with a C API. The macOS app links against it via a Swift bridge. All editing state lives in Zig; Swift handles windowing, input, and Metal rendering.

Key design decisions:
- Cursor columns are byte offsets, not codepoint counts
- Piece table with cached line count and total length
- Word-boundary wrap cache with prefix-sum array
- CJK characters use measured font advance widths
- Glyph atlas with partial dirty-region uploads

## License

MIT
