const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenType = @import("TokenType.zig").TokenType;
const Language = @import("Language.zig").Language;

/// Persistent state carried across lines for multi-line constructs.
pub const LineState = struct {
    in_block_comment: bool = false,
    in_multiline_string: bool = false,
    block_comment_depth: u8 = 0,
    /// Quote character that opened the multi-line string ('"', '\'', or '`')
    multiline_quote: u8 = '"',
};

pub const Token = struct {
    start: u32,
    len: u32,
    type: TokenType,
};

pub const LineTokens = struct {
    tokens: []Token,
    end_state: LineState,
    allocator: Allocator,

    pub fn deinit(self: *LineTokens) void {
        self.allocator.free(self.tokens);
    }
};

pub fn tokenizeLine(
    allocator: Allocator,
    line_bytes: []const u8,
    state_in: LineState,
    lang: Language,
) !LineTokens {
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    defer tokens.deinit(allocator);

    var state = state_in;
    var i: u32 = 0;
    const len: u32 = @intCast(line_bytes.len);

    // ── Continue block comment ─────────────────────────────────
    if (state.in_block_comment) {
        const start = i;
        while (i < len) {
            if (lang == .zig) {
                // Zig has no block comments
                break;
            }
            if (i + 1 < len and line_bytes[i] == '*' and line_bytes[i + 1] == '/') {
                if (state.block_comment_depth > 1) {
                    state.block_comment_depth -= 1;
                } else {
                    state.in_block_comment = false;
                    state.block_comment_depth = 0;
                    i += 2;
                    break;
                }
                i += 2;
                continue;
            }
            if (i + 1 < len and line_bytes[i] == '/' and line_bytes[i + 1] == '*') {
                state.block_comment_depth +|= 1;
                i += 2;
                continue;
            }
            i += 1;
        }
        if (i > start) {
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .comment });
        }
    }

    // ── Continue multi-line string ─────────────────────────────
    if (state.in_multiline_string) {
        const start = i;
        const mq = state.multiline_quote;
        while (i < len) {
            if (lang == .python) {
                // Look for matching triple-quote (""" or ''')
                if (i + 2 < len and line_bytes[i] == mq and line_bytes[i + 1] == mq and line_bytes[i + 2] == mq) {
                    i += 3;
                    state.in_multiline_string = false;
                    break;
                }
            } else if (lang == .javascript) {
                // Template literal backtick
                if (line_bytes[i] == '`') {
                    i += 1;
                    state.in_multiline_string = false;
                    break;
                }
                if (line_bytes[i] == '\\' and i + 1 < len) {
                    i += 2;
                    continue;
                }
            }
            i += 1;
        }
        if (i > start) {
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .string });
        }
    }

    // ── Main tokenizer loop ────────────────────────────────────
    while (i < len) {
        const ch = line_bytes[i];

        // Skip whitespace — emit as normal
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            const start = i;
            while (i < len and (line_bytes[i] == ' ' or line_bytes[i] == '\t' or line_bytes[i] == '\r')) {
                i += 1;
            }
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .normal });
            continue;
        }

        // Line comment
        if (isLineComment(line_bytes, i, lang)) {
            try tokens.append(allocator, .{ .start = i, .len = len - i, .type = .comment });
            i = len;
            continue;
        }

        // Block comment open
        if (lang != .zig and lang != .python and lang != .shell and lang != .lua and
            i + 1 < len and ch == '/' and line_bytes[i + 1] == '*')
        {
            const start = i;
            state.in_block_comment = true;
            state.block_comment_depth = 1;
            i += 2;
            // Scan for close on same line
            while (i < len) {
                if (i + 1 < len and line_bytes[i] == '/' and line_bytes[i + 1] == '*') {
                    state.block_comment_depth +|= 1;
                    i += 2;
                    continue;
                }
                if (i + 1 < len and line_bytes[i] == '*' and line_bytes[i + 1] == '/') {
                    if (state.block_comment_depth > 1) {
                        state.block_comment_depth -= 1;
                    } else {
                        state.in_block_comment = false;
                        state.block_comment_depth = 0;
                        i += 2;
                        break;
                    }
                    i += 2;
                    continue;
                }
                i += 1;
            }
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .comment });
            continue;
        }

        // Python triple-quote string (""" or ''')
        if (lang == .python and (ch == '"' or ch == '\'') and i + 2 < len and line_bytes[i + 1] == ch and line_bytes[i + 2] == ch) {
            const start = i;
            const q = ch;
            i += 3;
            var found_close = false;
            while (i + 2 < len) {
                if (line_bytes[i] == q and line_bytes[i + 1] == q and line_bytes[i + 2] == q) {
                    i += 3;
                    found_close = true;
                    break;
                }
                i += 1;
            }
            if (!found_close) {
                i = len;
                state.in_multiline_string = true;
                state.multiline_quote = q;
            }
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .string });
            continue;
        }

        // String literal
        if (ch == '"' or ch == '\'' or (ch == '`' and lang == .javascript)) {
            const start = i;
            const quote = ch;
            i += 1;
            while (i < len) {
                if (line_bytes[i] == '\\' and i + 1 < len) {
                    i += 2;
                    continue;
                }
                if (line_bytes[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            // If backtick string didn't close, it's a template literal
            if (quote == '`' and i == len) {
                // Check if the loop found a closing backtick (it would have done i+=1 past it)
                // If i==len and the char before i is a backtick AND it's not the opening one, it closed
                const closed = (i > start + 1 and line_bytes[i - 1] == '`');
                if (!closed) {
                    state.in_multiline_string = true;
                    state.multiline_quote = '`';
                }
            }
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .string });
            continue;
        }

        // Number
        if (isDigit(ch) or (ch == '.' and i + 1 < len and isDigit(line_bytes[i + 1]))) {
            const start = i;
            // Hex/bin/oct prefix
            if (ch == '0' and i + 1 < len) {
                const next = line_bytes[i + 1];
                if (next == 'x' or next == 'X' or next == 'b' or next == 'B' or next == 'o' or next == 'O') {
                    i += 2;
                    while (i < len and isHexDigitOrUnderscore(line_bytes[i])) i += 1;
                    try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .number });
                    continue;
                }
            }
            while (i < len and (isDigit(line_bytes[i]) or line_bytes[i] == '_')) i += 1;
            // Decimal point
            if (i < len and line_bytes[i] == '.' and i + 1 < len and isDigit(line_bytes[i + 1])) {
                i += 1;
                while (i < len and (isDigit(line_bytes[i]) or line_bytes[i] == '_')) i += 1;
            }
            // Exponent
            if (i < len and (line_bytes[i] == 'e' or line_bytes[i] == 'E')) {
                i += 1;
                if (i < len and (line_bytes[i] == '+' or line_bytes[i] == '-')) i += 1;
                while (i < len and isDigit(line_bytes[i])) i += 1;
            }
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .number });
            continue;
        }

        // Attribute / builtin (@identifier, decorators)
        if (ch == '@' and i + 1 < len and isIdentStart(line_bytes[i + 1])) {
            const start = i;
            i += 1;
            while (i < len and isIdentChar(line_bytes[i])) i += 1;
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .attribute });
            continue;
        }

        // Identifier / keyword
        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < len and isIdentChar(line_bytes[i])) i += 1;
            const word = line_bytes[start..i];
            const tt = classifyWord(word, lang, line_bytes, i, len);
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = tt });
            continue;
        }

        // Operator
        if (isOperator(ch)) {
            const start = i;
            i += 1;
            // Group consecutive operators
            while (i < len and isOperator(line_bytes[i])) i += 1;
            try tokens.append(allocator, .{ .start = start, .len = i - start, .type = .operator });
            continue;
        }

        // Punctuation
        if (isPunctuation(ch)) {
            try tokens.append(allocator, .{ .start = i, .len = 1, .type = .punctuation });
            i += 1;
            continue;
        }

        // Anything else
        try tokens.append(allocator, .{ .start = i, .len = 1, .type = .normal });
        i += 1;
    }

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .end_state = state,
        .allocator = allocator,
    };
}

/// Scan lines [0, target_line) tracking only multi-line state transitions.
/// Returns the LineState entering target_line.
pub fn scanStateToLine(
    line_bytes_fn: anytype,
    target_line: u32,
    lang: Language,
) LineState {
    var state = LineState{};
    var line: u32 = 0;
    while (line < target_line) : (line += 1) {
        const bytes = line_bytes_fn.call(line);
        state = scanLineState(bytes, state, lang);
    }
    return state;
}

/// Lightweight state-only scan of a single line (no token allocation).
pub fn scanLineState(line_bytes: []const u8, state_in: LineState, lang: Language) LineState {
    var state = state_in;
    var i: usize = 0;
    const len = line_bytes.len;

    if (state.in_block_comment) {
        while (i < len) {
            if (lang == .zig) break;
            if (i + 1 < len and line_bytes[i] == '*' and line_bytes[i + 1] == '/') {
                if (state.block_comment_depth > 1) {
                    state.block_comment_depth -= 1;
                } else {
                    state.in_block_comment = false;
                    state.block_comment_depth = 0;
                    i += 2;
                    break;
                }
                i += 2;
                continue;
            }
            if (i + 1 < len and line_bytes[i] == '/' and line_bytes[i + 1] == '*') {
                state.block_comment_depth +|= 1;
                i += 2;
                continue;
            }
            i += 1;
        }
        if (state.in_block_comment) return state;
    }

    if (state.in_multiline_string) {
        const mq = state.multiline_quote;
        while (i < len) {
            if (lang == .python) {
                if (i + 2 < len and line_bytes[i] == mq and line_bytes[i + 1] == mq and line_bytes[i + 2] == mq) {
                    state.in_multiline_string = false;
                    i += 3;
                    break;
                }
            } else if (lang == .javascript) {
                if (line_bytes[i] == '`') {
                    state.in_multiline_string = false;
                    i += 1;
                    break;
                }
                if (line_bytes[i] == '\\' and i + 1 < len) {
                    i += 2;
                    continue;
                }
            }
            i += 1;
        }
        if (state.in_multiline_string) return state;
    }

    // Scan rest of line for new multi-line constructs
    while (i < len) {
        const ch = line_bytes[i];

        // Line comment — rest of line, no state change
        if (isLineComment(line_bytes, @intCast(i), lang)) return state;

        // Block comment open
        if (lang != .zig and lang != .python and lang != .shell and lang != .lua and
            i + 1 < len and ch == '/' and line_bytes[i + 1] == '*')
        {
            state.in_block_comment = true;
            state.block_comment_depth = 1;
            i += 2;
            while (i < len) {
                if (i + 1 < len and line_bytes[i] == '/' and line_bytes[i + 1] == '*') {
                    state.block_comment_depth +|= 1;
                    i += 2;
                    continue;
                }
                if (i + 1 < len and line_bytes[i] == '*' and line_bytes[i + 1] == '/') {
                    if (state.block_comment_depth > 1) {
                        state.block_comment_depth -= 1;
                    } else {
                        state.in_block_comment = false;
                        state.block_comment_depth = 0;
                        i += 2;
                        break;
                    }
                    i += 2;
                    continue;
                }
                i += 1;
            }
            continue;
        }

        // Python triple-quote (""" or ''')
        if (lang == .python and (ch == '"' or ch == '\'') and i + 2 < len and line_bytes[i + 1] == ch and line_bytes[i + 2] == ch) {
            const q = ch;
            i += 3;
            var found_close = false;
            while (i + 2 < len) {
                if (line_bytes[i] == q and line_bytes[i + 1] == q and line_bytes[i + 2] == q) {
                    i += 3;
                    found_close = true;
                    break;
                }
                i += 1;
            }
            if (!found_close) {
                state.in_multiline_string = true;
                state.multiline_quote = q;
                i = len; // consume remaining chars to avoid misparse
            }
            continue;
        }

        // String literal (skip to end)
        if (ch == '"' or ch == '\'' or (ch == '`' and lang == .javascript)) {
            const quote = ch;
            i += 1;
            var found_close = false;
            while (i < len) {
                if (line_bytes[i] == '\\' and i + 1 < len) {
                    i += 2;
                    continue;
                }
                if (line_bytes[i] == quote) {
                    i += 1;
                    found_close = true;
                    break;
                }
                i += 1;
            }
            if (quote == '`' and !found_close) {
                state.in_multiline_string = true;
                state.multiline_quote = '`';
            }
            continue;
        }

        i += 1;
    }
    return state;
}

// ── Helpers ────────────────────────────────────────────────────

fn isLineComment(bytes: []const u8, pos: u32, lang: Language) bool {
    if (pos >= bytes.len) return false;
    return switch (lang) {
        .zig, .rust, .swift, .c, .go, .javascript => (pos + 1 < bytes.len and bytes[pos] == '/' and bytes[pos + 1] == '/'),
        .lua => (pos + 1 < bytes.len and bytes[pos] == '-' and bytes[pos + 1] == '-'),
        .python, .shell, .toml, .yaml => (bytes[pos] == '#'),
        else => false,
    };
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isHexDigitOrUnderscore(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F') or ch == '_';
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or isDigit(ch);
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '=', '<', '>', '?' => true,
        else => false,
    };
}

fn isPunctuation(ch: u8) bool {
    return switch (ch) {
        '(', ')', '[', ']', '{', '}', ',', '.', ';', ':' => true,
        else => false,
    };
}

fn classifyWord(word: []const u8, lang: Language, line_bytes: []const u8, after: u32, line_len: u32) TokenType {
    if (isKeyword(word, lang)) return .keyword;
    if (isTypeKeyword(word, lang)) return .typ;
    // Check if followed by '(' — function call
    var j = after;
    while (j < line_len and (line_bytes[j] == ' ' or line_bytes[j] == '\t')) j += 1;
    if (j < line_len and line_bytes[j] == '(') return .function;
    return .normal;
}

fn isKeyword(word: []const u8, lang: Language) bool {
    const table: []const []const u8 = switch (lang) {
        .zig => &zig_keywords,
        .swift => &swift_keywords,
        .c => &c_keywords,
        .python => &python_keywords,
        .javascript => &js_keywords,
        .rust => &rust_keywords,
        .go => &go_keywords,
        .shell => &shell_keywords,
        .lua => &lua_keywords,
        else => return false,
    };
    for (table) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isTypeKeyword(word: []const u8, lang: Language) bool {
    const table: []const []const u8 = switch (lang) {
        .zig => &zig_types,
        .swift => &swift_types,
        .c => &c_types,
        .python => &python_types,
        .javascript => &js_types,
        .rust => &rust_types,
        .go => &go_types,
        .lua => &lua_types,
        else => return false,
    };
    for (table) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

// ── Keyword tables ─────────────────────────────────────────────

const zig_keywords = [_][]const u8{
    "addrspace",   "align",       "allowzero", "and",
    "asm",         "async",       "await",     "break",
    "catch",       "comptime",    "const",     "continue",
    "defer",       "else",        "enum",      "errdefer",
    "error",       "export",      "extern",    "fn",
    "for",         "if",          "inline",    "linksection",
    "noalias",     "nosuspend",   "opaque",    "or",
    "orelse",      "packed",      "pub",       "resume",
    "return",      "struct",      "suspend",   "switch",
    "test",        "threadlocal", "try",       "union",
    "unreachable", "var",         "volatile",  "while",
};

const zig_types = [_][]const u8{
    "bool", "comptime_float", "comptime_int", "f128",      "f16",       "f32",
    "f64",  "f80",            "i128",         "i16",       "i32",       "i64",
    "i8",   "isize",          "noreturn",     "null",      "type",      "u128",
    "u16",  "u32",            "u64",          "u8",        "undefined", "usize",
    "void", "anyerror",       "anyframe",     "anyopaque", "anytype",
};

const swift_keywords = [_][]const u8{
    "as",       "associatedtype", "break",       "case",
    "catch",    "class",          "continue",    "default",
    "defer",    "deinit",         "do",          "else",
    "enum",     "extension",      "fallthrough", "fileprivate",
    "for",      "func",           "guard",       "if",
    "import",   "in",             "init",        "inout",
    "internal", "is",             "let",         "open",
    "operator", "private",        "protocol",    "public",
    "repeat",   "rethrows",       "return",      "self",
    "Self",     "static",         "struct",      "subscript",
    "super",    "switch",         "throw",       "throws",
    "try",      "typealias",      "var",         "where",
    "while",
};

const swift_types = [_][]const u8{
    "Any",    "Array", "Bool",     "Character", "Dictionary",
    "Double", "Float", "Int",      "Int8",      "Int16",
    "Int32",  "Int64", "Optional", "Set",       "String",
    "UInt",   "UInt8", "UInt16",   "UInt32",    "UInt64",
    "Void",   "nil",   "true",     "false",
};

const c_keywords = [_][]const u8{
    "auto",      "break",    "case",      "const",
    "continue",  "default",  "do",        "else",
    "enum",      "extern",   "for",       "goto",
    "if",        "inline",   "register",  "restrict",
    "return",    "sizeof",   "static",    "struct",
    "switch",    "typedef",  "union",     "volatile",
    "while",     "class",    "namespace", "template",
    "public",    "private",  "protected", "virtual",
    "override",  "new",      "delete",    "throw",
    "try",       "catch",    "using",     "nullptr",
    "constexpr", "noexcept",
};

const c_types = [_][]const u8{
    "bool",      "char",     "double",   "float",    "int",
    "long",      "short",    "signed",   "unsigned", "void",
    "int8_t",    "int16_t",  "int32_t",  "int64_t",  "uint8_t",
    "uint16_t",  "uint32_t", "uint64_t", "size_t",   "ssize_t",
    "ptrdiff_t", "NULL",     "true",     "false",    "string",
};

const python_keywords = [_][]const u8{
    "False",   "None",     "True",     "and",
    "as",      "assert",   "async",    "await",
    "break",   "class",    "continue", "def",
    "del",     "elif",     "else",     "except",
    "finally", "for",      "from",     "global",
    "if",      "import",   "in",       "is",
    "lambda",  "nonlocal", "not",      "or",
    "pass",    "raise",    "return",   "try",
    "while",   "with",     "yield",
};

const python_types = [_][]const u8{
    "int",  "float",  "str",       "bool", "bytes",
    "list", "tuple",  "dict",      "set",  "frozenset",
    "type", "object", "Exception", "None",
};

const js_keywords = [_][]const u8{
    "async",    "await",      "break",    "case",
    "catch",    "class",      "const",    "continue",
    "debugger", "default",    "delete",   "do",
    "else",     "export",     "extends",  "finally",
    "for",      "function",   "if",       "import",
    "in",       "instanceof", "let",      "new",
    "of",       "return",     "static",   "super",
    "switch",   "this",       "throw",    "try",
    "typeof",   "var",        "void",     "while",
    "with",     "yield",      "from",     "as",
    "type",     "interface",  "enum",     "implements",
    "declare",  "abstract",   "readonly",
};

const js_types = [_][]const u8{
    "boolean", "number", "string",    "symbol",
    "bigint",  "any",    "unknown",   "never",
    "void",    "null",   "undefined", "object",
    "true",    "false",  "Array",     "Promise",
    "Map",     "Set",
};

const rust_keywords = [_][]const u8{
    "as",     "async",       "await",  "break",
    "const",  "continue",    "crate",  "dyn",
    "else",   "enum",        "extern", "fn",
    "for",    "if",          "impl",   "in",
    "let",    "loop",        "match",  "mod",
    "move",   "mut",         "pub",    "ref",
    "return", "self",        "Self",   "static",
    "struct", "super",       "trait",  "type",
    "union",  "unsafe",      "use",    "where",
    "while",  "macro_rules",
};

const rust_types = [_][]const u8{
    "bool",   "char",   "f32",  "f64",
    "i8",     "i16",    "i32",  "i64",
    "i128",   "isize",  "str",  "u8",
    "u16",    "u32",    "u64",  "u128",
    "usize",  "String", "Vec",  "Box",
    "Option", "Result", "Some", "None",
    "Ok",     "Err",    "true", "false",
};

const go_keywords = [_][]const u8{
    "break",       "case",    "chan",   "const",
    "continue",    "default", "defer",  "else",
    "fallthrough", "for",     "func",   "go",
    "goto",        "if",      "import", "interface",
    "map",         "package", "range",  "return",
    "select",      "struct",  "switch", "type",
    "var",
};

const go_types = [_][]const u8{
    "bool",   "byte",    "complex64", "complex128",
    "error",  "float32", "float64",   "int",
    "int8",   "int16",   "int32",     "int64",
    "rune",   "string",  "uint",      "uint8",
    "uint16", "uint32",  "uint64",    "uintptr",
    "true",   "false",   "nil",       "iota",
    "append", "cap",     "close",     "copy",
    "delete", "imag",    "len",       "make",
    "new",    "panic",   "print",     "println",
    "real",   "recover",
};

const shell_keywords = [_][]const u8{
    "if",       "then",     "else",    "elif",
    "fi",       "case",     "esac",    "for",
    "while",    "until",    "do",      "done",
    "in",       "function", "select",  "time",
    "return",   "exit",     "export",  "local",
    "readonly", "declare",  "typeset", "unset",
    "source",   "alias",
};

const lua_keywords = [_][]const u8{
    "and",    "break", "do",     "else",
    "elseif", "end",   "for",    "function",
    "goto",   "if",    "in",     "local",
    "not",    "or",    "repeat", "return",
    "then",   "until", "while",
};

const lua_types = [_][]const u8{
    "nil",       "true",   "false",
    "self",      "string", "table",
    "math",      "io",     "os",
    "coroutine",
};

// ── Tests ──────────────────────────────────────────────────────

test "Lexer: zig keywords" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "const x: u32 = 42;", .{}, .zig);
    defer result.deinit();

    try std.testing.expect(result.tokens.len > 0);
    // "const" should be keyword
    try std.testing.expectEqual(TokenType.keyword, result.tokens[0].type);
    try std.testing.expectEqualStrings("const", "const x: u32 = 42;"[result.tokens[0].start .. result.tokens[0].start + result.tokens[0].len]);
}

test "Lexer: string literal" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "const s = \"hello\";", .{}, .zig);
    defer result.deinit();

    // Find the string token
    var found_string = false;
    for (result.tokens) |tok| {
        if (tok.type == .string) {
            const text = "const s = \"hello\";"[tok.start .. tok.start + tok.len];
            try std.testing.expectEqualStrings("\"hello\"", text);
            found_string = true;
            break;
        }
    }
    try std.testing.expect(found_string);
}

test "Lexer: line comment" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "x = 1; // comment", .{}, .zig);
    defer result.deinit();

    // Last token should be comment
    const last = result.tokens[result.tokens.len - 1];
    try std.testing.expectEqual(TokenType.comment, last.type);
}

test "Lexer: python hash comment" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "x = 1  # comment", .{}, .python);
    defer result.deinit();

    const last = result.tokens[result.tokens.len - 1];
    try std.testing.expectEqual(TokenType.comment, last.type);
}

test "Lexer: number literal" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "return 0xFF;", .{}, .zig);
    defer result.deinit();

    var found = false;
    for (result.tokens) |tok| {
        if (tok.type == .number) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Lexer: block comment spans lines" {
    const allocator = std.testing.allocator;
    var r1 = try tokenizeLine(allocator, "x = /* start", .{}, .c);
    defer r1.deinit();
    try std.testing.expect(r1.end_state.in_block_comment);

    var r2 = try tokenizeLine(allocator, "still comment */  y = 1;", r1.end_state, .c);
    defer r2.deinit();
    try std.testing.expect(!r2.end_state.in_block_comment);
    // First token should be comment
    try std.testing.expectEqual(TokenType.comment, r2.tokens[0].type);
}

test "Lexer: function detection" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "foo(bar)", .{}, .zig);
    defer result.deinit();

    try std.testing.expectEqual(TokenType.function, result.tokens[0].type);
}

test "Lexer: attribute" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "@intCast(x)", .{}, .zig);
    defer result.deinit();

    try std.testing.expectEqual(TokenType.attribute, result.tokens[0].type);
}

test "Lexer: type keyword" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "var x: u32 = 0;", .{}, .zig);
    defer result.deinit();

    var found = false;
    for (result.tokens) |tok| {
        if (tok.type == .typ) {
            const text = "var x: u32 = 0;"[tok.start .. tok.start + tok.len];
            try std.testing.expectEqualStrings("u32", text);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Lexer: operators and punctuation" {
    const allocator = std.testing.allocator;
    var result = try tokenizeLine(allocator, "a + b;", .{}, .zig);
    defer result.deinit();

    var found_op = false;
    var found_punc = false;
    for (result.tokens) |tok| {
        if (tok.type == .operator) found_op = true;
        if (tok.type == .punctuation) found_punc = true;
    }
    try std.testing.expect(found_op);
    try std.testing.expect(found_punc);
}
