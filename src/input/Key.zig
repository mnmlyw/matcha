/// Platform-agnostic key representation.
pub const Key = struct {
    keycode: u16 = 0,
    modifiers: Modifiers = .{},
    text: ?[]const u8 = null,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _padding: u4 = 0,

    pub fn toU32(self: Modifiers) u32 {
        var result: u32 = 0;
        if (self.shift) result |= 1;
        if (self.ctrl) result |= 2;
        if (self.alt) result |= 4;
        if (self.super) result |= 8;
        return result;
    }

    pub fn fromU32(val: u32) Modifiers {
        return .{
            .shift = (val & 1) != 0,
            .ctrl = (val & 2) != 0,
            .alt = (val & 4) != 0,
            .super = (val & 8) != 0,
        };
    }
};
