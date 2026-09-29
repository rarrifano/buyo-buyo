/*
 * gfx: SDL renderer wrapper exposed to Lua.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * All coordinates are in the fixed 1280x720 logical space; SDL letterboxes
 * and scales to the real window. Textures and primitives are tinted by the
 * current color (gfx.color) and use the current blend mode (gfx.blend).
 */
#include "engine.h"
#include "font8x8.h"
#include "stb_image.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TEX_MT "buyo.Texture"
#define PI_D 3.14159265358979323846

typedef struct {
    SDL_Texture *tex;
    int w, h;
} Tex;

static SDL_Renderer *R;
static SDL_Texture *font_tex;
#define NCIRCLES 5
static SDL_Texture *circle_tex[NCIRCLES];
static const int circle_size[NCIRCLES] = {16, 32, 64, 128, 256};

static SDL_Color cur = {255, 255, 255, 255};
static SDL_BlendMode cur_blend = SDL_BLENDMODE_BLEND;
static float off_x, off_y;
static char shot_path[1024];

/* ------------------------------------------------------------------ */
/* textures                                                            */
/* ------------------------------------------------------------------ */

SDL_Texture *gfx_create_texture_rgba(const unsigned char *rgba, int w, int h, bool linear) {
    SDL_Texture *t = SDL_CreateTexture(R, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, w, h);
    if (!t) {
        SDL_Log("SDL_CreateTexture(%dx%d) failed: %s", w, h, SDL_GetError());
        return NULL;
    }
    SDL_UpdateTexture(t, NULL, rgba, w * 4);
    SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
    SDL_SetTextureScaleMode(t, linear ? SDL_ScaleModeLinear : SDL_ScaleModeNearest);
    return t;
}

/* Give fully transparent pixels the average color of their opaque
 * neighbours, so bilinear filtering does not pull in dark fringes. */
void gfx_bleed_rgba(unsigned char *px, int w, int h) {
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned char *o = &px[((size_t)y * w + x) * 4];
            if (o[3] != 0)
                continue;
            int sr = 0, sg = 0, sb = 0, cnt = 0;
            for (int yy = y - 1; yy <= y + 1; yy++) {
                for (int xx = x - 1; xx <= x + 1; xx++) {
                    if (xx < 0 || yy < 0 || xx >= w || yy >= h)
                        continue;
                    const unsigned char *q = &px[((size_t)yy * w + xx) * 4];
                    if (q[3] == 0)
                        continue;
                    sr += q[0];
                    sg += q[1];
                    sb += q[2];
                    cnt++;
                }
            }
            if (cnt) {
                o[0] = (unsigned char)(sr / cnt);
                o[1] = (unsigned char)(sg / cnt);
                o[2] = (unsigned char)(sb / cnt);
            }
        }
    }
}

/* decode an image file (PNG/JPG/BMP/TGA) to RGBA8; free with stbi_image_free */
unsigned char *gfx_decode_file(const char *path, int *w, int *h, char *err, size_t errlen) {
    size_t len = 0;
    unsigned char *file = (unsigned char *)fs_read(path, &len);
    if (!file) {
        snprintf(err, errlen, "cannot read %s", path);
        return NULL;
    }
    int n = 0;
    unsigned char *px = stbi_load_from_memory(file, (int)len, w, h, &n, 4);
    free(file);
    if (!px)
        snprintf(err, errlen, "%s: %s", path, stbi_failure_reason());
    return px;
}

static int tex_gc(lua_State *L) {
    Tex *t = (Tex *)luaL_checkudata(L, 1, TEX_MT);
    if (t->tex)
        SDL_DestroyTexture(t->tex);
    t->tex = NULL;
    return 0;
}

static int tex_size(lua_State *L) {
    Tex *t = (Tex *)luaL_checkudata(L, 1, TEX_MT);
    lua_pushinteger(L, t->w);
    lua_pushinteger(L, t->h);
    return 2;
}

/* tex:filter("linear" | "nearest") */
static int tex_filter(lua_State *L) {
    Tex *t = (Tex *)luaL_checkudata(L, 1, TEX_MT);
    const char *m = luaL_checkstring(L, 2);
    if (t->tex)
        SDL_SetTextureScaleMode(t->tex,
                                strcmp(m, "nearest") ? SDL_ScaleModeLinear : SDL_ScaleModeNearest);
    lua_settop(L, 1);
    return 1;
}

static int tex_tostring(lua_State *L) {
    Tex *t = (Tex *)luaL_checkudata(L, 1, TEX_MT);
    lua_pushfstring(L, "Texture(%dx%d)", t->w, t->h);
    return 1;
}

void gfx_push_texture(lua_State *L, SDL_Texture *tex, int w, int h) {
    Tex *t = (Tex *)lua_newuserdatauv(L, sizeof *t, 0);
    t->tex = tex;
    t->w = w;
    t->h = h;
    luaL_setmetatable(L, TEX_MT);
}

static Tex *check_tex(lua_State *L, int i) {
    return (Tex *)luaL_checkudata(L, i, TEX_MT);
}

static void tex_state(SDL_Texture *t) {
    SDL_SetTextureColorMod(t, cur.r, cur.g, cur.b);
    SDL_SetTextureAlphaMod(t, cur.a);
    SDL_SetTextureBlendMode(t, cur_blend);
}

static void prim_state(void) {
    SDL_SetRenderDrawColor(R, cur.r, cur.g, cur.b, cur.a);
    SDL_SetRenderDrawBlendMode(R, cur_blend);
}

/* ------------------------------------------------------------------ */
/* built-in assets: font atlas + anti-aliased circles                   */
/* ------------------------------------------------------------------ */

static SDL_Texture *make_font(void) {
    const int w = 128, h = 64; /* 16 x 8 glyphs */
    unsigned char *px = (unsigned char *)calloc((size_t)w * h * 4, 1);
    if (!px)
        return NULL;
    for (int ch = 0; ch < 128; ch++) {
        int gx = (ch % 16) * 8, gy = (ch / 16) * 8;
        for (int row = 0; row < 8; row++) {
            unsigned bits = font8x8[ch][row];
            for (int col = 0; col < 8; col++) {
                if (bits & (1u << col)) {
                    unsigned char *p = px + ((size_t)(gy + row) * w + gx + col) * 4;
                    p[0] = p[1] = p[2] = p[3] = 255;
                }
            }
        }
    }
    SDL_Texture *t = gfx_create_texture_rgba(px, w, h, false);
    free(px);
    return t;
}

static SDL_Texture *make_circle(int size) {
    unsigned char *px = (unsigned char *)malloc((size_t)size * size * 4);
    if (!px)
        return NULL;
    float c = size * 0.5f, r = size * 0.5f - 0.5f;
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            float dx = x + 0.5f - c, dy = y + 0.5f - c;
            float a = r - sqrtf(dx * dx + dy * dy) + 0.5f;
            a = a < 0.f ? 0.f : a > 1.f ? 1.f : a;
            unsigned char *p = px + ((size_t)y * size + x) * 4;
            p[0] = p[1] = p[2] = 255;
            p[3] = (unsigned char)(a * 255.f + 0.5f);
        }
    }
    SDL_Texture *t = gfx_create_texture_rgba(px, size, size, true);
    free(px);
    return t;
}

bool gfx_init(SDL_Window *win, bool software, bool vsync) {
    Uint32 flags = software ? SDL_RENDERER_SOFTWARE : SDL_RENDERER_ACCELERATED;
    if (vsync)
        flags |= SDL_RENDERER_PRESENTVSYNC;
    R = SDL_CreateRenderer(win, -1, flags);
    if (!R && !software) {
        SDL_Log("accelerated renderer unavailable (%s), falling back to software", SDL_GetError());
        R = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!R) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        return false;
    }
    SDL_RendererInfo info;
    if (SDL_GetRendererInfo(R, &info) == 0)
        SDL_Log("video: %s, renderer: %s", SDL_GetCurrentVideoDriver(), info.name);

    SDL_RenderSetLogicalSize(R, GAME_W, GAME_H);
    SDL_SetRenderDrawBlendMode(R, SDL_BLENDMODE_BLEND);

    font_tex = make_font();
    for (int i = 0; i < NCIRCLES; i++)
        circle_tex[i] = make_circle(circle_size[i]);
    return font_tex != NULL;
}

void gfx_shutdown(void) {
    for (int i = 0; i < NCIRCLES; i++) {
        if (circle_tex[i])
            SDL_DestroyTexture(circle_tex[i]);
        circle_tex[i] = NULL;
    }
    if (font_tex)
        SDL_DestroyTexture(font_tex);
    font_tex = NULL;
    if (R)
        SDL_DestroyRenderer(R);
    R = NULL;
}

void gfx_reset_state(void) {
    cur = (SDL_Color){255, 255, 255, 255};
    cur_blend = SDL_BLENDMODE_BLEND;
    off_x = off_y = 0.f;
    if (R)
        SDL_RenderSetClipRect(R, NULL);
}

/* ------------------------------------------------------------------ */
/* text                                                                */
/* ------------------------------------------------------------------ */

static void draw_text(const char *s, float x, float y, float scale, int align) {
    if (!font_tex)
        return;
    tex_state(font_tex);
    float gw = 8.f * scale;
    const char *line = s;
    float cy = y;
    for (;;) {
        const char *end = strchr(line, '\n');
        size_t n = end ? (size_t)(end - line) : strlen(line);
        float w = (float)n * gw;
        float cx = x - (align == 1 ? w * 0.5f : align == 2 ? w : 0.f);
        for (size_t i = 0; i < n; i++) {
            unsigned c = (unsigned char)line[i];
            if (c >= 128)
                c = '?';
            if (c != ' ') {
                SDL_Rect src = {(int)(c % 16) * 8, (int)(c / 16) * 8, 8, 8};
                SDL_FRect dst = {cx + off_x, cy + off_y, gw, gw};
                SDL_RenderCopyF(R, font_tex, &src, &dst);
            }
            cx += gw;
        }
        if (!end)
            break;
        line = end + 1;
        cy += 10.f * scale;
    }
}

static float text_width(const char *s, float scale) {
    size_t best = 0, n = 0;
    for (; *s; s++) {
        if (*s == '\n') {
            if (n > best)
                best = n;
            n = 0;
        } else
            n++;
    }
    if (n > best)
        best = n;
    return (float)best * 8.f * scale;
}

/* ------------------------------------------------------------------ */
/* frame end / screenshots / error screen                              */
/* ------------------------------------------------------------------ */

void gfx_request_screenshot(const char *path) {
    snprintf(shot_path, sizeof shot_path, "%s", path);
}

static void save_screenshot(const char *path) {
    int w, h;
    if (SDL_GetRendererOutputSize(R, &w, &h) != 0)
        return;
    SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!s)
        return;
    if (SDL_RenderReadPixels(R, NULL, SDL_PIXELFORMAT_ARGB8888, s->pixels, s->pitch) == 0) {
        if (SDL_SaveBMP(s, path) != 0)
            SDL_Log("screenshot %s failed: %s", path, SDL_GetError());
    } else {
        SDL_Log("SDL_RenderReadPixels failed: %s", SDL_GetError());
    }
    SDL_FreeSurface(s);
}

void gfx_end_frame(void) {
    if (shot_path[0]) {
        save_screenshot(shot_path);
        shot_path[0] = '\0';
    }
    SDL_RenderPresent(R);
}

void gfx_draw_error(const char *msg) {
    gfx_reset_state();
    SDL_SetRenderDrawColor(R, 36, 8, 20, 255);
    SDL_RenderClear(R);
    cur = (SDL_Color){255, 90, 110, 255};
    draw_text("SCRIPT ERROR", 40, 30, 4, 0);
    cur = (SDL_Color){255, 240, 240, 255};

    /* word-wrap-less hard wrap at 76 columns, scale 2 (16 px glyphs) */
    char line[80];
    int n = 0;
    float y = 90;
    for (const char *p = msg;; p++) {
        char c = *p;
        if (c == '\t')
            c = ' ';
        if (c == '\0' || c == '\n' || n == 76) {
            line[n] = '\0';
            draw_text(line, 40, y, 2, 0);
            y += 20;
            n = 0;
            if (c == '\0' || y > GAME_H - 80)
                break;
            if (c == '\n')
                continue;
        }
        line[n++] = c;
    }
    cur = (SDL_Color){255, 220, 120, 255};
    draw_text("F5: reload scripts    ESC: quit", 40, GAME_H - 50, 2, 0);
}

/* ------------------------------------------------------------------ */
/* Lua API                                                             */
/* ------------------------------------------------------------------ */

static Uint8 u8(lua_Number v) {
    return v <= 0 ? 0 : v >= 255 ? 255 : (Uint8)(v + 0.5);
}

static int l_clear(lua_State *L) {
    SDL_SetRenderDrawColor(R, u8(luaL_optnumber(L, 1, 0)), u8(luaL_optnumber(L, 2, 0)),
                           u8(luaL_optnumber(L, 3, 0)), 255);
    SDL_RenderClear(R);
    return 0;
}

/* gfx.color(r, g, b [, a])  -- 0..255 */
static int l_color(lua_State *L) {
    cur.r = u8(luaL_checknumber(L, 1));
    cur.g = u8(luaL_checknumber(L, 2));
    cur.b = u8(luaL_checknumber(L, 3));
    cur.a = u8(luaL_optnumber(L, 4, 255));
    return 0;
}

/* gfx.blend("alpha" | "add" | "mul" | "none") */
static int l_blend(lua_State *L) {
    const char *m = luaL_optstring(L, 1, "alpha");
    if (!strcmp(m, "add"))
        cur_blend = SDL_BLENDMODE_ADD;
    else if (!strcmp(m, "mul"))
        cur_blend = SDL_BLENDMODE_MOD;
    else if (!strcmp(m, "none"))
        cur_blend = SDL_BLENDMODE_NONE;
    else
        cur_blend = SDL_BLENDMODE_BLEND;
    return 0;
}

/* gfx.offset(x, y) -> previous x, y   (global translation, e.g. screen shake) */
static int l_offset(lua_State *L) {
    float px = off_x, py = off_y;
    if (lua_gettop(L) >= 2) {
        off_x = (float)luaL_checknumber(L, 1);
        off_y = (float)luaL_checknumber(L, 2);
    }
    lua_pushnumber(L, px);
    lua_pushnumber(L, py);
    return 2;
}

/* gfx.clip(x, y, w, h) / gfx.clip() */
static int l_clip(lua_State *L) {
    if (lua_gettop(L) < 4) {
        SDL_RenderSetClipRect(R, NULL);
        return 0;
    }
    float x = (float)luaL_checknumber(L, 1) + off_x, y = (float)luaL_checknumber(L, 2) + off_y;
    float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
    SDL_Rect rc = {(int)floorf(x), (int)floorf(y), (int)ceilf(w), (int)ceilf(h)};
    if (rc.w < 0)
        rc.w = 0;
    if (rc.h < 0)
        rc.h = 0;
    SDL_RenderSetClipRect(R, &rc);
    return 0;
}

static int l_rect(lua_State *L) {
    SDL_FRect rc = {(float)luaL_checknumber(L, 1) + off_x, (float)luaL_checknumber(L, 2) + off_y,
                    (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4)};
    prim_state();
    SDL_RenderFillRectF(R, &rc);
    return 0;
}

/* gfx.rect_line(x, y, w, h [, thickness])  -- border drawn inside the rect */
static int l_rect_line(lua_State *L) {
    float x = (float)luaL_checknumber(L, 1) + off_x, y = (float)luaL_checknumber(L, 2) + off_y;
    float w = (float)luaL_checknumber(L, 3), h = (float)luaL_checknumber(L, 4);
    float t = (float)luaL_optnumber(L, 5, 1);
    if (t * 2 > w || t * 2 > h) {
        SDL_FRect all = {x, y, w, h};
        prim_state();
        SDL_RenderFillRectF(R, &all);
        return 0;
    }
    SDL_FRect r[4] = {
        {x, y, w, t},
        {x, y + h - t, w, t},
        {x, y + t, t, h - 2 * t},
        {x + w - t, y + t, t, h - 2 * t},
    };
    prim_state();
    SDL_RenderFillRectsF(R, r, 4);
    return 0;
}

static int l_line(lua_State *L) {
    prim_state();
    SDL_RenderDrawLineF(
        R, (float)luaL_checknumber(L, 1) + off_x, (float)luaL_checknumber(L, 2) + off_y,
        (float)luaL_checknumber(L, 3) + off_x, (float)luaL_checknumber(L, 4) + off_y);
    return 0;
}

/* gfx.circle(x, y, r)  -- filled, anti-aliased */
static int l_circle(lua_State *L) {
    float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
    float r = (float)luaL_checknumber(L, 3);
    if (r <= 0.f)
        return 0;
    float d = r * 2.f;
    int k = NCIRCLES - 1;
    for (int i = 0; i < NCIRCLES; i++) {
        if (circle_size[i] >= d) {
            k = i;
            break;
        }
    }
    SDL_Texture *t = circle_tex[k];
    if (!t)
        return 0;
    tex_state(t);
    SDL_FRect dst = {x - r + off_x, y - r + off_y, d, d};
    SDL_RenderCopyF(R, t, NULL, &dst);
    return 0;
}

/* gfx.draw(tex, x, y [, angle, sx, sy, ox, oy])
 * (ox, oy) is the texture-space origin placed at (x, y); rotation (radians)
 * and scale are applied around it. Negative scales mirror. */
static int l_draw(lua_State *L) {
    Tex *t = check_tex(L, 1);
    if (!t->tex)
        return 0;
    float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
    double ang = luaL_optnumber(L, 4, 0.0);
    float sx = (float)luaL_optnumber(L, 5, 1.0);
    float sy = (float)luaL_optnumber(L, 6, sx);
    float ox = (float)luaL_optnumber(L, 7, 0.0), oy = (float)luaL_optnumber(L, 8, 0.0);
    SDL_RendererFlip flip = SDL_FLIP_NONE;
    if (sx < 0.f) {
        sx = -sx;
        ox = (float)t->w - ox;
        flip |= SDL_FLIP_HORIZONTAL;
    }
    if (sy < 0.f) {
        sy = -sy;
        oy = (float)t->h - oy;
        flip |= SDL_FLIP_VERTICAL;
    }
    SDL_FRect dst = {x + off_x - ox * sx, y + off_y - oy * sy, (float)t->w * sx, (float)t->h * sy};
    tex_state(t->tex);
    if (ang == 0.0 && flip == SDL_FLIP_NONE) {
        SDL_RenderCopyF(R, t->tex, NULL, &dst);
    } else {
        SDL_FPoint c = {ox * sx, oy * sy};
        SDL_RenderCopyExF(R, t->tex, NULL, &dst, ang * 180.0 / PI_D, &c, flip);
    }
    return 0;
}

/* gfx.drawq(tex, qx, qy, qw, qh, x, y [, angle, sx, sy, ox, oy])
 * Like gfx.draw but for the sub-rectangle (qx, qy, qw, qh) of the texture;
 * (ox, oy) is relative to that rectangle. */
static int l_drawq(lua_State *L) {
    Tex *t = check_tex(L, 1);
    if (!t->tex)
        return 0;
    SDL_Rect src = {(int)luaL_checknumber(L, 2), (int)luaL_checknumber(L, 3),
                    (int)luaL_checknumber(L, 4), (int)luaL_checknumber(L, 5)};
    float x = (float)luaL_checknumber(L, 6), y = (float)luaL_checknumber(L, 7);
    double ang = luaL_optnumber(L, 8, 0.0);
    float sx = (float)luaL_optnumber(L, 9, 1.0);
    float sy = (float)luaL_optnumber(L, 10, sx);
    float ox = (float)luaL_optnumber(L, 11, 0.0), oy = (float)luaL_optnumber(L, 12, 0.0);
    SDL_RendererFlip flip = SDL_FLIP_NONE;
    if (sx < 0.f) {
        sx = -sx;
        ox = (float)src.w - ox;
        flip |= SDL_FLIP_HORIZONTAL;
    }
    if (sy < 0.f) {
        sy = -sy;
        oy = (float)src.h - oy;
        flip |= SDL_FLIP_VERTICAL;
    }
    SDL_FRect dst = {x + off_x - ox * sx, y + off_y - oy * sy, (float)src.w * sx,
                     (float)src.h * sy};
    SDL_FPoint c = {ox * sx, oy * sy};
    tex_state(t->tex);
    SDL_RenderCopyExF(R, t->tex, &src, &dst, ang * 180.0 / PI_D, &c, flip);
    return 0;
}

/* gfx.load(path [, "linear"|"nearest"]) -> Texture, w, h | nil, err */
static int l_load(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    const char *filter = luaL_optstring(L, 2, "linear");
    int w = 0, h = 0;
    char err[512];
    unsigned char *px = gfx_decode_file(path, &w, &h, err, sizeof err);
    if (!px) {
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
    gfx_bleed_rgba(px, w, h);
    SDL_Texture *t = gfx_create_texture_rgba(px, w, h, strcmp(filter, "nearest") != 0);
    stbi_image_free(px);
    if (!t) {
        lua_pushnil(L);
        lua_pushfstring(L, "texture creation failed: %s", SDL_GetError());
        return 2;
    }
    gfx_push_texture(L, t, w, h);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    return 3;
}

/* gfx.stretch(tex, x, y, w, h) */
static int l_stretch(lua_State *L) {
    Tex *t = check_tex(L, 1);
    if (!t->tex)
        return 0;
    SDL_FRect dst = {(float)luaL_checknumber(L, 2) + off_x, (float)luaL_checknumber(L, 3) + off_y,
                     (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5)};
    tex_state(t->tex);
    SDL_RenderCopyF(R, t->tex, NULL, &dst);
    return 0;
}

static int align_arg(lua_State *L, int i) {
    const char *a = luaL_optstring(L, i, "left");
    return a[0] == 'c' ? 1 : a[0] == 'r' ? 2 : 0;
}

/* gfx.text(str, x, y [, scale [, "left"|"center"|"right"]]) */
static int l_text(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    draw_text(s, (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3),
              (float)luaL_optnumber(L, 4, 1.0), align_arg(L, 5));
    return 0;
}

static int l_text_width(lua_State *L) {
    lua_pushnumber(L, text_width(luaL_checkstring(L, 1), (float)luaL_optnumber(L, 2, 1.0)));
    return 1;
}

static int l_size(lua_State *L) {
    lua_pushinteger(L, GAME_W);
    lua_pushinteger(L, GAME_H);
    return 2;
}

static int l_screenshot(lua_State *L) {
    gfx_request_screenshot(luaL_checkstring(L, 1));
    return 0;
}

int luaopen_gfx(lua_State *L) {
    static const luaL_Reg tex_methods[] = {
        {"size", tex_size},
        {"filter", tex_filter},
        {NULL, NULL},
    };
    luaL_newmetatable(L, TEX_MT);
    lua_pushcfunction(L, tex_gc);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, tex_tostring);
    lua_setfield(L, -2, "__tostring");
    luaL_newlib(L, tex_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    static const luaL_Reg fns[] = {
        {"clear", l_clear},
        {"color", l_color},
        {"blend", l_blend},
        {"offset", l_offset},
        {"clip", l_clip},
        {"rect", l_rect},
        {"rect_line", l_rect_line},
        {"line", l_line},
        {"circle", l_circle},
        {"draw", l_draw},
        {"drawq", l_drawq},
        {"stretch", l_stretch},
        {"load", l_load},
        {"text", l_text},
        {"text_width", l_text_width},
        {"size", l_size},
        {"screenshot", l_screenshot},
        {NULL, NULL},
    };
    luaL_newlib(L, fns);
    canvas_register(L, lua_gettop(L));
    return 1;
}
