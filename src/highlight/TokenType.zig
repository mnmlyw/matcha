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

/// Catppuccin Mocha–inspired syntax theme. All colors are RGBA u32.
pub const Theme = struct {
    normal: u32 = 0xCDD6F4FF, // text
    keyword: u32 = 0xCBA6F7FF, // mauve
    string: u32 = 0xA6E3A1FF, // green
    comment: u32 = 0x6C7086FF, // overlay0
    number: u32 = 0xFAB387FF, // peach
    typ: u32 = 0x89DCEBFF, // sky
    function: u32 = 0x89B4FAFF, // blue
    operator: u32 = 0x94E2D5FF, // teal
    punctuation: u32 = 0xBAC2DEFF, // subtext0
    attribute: u32 = 0xF9E2AFFF, // yellow

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
