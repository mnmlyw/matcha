/// Per-cell render data, matches matcha_render_cell_s in C ABI.
pub const RenderCell = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    fg: u32 = 0xFFFFFFFF,
    bg: u32 = 0x00000000,
    glyph_index: u32 = 0,
    uv_x: f32 = 0,
    uv_y: f32 = 0,
    uv_w: f32 = 0,
    uv_h: f32 = 0,
    style: u8 = 0,
};

pub const RenderCursor = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    color: u32 = 0xFFFFFFFF,
    style: u8 = 0, // 0=block, 1=beam, 2=underline
};

pub const RenderRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    color: u32 = 0x00000000,
};
