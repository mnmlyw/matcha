pub const TokenType = enum {
    normal,
    keyword,
    string,
    comment,
    number,
    typ,
    function,
    operator,
    punctuation,
    attribute,
};

/// Cyberdream syntax theme. All colors are RGBA u32.
pub const Theme = struct {
    normal: u32 = 0xFFFFFFFF, // fg
    keyword: u32 = 0xFFBD5EFF, // orange
    string: u32 = 0x5EFF6CFF, // green
    comment: u32 = 0x7B8496FF, // grey
    number: u32 = 0xFFBD5EFF, // orange
    typ: u32 = 0xBD5EFFFF, // purple
    function: u32 = 0x5EA1FFFF, // blue
    operator: u32 = 0xBD5EFFFF, // purple
    punctuation: u32 = 0xFFFFFFFF, // fg
    attribute: u32 = 0x5EF1FFFF, // cyan

    pub fn colorFor(self: *const Theme, token: TokenType) u32 {
        return switch (token) {
            .normal => self.normal,
            .keyword => self.keyword,
            .string => self.string,
            .comment => self.comment,
            .number => self.number,
            .typ => self.typ,
            .function => self.function,
            .operator => self.operator,
            .punctuation => self.punctuation,
            .attribute => self.attribute,
        };
    }
};
