#ifndef MATCHA_H
#define MATCHA_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Opaque handles ─────────────────────────────────────────────
typedef struct matcha_config_s* matcha_config_t;
typedef struct matcha_editor_s* matcha_editor_t;

// ── Input structs ──────────────────────────────────────────────
typedef struct {
    uint16_t keycode;
    uint32_t modifiers;
    const char* text;
    uint32_t text_len;
} matcha_input_key_s;

// Modifier flags
#define MATCHA_MOD_SHIFT   (1u << 0)
#define MATCHA_MOD_CTRL    (1u << 1)
#define MATCHA_MOD_ALT     (1u << 2)
#define MATCHA_MOD_SUPER   (1u << 3)

// ── Render structs ─────────────────────────────────────────────
typedef struct {
    float x, y, w, h;
    uint32_t fg;       // 0xRRGGBBAA
    uint32_t bg;       // 0xRRGGBBAA
    uint32_t glyph_index;
    float uv_x, uv_y, uv_w, uv_h;
    uint8_t style;     // 0=normal, 1=bold, 2=italic
} matcha_render_cell_s;

typedef struct {
    float x, y, w, h;
    uint32_t color;    // 0xRRGGBBAA
    uint8_t style;     // 0=block, 1=beam, 2=underline
} matcha_render_cursor_s;

typedef struct {
    float x, y, w, h;
    uint32_t color;    // 0xRRGGBBAA
} matcha_render_rect_s;

// ── Editor state info ──────────────────────────────────────────
typedef struct {
    uint32_t cursor_line;   // 1-based
    uint32_t cursor_col;    // 1-based
    uint32_t total_lines;
    bool modified;
    const char* filename;   // null if untitled; borrowed pointer, valid until next editor mutation
} matcha_editor_info_s;

// ── Lifecycle ──────────────────────────────────────────────────
void matcha_init(void);

// ── Config ─────────────────────────────────────────────────────
matcha_config_t matcha_config_new(void);
void matcha_config_free(matcha_config_t cfg);
bool matcha_config_load_file(matcha_config_t cfg, const char* path);
const char* matcha_config_get_string(matcha_config_t cfg, const char* key);
int64_t matcha_config_get_int(matcha_config_t cfg, const char* key);
bool matcha_config_get_bool(matcha_config_t cfg, const char* key);
double matcha_config_get_float(matcha_config_t cfg, const char* key);

// ── Editor ─────────────────────────────────────────────────────
matcha_editor_t matcha_editor_new(matcha_config_t cfg);
void matcha_editor_free(matcha_editor_t ed);

// File I/O
void matcha_editor_new_file(matcha_editor_t ed);
bool matcha_editor_open_file(matcha_editor_t ed, const char* path);
bool matcha_editor_save(matcha_editor_t ed);
bool matcha_editor_save_as(matcha_editor_t ed, const char* path);

// Error feedback (returns borrowed pointer to internal buffer)
const char* matcha_editor_get_last_error(matcha_editor_t ed);
void matcha_editor_clear_error(matcha_editor_t ed);

// Editing
void matcha_editor_insert(matcha_editor_t ed, const char* text, uint32_t len);
void matcha_editor_delete_backward(matcha_editor_t ed);
void matcha_editor_delete_forward(matcha_editor_t ed);
void matcha_editor_delete_word_backward(matcha_editor_t ed);
void matcha_editor_delete_word_forward(matcha_editor_t ed);
void matcha_editor_newline(matcha_editor_t ed);
void matcha_editor_toggle_comment(matcha_editor_t ed);
void matcha_editor_duplicate_line(matcha_editor_t ed);
void matcha_editor_move_line_up(matcha_editor_t ed);
void matcha_editor_move_line_down(matcha_editor_t ed);

// Tab / Indent
void matcha_editor_insert_tab(matcha_editor_t ed);
void matcha_editor_dedent(matcha_editor_t ed);

// Movement
void matcha_editor_move_left(matcha_editor_t ed);
void matcha_editor_move_right(matcha_editor_t ed);
void matcha_editor_move_up(matcha_editor_t ed);
void matcha_editor_move_down(matcha_editor_t ed);
void matcha_editor_move_line_start(matcha_editor_t ed);
void matcha_editor_move_line_end(matcha_editor_t ed);
void matcha_editor_move_start(matcha_editor_t ed);
void matcha_editor_move_end(matcha_editor_t ed);
void matcha_editor_move_page_up(matcha_editor_t ed);
void matcha_editor_move_page_down(matcha_editor_t ed);
void matcha_editor_move_word_left(matcha_editor_t ed);
void matcha_editor_move_word_right(matcha_editor_t ed);

// Selection
void matcha_editor_select_left(matcha_editor_t ed);
void matcha_editor_select_right(matcha_editor_t ed);
void matcha_editor_select_up(matcha_editor_t ed);
void matcha_editor_select_down(matcha_editor_t ed);
void matcha_editor_select_line_start(matcha_editor_t ed);
void matcha_editor_select_line_end(matcha_editor_t ed);
void matcha_editor_select_all(matcha_editor_t ed);
void matcha_editor_select_start(matcha_editor_t ed);
void matcha_editor_select_end(matcha_editor_t ed);
void matcha_editor_select_word_left(matcha_editor_t ed);
void matcha_editor_select_word_right(matcha_editor_t ed);

// Clipboard
/// Returns a malloc'd string the caller must free with matcha_free_string, or NULL if no selection.
char* matcha_editor_get_selection_text(matcha_editor_t ed);
void matcha_editor_paste(matcha_editor_t ed, const char* text, uint32_t len);

// Undo/Redo
void matcha_editor_undo(matcha_editor_t ed);
void matcha_editor_redo(matcha_editor_t ed);

// Input
bool matcha_editor_key_event(matcha_editor_t ed, matcha_input_key_s key);

// Viewport
void matcha_editor_set_viewport(matcha_editor_t ed,
                                 uint32_t width_px, uint32_t height_px,
                                 float cell_width, float cell_height);
void matcha_editor_scroll(matcha_editor_t ed, float dx, float dy);
void matcha_editor_click(matcha_editor_t ed, float x, float y, bool extend);
void matcha_editor_double_click(matcha_editor_t ed, float x, float y);
void matcha_editor_triple_click(matcha_editor_t ed, float x, float y);
float matcha_editor_get_scroll_y(matcha_editor_t ed);

// Find & Replace
bool matcha_editor_find_next(matcha_editor_t ed, const char* query, uint32_t len);
bool matcha_editor_find_prev(matcha_editor_t ed, const char* query, uint32_t len);
bool matcha_editor_find_next_with_options(matcha_editor_t ed, const char* query, uint32_t len,
                                           bool case_sensitive, bool whole_word);
bool matcha_editor_find_prev_with_options(matcha_editor_t ed, const char* query, uint32_t len,
                                           bool case_sensitive, bool whole_word);
bool matcha_editor_replace_next(matcha_editor_t ed, const char* query, uint32_t q_len,
                                 const char* replacement, uint32_t r_len);
bool matcha_editor_replace_next_with_options(matcha_editor_t ed, const char* query, uint32_t q_len,
                                              const char* replacement, uint32_t r_len,
                                              bool case_sensitive, bool whole_word);
uint32_t matcha_editor_replace_all(matcha_editor_t ed, const char* query, uint32_t q_len,
                                    const char* replacement, uint32_t r_len);
uint32_t matcha_editor_replace_all_with_options(matcha_editor_t ed, const char* query, uint32_t q_len,
                                                 const char* replacement, uint32_t r_len,
                                                 bool case_sensitive, bool whole_word);

// Bracket highlights
const matcha_render_rect_s* matcha_editor_get_bracket_highlights(matcha_editor_t ed, uint32_t* count);

// Render
void matcha_editor_prepare_render(matcha_editor_t ed);

const matcha_render_cell_s* matcha_editor_get_cells(matcha_editor_t ed, uint32_t* count);
const matcha_render_cursor_s* matcha_editor_get_cursors(matcha_editor_t ed, uint32_t* count);
const matcha_render_rect_s* matcha_editor_get_selections(matcha_editor_t ed, uint32_t* count);
const matcha_render_rect_s* matcha_editor_get_line_number_cells(matcha_editor_t ed, uint32_t* count);

const uint8_t* matcha_editor_get_atlas_data(matcha_editor_t ed,
                                             uint32_t* width, uint32_t* height);
bool matcha_editor_atlas_needs_update(matcha_editor_t ed);
void matcha_editor_atlas_clear_dirty(matcha_editor_t ed);

// Info
matcha_editor_info_s matcha_editor_get_info(matcha_editor_t ed);

// Memory management
void matcha_editor_free_string(char* str);   // free strings from matcha_editor_get_selection_text
void matcha_free_string(char* str);          // generic string free (also works for config strings)

#ifdef __cplusplus
}
#endif

#endif // MATCHA_H
