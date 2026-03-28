// Matcha — Native macOS Text Editor
// Library root: re-exports all modules

pub const PieceTable = @import("buffer/PieceTable.zig").PieceTable;
pub const Editor = @import("editor/Editor.zig").Editor;
pub const FindOptions = Editor.FindOptions;
pub const Cursor = @import("editor/Cursor.zig").Cursor;
pub const Selection = @import("editor/Selection.zig").Selection;
pub const UndoStack = @import("editor/UndoStack.zig").UndoStack;
pub const Config = @import("config/Config.zig").Config;
pub const Parser = @import("config/Parser.zig");
pub const RenderState = @import("render/RenderState.zig").RenderState;
pub const Cell = @import("render/Cell.zig");
pub const Atlas = @import("font/Atlas.zig").Atlas;
pub const FontMetrics = @import("font/Metrics.zig").FontMetrics;
pub const Key = @import("input/Key.zig");
pub const Keybind = @import("input/Keybind.zig");
pub const Language = @import("highlight/Language.zig").Language;
pub const TokenType = @import("highlight/TokenType.zig").TokenType;
pub const Theme = @import("highlight/TokenType.zig").Theme;
pub const Lexer = @import("highlight/Lexer.zig");

// C ABI exports
comptime {
    _ = @import("main_c.zig");
}

test {
    _ = @import("buffer/PieceTable.zig");
    _ = @import("buffer/UnicodeIterator.zig");
    _ = @import("editor/Editor.zig");
    _ = @import("editor/Cursor.zig");
    _ = @import("editor/Selection.zig");
    _ = @import("editor/UndoStack.zig");
    _ = @import("config/Config.zig");
    _ = @import("config/Parser.zig");
    _ = @import("render/RenderState.zig");
    _ = @import("render/Cell.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("font/Metrics.zig");
    _ = @import("input/Key.zig");
    _ = @import("input/Keybind.zig");
    _ = @import("highlight/Language.zig");
    _ = @import("highlight/TokenType.zig");
    _ = @import("highlight/Lexer.zig");
}
