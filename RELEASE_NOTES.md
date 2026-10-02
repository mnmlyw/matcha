# Matcha v0.5.5

This release focuses on data integrity, responsiveness on large files, and
macOS rendering reliability.

## Highlights

- Saves are now atomic and preserve existing file permissions, preventing a
  failed or interrupted write from destroying the original file.
- IME and clipboard operations preserve invalid UTF-8 and embedded NUL bytes
  without replacing or truncating neighboring content.
- Editing large files is substantially faster through incremental line, wrap,
  and syntax-token caches plus piece coalescing.
- Cursor blinking reuses prepared geometry, file completion scans are bounded,
  and File Finder filtering now runs off the main thread.
- Metal rendering now synchronizes shared buffers, recovers full glyph atlases,
  and correctly retains syntax colors across wrapped rows.
- Undo history is bounded, grouped edits roll back safely on allocation
  failure, and multi-cursor undo restores the primary cursor.
- Configuration errors are surfaced at launch and unsafe font sizes are
  rejected.

## Compatibility

- Requires macOS 14 or later on Apple Silicon.
- The C ABI for allocated editor byte strings now requires an explicit length
  when freeing them. Consumers should rebuild against the bundled
  `include/matcha.h`.
