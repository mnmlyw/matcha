# Matcha

Matcha is a native macOS text editor with a Zig editing core and a SwiftUI + Metal app shell. The project is split so the editor engine can be built as a reusable static library while the macOS app provides the windowing, input, and rendering integration.

## Current Scope

Matcha already supports:

- file open, save, and save as
- syntax highlighting for Zig, Swift, C/C++, Python, JavaScript/TypeScript, Rust, Go, shell, Markdown, JSON, TOML, and YAML
- find and replace with case-sensitive and whole-word options
- line numbers, line wrapping, comment toggling, duplicate line, and move line up/down
- multi-window app launches and opening files from the command line

This is currently a macOS-only project.

## Requirements

- macOS
- Zig
- Xcode Command Line Tools (`xcrun`, `swiftc`, `iconutil`)

## Quick Start

Build the Zig core:

```sh
zig build
```

Build the app bundle:

```sh
zig build app
```

Launch the app:

```sh
zig build run
```

Open a sample file after building:

```sh
bin/matcha demo/hello.zig
```

Run the Zig test suite:

```sh
zig build test
```

Equivalent `make` targets are available: `make lib`, `make app`, `make run`, `make test`, and `make clean`.

## Project Layout

- `src/`: Zig editor core, including buffer management, editing commands, rendering state, highlighting, input, and config parsing
- `src/main.zig`: public Zig entry point
- `src/main_c.zig`: C ABI layer exported to the app
- `include/matcha.h`: public C header used by the Swift bridge
- `macos/Sources/`: SwiftUI app, Metal renderer, input bridge, and editor wrapper
- `macos/Assets.xcassets/`: app icons and bundled assets
- `demo/`: sample files for manual testing
- `test/fixtures/`: file-backed test data

## Configuration

Matcha reads user settings from `~/.config/matcha/config`. Current settings include font family, font size, tab size, spaces vs tabs, line numbers, and wrap mode. The parser and defaults live under `src/config/`.

## Development Notes

Format Zig code before sending changes for review:

```sh
zig fmt build.zig src/**/*.zig
```

When changing exported editor APIs, keep `src/main.zig`, `src/main_c.zig`, and `include/matcha.h` in sync. For app-side changes, pair `zig build test` with `zig build app` to catch bridge or rendering regressions.
