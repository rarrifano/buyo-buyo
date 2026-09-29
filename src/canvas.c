/*
 * canvas: CPU-side RGBA images painted with anti-aliased signed-distance
 * shapes, then uploaded as textures. Content can paint sprites procedurally
 * (no image files needed), load/crop/compose PNGs, and export PNGs.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 *   local s = gfx.shape():circle(32, 32, 28):rect(0, 20, 32, 24)   -- union
 *   local img = gfx.image(64, 64)
 *   img:fill(s, r, g, b, a, { inset = 2, soft = 1, dx = 0, dy = 0, mode = "over" })
 *   local tex = img:texture()
 *
 * Shape ops: each primitive takes an optional trailing op "add" (union,
 * default), "sub" (subtract) or "and" (intersect), applied in order.
 * `inset` erodes (>0) or dilates (<0) the shape, `soft` is the edge width in
 * pixels (1 = crisp anti-aliasing, larger = feathered).
 *
 *   gfx.image_load(path) -> Image | nil, err    img:crop(x, y, w, h) -> Image
 *   img:blit(src, x, y)                         gfx.save_png(img, path) -> true | nil, err
 * (save_png is a gfx function, not an Image method, so sandboxed content
 *  that can paint images still cannot write files)
 */
#include "engine.h"
#include "stb_image.h"
#include "stb_image_write.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IMAGE_MT "buyo.Image"
#define SHAPE_MT "buyo.Shape"

typedef struct {
    int w, h;
    float *px; /* premultiplied RGBA, 0..1 */
} Image;

enum { PK_CIRCLE, PK_ELLIPSE, PK_RECT, PK_CAPSULE, PK_POLY };
enum { OP_UNION, OP_SUB, OP_AND };

typedef struct {
    int kind, op;
    float p[6];
    float *pts; /* polygon vertices x0,y0,x1,y1,... */
    int npts;
    float x0, y0, x1, y1; /* bounds */
} Prim;

typedef struct {
    Prim *v;
    int n, cap;
} Shape;

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

/* ------------------------------------------------------------------ */
/* shapes                                                              */
/* ------------------------------------------------------------------ */

static Shape *check_shape(lua_State *L, int i) {
    return (Shape *)luaL_checkudata(L, i, SHAPE_MT);
}

static int op_arg(lua_State *L, int i) {
    const char *s = luaL_optstring(L, i, "add");
    if (!strcmp(s, "sub"))
        return OP_SUB;
    if (!strcmp(s, "and"))
        return OP_AND;
    return OP_UNION;
}

static Prim *push_prim(lua_State *L, Shape *s, int kind) {
    if (s->n == s->cap) {
        int nc = s->cap ? s->cap * 2 : 8;
        Prim *v = (Prim *)realloc(s->v, (size_t)nc * sizeof *v);
        if (!v)
            luaL_error(L, "out of memory");
        s->v = v;
        s->cap = nc;
    }
    Prim *p = &s->v[s->n++];
    memset(p, 0, sizeof *p);
    p->kind = kind;
    return p;
}

static int l_shape_new(lua_State *L) {
    Shape *s = (Shape *)lua_newuserdatauv(L, sizeof *s, 0);
    memset(s, 0, sizeof *s);
    luaL_setmetatable(L, SHAPE_MT);
    return 1;
}

static int l_shape_gc(lua_State *L) {
    Shape *s = check_shape(L, 1);
    for (int i = 0; i < s->n; i++)
        free(s->v[i].pts);
    free(s->v);
    s->v = NULL;
    s->n = s->cap = 0;
    return 0;
}

/* shape:circle(cx, cy, r [, op]) */
static int l_shape_circle(lua_State *L) {
    Shape *s = check_shape(L, 1);
    float cx = (float)luaL_checknumber(L, 2), cy = (float)luaL_checknumber(L, 3);
    float r = (float)luaL_checknumber(L, 4);
    Prim *p = push_prim(L, s, PK_CIRCLE);
    p->p[0] = cx;
    p->p[1] = cy;
    p->p[2] = r;
    p->x0 = cx - r;
    p->y0 = cy - r;
    p->x1 = cx + r;
    p->y1 = cy + r;
    p->op = op_arg(L, 5);
    lua_settop(L, 1);
    return 1;
}

/* shape:ellipse(cx, cy, rx, ry [, angle [, op]]) */
static int l_shape_ellipse(lua_State *L) {
    Shape *s = check_shape(L, 1);
    float cx = (float)luaL_checknumber(L, 2), cy = (float)luaL_checknumber(L, 3);
    float rx = fmaxf((float)luaL_checknumber(L, 4), 0.01f),
          ry = fmaxf((float)luaL_checknumber(L, 5), 0.01f);
    float a = (float)luaL_optnumber(L, 6, 0.0);
    Prim *p = push_prim(L, s, PK_ELLIPSE);
    p->p[0] = cx;
    p->p[1] = cy;
    p->p[2] = rx;
    p->p[3] = ry;
    p->p[4] = cosf(a);
    p->p[5] = sinf(a);
    float m = fmaxf(rx, ry);
    p->x0 = cx - m;
    p->y0 = cy - m;
    p->x1 = cx + m;
    p->y1 = cy + m;
    p->op = op_arg(L, 7);
    lua_settop(L, 1);
    return 1;
}

/* shape:rect(x, y, w, h [, radius [, op]]) */
static int l_shape_rect(lua_State *L) {
    Shape *s = check_shape(L, 1);
    float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
    float w = (float)luaL_checknumber(L, 4), h = (float)luaL_checknumber(L, 5);
    float r = (float)luaL_optnumber(L, 6, 0.0);
    if (w < 0) {
        x += w;
        w = -w;
    }
    if (h < 0) {
        y += h;
        h = -h;
    }
    r = clampf(r, 0.f, fminf(w, h) * 0.5f);
    Prim *p = push_prim(L, s, PK_RECT);
    p->p[0] = x + w * 0.5f;
    p->p[1] = y + h * 0.5f;
    p->p[2] = w * 0.5f;
    p->p[3] = h * 0.5f;
    p->p[4] = r;
    p->x0 = x;
    p->y0 = y;
    p->x1 = x + w;
    p->y1 = y + h;
    p->op = op_arg(L, 7);
    lua_settop(L, 1);
    return 1;
}

/* shape:capsule(x1, y1, x2, y2, r [, op])  -- thick rounded line segment */
static int l_shape_capsule(lua_State *L) {
    Shape *s = check_shape(L, 1);
    float ax = (float)luaL_checknumber(L, 2), ay = (float)luaL_checknumber(L, 3);
    float bx = (float)luaL_checknumber(L, 4), by = (float)luaL_checknumber(L, 5);
    float r = (float)luaL_checknumber(L, 6);
    Prim *p = push_prim(L, s, PK_CAPSULE);
    p->p[0] = ax;
    p->p[1] = ay;
    p->p[2] = bx;
    p->p[3] = by;
    p->p[4] = r;
    p->x0 = fminf(ax, bx) - r;
    p->y0 = fminf(ay, by) - r;
    p->x1 = fmaxf(ax, bx) + r;
    p->y1 = fmaxf(ay, by) + r;
    p->op = op_arg(L, 7);
    lua_settop(L, 1);
    return 1;
}

/* shape:poly({x1, y1, x2, y2, ...} [, op]) */
static int l_shape_poly(lua_State *L) {
    Shape *s = check_shape(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    int n = (int)luaL_len(L, 2) / 2;
    if (n < 3)
        return luaL_error(L, "poly needs at least 3 points");
    float *pts = (float *)malloc(sizeof(float) * 2 * (size_t)n);
    if (!pts)
        return luaL_error(L, "out of memory");
    float x0 = 1e30f, y0 = 1e30f, x1 = -1e30f, y1 = -1e30f;
    for (int i = 0; i < n * 2; i++) {
        lua_rawgeti(L, 2, i + 1);
        pts[i] = (float)lua_tonumber(L, -1);
        lua_pop(L, 1);
        if (i % 2 == 0) {
            x0 = fminf(x0, pts[i]);
            x1 = fmaxf(x1, pts[i]);
        } else {
            y0 = fminf(y0, pts[i]);
            y1 = fmaxf(y1, pts[i]);
        }
    }
    int op = op_arg(L, 3);
    Prim *p = push_prim(L, s, PK_POLY);
    p->pts = pts;
    p->npts = n;
    p->x0 = x0;
    p->y0 = y0;
    p->x1 = x1;
    p->y1 = y1;
    p->op = op;
    lua_settop(L, 1);
    return 1;
}

static float sd_poly(const float *v, int n, float px, float py) {
    float d = (px - v[0]) * (px - v[0]) + (py - v[1]) * (py - v[1]);
    float s = 1.f;
    for (int i = 0, j = n - 1; i < n; j = i, i++) {
        float ex = v[2 * j] - v[2 * i], ey = v[2 * j + 1] - v[2 * i + 1];
        float wx = px - v[2 * i], wy = py - v[2 * i + 1];
        float ee = ex * ex + ey * ey;
        float t = ee > 0.f ? clampf((wx * ex + wy * ey) / ee, 0.f, 1.f) : 0.f;
        float bx = wx - ex * t, by = wy - ey * t;
        float dd = bx * bx + by * by;
        if (dd < d)
            d = dd;
        int c1 = py >= v[2 * i + 1], c2 = py<v[2 * j + 1], c3 = ex * wy> ey * wx;
        if ((c1 && c2 && c3) || (!c1 && !c2 && !c3))
            s = -s;
    }
    return s * sqrtf(d);
}

static float sd_prim(const Prim *pr, float x, float y) {
    switch (pr->kind) {
        case PK_CIRCLE: {
            float dx = x - pr->p[0], dy = y - pr->p[1];
            return sqrtf(dx * dx + dy * dy) - pr->p[2];
        }
        case PK_ELLIPSE: {
            float dx = x - pr->p[0], dy = y - pr->p[1];
            float c = pr->p[4], s = pr->p[5];
            float lx = dx * c + dy * s, ly = -dx * s + dy * c;
            float rx = pr->p[2], ry = pr->p[3];
            float ax = lx / rx, ay = ly / ry;
            float k0 = sqrtf(ax * ax + ay * ay);
            float bx = lx / (rx * rx), by = ly / (ry * ry);
            float k1 = sqrtf(bx * bx + by * by);
            if (k1 < 1e-6f)
                return -fminf(rx, ry);
            return k0 * (k0 - 1.f) / k1;
        }
        case PK_RECT: {
            float r = pr->p[4];
            float qx = fabsf(x - pr->p[0]) - (pr->p[2] - r);
            float qy = fabsf(y - pr->p[1]) - (pr->p[3] - r);
            float ox = fmaxf(qx, 0.f), oy = fmaxf(qy, 0.f);
            return sqrtf(ox * ox + oy * oy) + fminf(fmaxf(qx, qy), 0.f) - r;
        }
        case PK_CAPSULE: {
            float pax = x - pr->p[0], pay = y - pr->p[1];
            float bax = pr->p[2] - pr->p[0], bay = pr->p[3] - pr->p[1];
            float bb = bax * bax + bay * bay;
            float h = bb > 0.f ? clampf((pax * bax + pay * bay) / bb, 0.f, 1.f) : 0.f;
            float dx = pax - bax * h, dy = pay - bay * h;
            return sqrtf(dx * dx + dy * dy) - pr->p[4];
        }
        case PK_POLY:
            return sd_poly(pr->pts, pr->npts, x, y);
    }
    return 1e9f;
}

static float sd_shape(const Shape *s, float x, float y) {
    float d = 1e9f;
    for (int i = 0; i < s->n; i++) {
        const Prim *pr = &s->v[i];
        float v = sd_prim(pr, x, y);
        switch (pr->op) {
            case OP_UNION:
                d = fminf(d, v);
                break;
            case OP_SUB:
                d = fmaxf(d, -v);
                break;
            case OP_AND:
                d = fmaxf(d, v);
                break;
        }
    }
    return d;
}

/* ------------------------------------------------------------------ */
/* images                                                              */
/* ------------------------------------------------------------------ */

static Image *check_image(lua_State *L, int i) {
    Image *im = (Image *)luaL_checkudata(L, i, IMAGE_MT);
    if (!im->px)
        luaL_error(L, "image has been released");
    return im;
}

static int l_image_new(lua_State *L) {
    int w = (int)luaL_checkinteger(L, 1), h = (int)luaL_checkinteger(L, 2);
    luaL_argcheck(L, w > 0 && w <= 4096, 1, "bad width");
    luaL_argcheck(L, h > 0 && h <= 4096, 2, "bad height");
    Image *im = (Image *)lua_newuserdatauv(L, sizeof *im, 0);
    im->w = w;
    im->h = h;
    im->px = (float *)calloc((size_t)w * h * 4, sizeof(float));
    if (!im->px)
        return luaL_error(L, "out of memory");
    luaL_setmetatable(L, IMAGE_MT);
    return 1;
}

static int l_image_gc(lua_State *L) {
    Image *im = (Image *)luaL_checkudata(L, 1, IMAGE_MT);
    free(im->px);
    im->px = NULL;
    return 0;
}

static int l_image_size(lua_State *L) {
    Image *im = check_image(L, 1);
    lua_pushinteger(L, im->w);
    lua_pushinteger(L, im->h);
    return 2;
}

static float opt_field(lua_State *L, int t, const char *k, float def) {
    lua_getfield(L, t, k);
    float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : def;
    lua_pop(L, 1);
    return v;
}

enum { MODE_OVER, MODE_ERASE, MODE_ADD };

/* img:fill(shape, r, g, b [, a [, opts]]) */
static int l_image_fill(lua_State *L) {
    Image *im = check_image(L, 1);
    Shape *sh = check_shape(L, 2);
    float cr = (float)luaL_checknumber(L, 3) / 255.f;
    float cg = (float)luaL_checknumber(L, 4) / 255.f;
    float cb = (float)luaL_checknumber(L, 5) / 255.f;
    float ca = (float)luaL_optnumber(L, 6, 255.0) / 255.f;
    float inset = 0.f, soft = 1.f, dx = 0.f, dy = 0.f;
    int mode = MODE_OVER;
    if (lua_istable(L, 7)) {
        inset = opt_field(L, 7, "inset", 0.f);
        soft = opt_field(L, 7, "soft", 1.f);
        dx = opt_field(L, 7, "dx", 0.f);
        dy = opt_field(L, 7, "dy", 0.f);
        lua_getfield(L, 7, "mode");
        const char *m = lua_tostring(L, -1);
        if (m && !strcmp(m, "erase"))
            mode = MODE_ERASE;
        else if (m && !strcmp(m, "add"))
            mode = MODE_ADD;
        lua_pop(L, 1);
    }
    cr = clampf(cr, 0, 1);
    cg = clampf(cg, 0, 1);
    cb = clampf(cb, 0, 1);
    ca = clampf(ca, 0, 1);
    if (soft < 0.05f)
        soft = 0.05f;

    /* bounds of the union parts */
    float bx0 = 1e30f, by0 = 1e30f, bx1 = -1e30f, by1 = -1e30f;
    for (int i = 0; i < sh->n; i++) {
        const Prim *p = &sh->v[i];
        if (p->op != OP_UNION)
            continue;
        bx0 = fminf(bx0, p->x0);
        by0 = fminf(by0, p->y0);
        bx1 = fmaxf(bx1, p->x1);
        by1 = fmaxf(by1, p->y1);
    }
    if (bx0 > bx1) {
        lua_settop(L, 1);
        return 1;
    }
    float m = soft + fmaxf(-inset, 0.f) + 2.f;
    int x0 = (int)floorf(bx0 + dx - m), y0 = (int)floorf(by0 + dy - m);
    int x1 = (int)ceilf(bx1 + dx + m), y1 = (int)ceilf(by1 + dy + m);
    if (x0 < 0)
        x0 = 0;
    if (y0 < 0)
        y0 = 0;
    if (x1 > im->w)
        x1 = im->w;
    if (y1 > im->h)
        y1 = im->h;

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float d = sd_shape(sh, x + 0.5f - dx, y + 0.5f - dy) + inset;
            float cov = 0.5f - d / soft;
            if (cov <= 0.f)
                continue;
            if (cov > 1.f)
                cov = 1.f;
            float sa = ca * cov;
            float *p = &im->px[((size_t)y * im->w + x) * 4];
            if (mode == MODE_OVER) {
                float k = 1.f - sa;
                p[0] = cr * sa + p[0] * k;
                p[1] = cg * sa + p[1] * k;
                p[2] = cb * sa + p[2] * k;
                p[3] = sa + p[3] * k;
            } else if (mode == MODE_ERASE) {
                float k = 1.f - sa;
                p[0] *= k;
                p[1] *= k;
                p[2] *= k;
                p[3] *= k;
            } else {
                p[0] = fminf(1.f, p[0] + cr * sa);
                p[1] = fminf(1.f, p[1] + cg * sa);
                p[2] = fminf(1.f, p[2] + cb * sa);
                p[3] = fminf(1.f, p[3] + sa);
            }
        }
    }
    lua_settop(L, 1);
    return 1;
}

/* img:gradient(r1,g1,b1,a1, r2,g2,b2,a2)  -- vertical, replaces contents */
static int l_image_gradient(lua_State *L) {
    Image *im = check_image(L, 1);
    float c[8];
    for (int i = 0; i < 8; i++)
        c[i] = clampf((float)luaL_checknumber(L, i + 2) / 255.f, 0, 1);
    for (int y = 0; y < im->h; y++) {
        float t = im->h > 1 ? (float)y / (float)(im->h - 1) : 0.f;
        float a = c[3] + (c[7] - c[3]) * t;
        float r = (c[0] + (c[4] - c[0]) * t) * a;
        float g = (c[1] + (c[5] - c[1]) * t) * a;
        float b = (c[2] + (c[6] - c[2]) * t) * a;
        for (int x = 0; x < im->w; x++) {
            float *p = &im->px[((size_t)y * im->w + x) * 4];
            p[0] = r;
            p[1] = g;
            p[2] = b;
            p[3] = a;
        }
    }
    lua_settop(L, 1);
    return 1;
}

/* img:pixel(x, y, r, g, b [, a])  -- 0-based coordinates, replaces */
static int l_image_pixel(lua_State *L) {
    Image *im = check_image(L, 1);
    int x = (int)luaL_checkinteger(L, 2), y = (int)luaL_checkinteger(L, 3);
    if (x < 0 || y < 0 || x >= im->w || y >= im->h)
        return 0;
    float a = clampf((float)luaL_optnumber(L, 7, 255.0) / 255.f, 0, 1);
    float *p = &im->px[((size_t)y * im->w + x) * 4];
    p[0] = clampf((float)luaL_checknumber(L, 4) / 255.f, 0, 1) * a;
    p[1] = clampf((float)luaL_checknumber(L, 5) / 255.f, 0, 1) * a;
    p[2] = clampf((float)luaL_checknumber(L, 6) / 255.f, 0, 1) * a;
    p[3] = a;
    return 0;
}

/* img:texture(["linear"|"nearest"]) -> Texture */
static int l_image_texture(lua_State *L) {
    Image *im = check_image(L, 1);
    const char *filter = luaL_optstring(L, 2, "linear");
    size_t n = (size_t)im->w * im->h;
    unsigned char *out = (unsigned char *)malloc(n * 4);
    if (!out)
        return luaL_error(L, "out of memory");

    for (size_t i = 0; i < n; i++) {
        const float *p = &im->px[i * 4];
        float a = p[3];
        unsigned char *o = &out[i * 4];
        if (a > 1.f / 512.f) {
            o[0] = (unsigned char)(clampf(p[0] / a, 0, 1) * 255.f + 0.5f);
            o[1] = (unsigned char)(clampf(p[1] / a, 0, 1) * 255.f + 0.5f);
            o[2] = (unsigned char)(clampf(p[2] / a, 0, 1) * 255.f + 0.5f);
            o[3] = (unsigned char)(clampf(a, 0, 1) * 255.f + 0.5f);
        } else {
            o[0] = o[1] = o[2] = o[3] = 0;
        }
    }
    gfx_bleed_rgba(out, im->w, im->h);

    SDL_Texture *t = gfx_create_texture_rgba(out, im->w, im->h, strcmp(filter, "nearest") != 0);
    free(out);
    if (!t)
        return luaL_error(L, "texture creation failed: %s", SDL_GetError());
    gfx_push_texture(L, t, im->w, im->h);
    return 1;
}

static Image *new_image(lua_State *L, int w, int h) {
    Image *im = (Image *)lua_newuserdatauv(L, sizeof *im, 0);
    im->w = w;
    im->h = h;
    im->px = (float *)calloc((size_t)w * h * 4, sizeof(float));
    if (!im->px)
        luaL_error(L, "out of memory");
    luaL_setmetatable(L, IMAGE_MT);
    return im;
}

/* gfx.image_load(path) -> Image | nil, err */
static int l_image_load(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int w = 0, h = 0;
    char err[512];
    unsigned char *px = gfx_decode_file(path, &w, &h, err, sizeof err);
    if (!px) {
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
    if (w > 8192 || h > 8192) {
        stbi_image_free(px);
        lua_pushnil(L);
        lua_pushfstring(L, "%s: image too large (%dx%d)", path, w, h);
        return 2;
    }
    Image *im = new_image(L, w, h);
    size_t n = (size_t)w * h;
    for (size_t i = 0; i < n; i++) {
        float a = px[i * 4 + 3] / 255.f;
        im->px[i * 4 + 0] = px[i * 4 + 0] / 255.f * a;
        im->px[i * 4 + 1] = px[i * 4 + 1] / 255.f * a;
        im->px[i * 4 + 2] = px[i * 4 + 2] / 255.f * a;
        im->px[i * 4 + 3] = a;
    }
    stbi_image_free(px);
    return 1;
}

/* img:crop(x, y, w, h) -> new Image (areas outside the source are transparent) */
static int l_image_crop(lua_State *L) {
    Image *src = check_image(L, 1);
    int x = (int)luaL_checkinteger(L, 2), y = (int)luaL_checkinteger(L, 3);
    int w = (int)luaL_checkinteger(L, 4), h = (int)luaL_checkinteger(L, 5);
    luaL_argcheck(L, w > 0 && w <= 4096 && h > 0 && h <= 4096, 4, "bad size");
    Image *dst = new_image(L, w, h);
    for (int yy = 0; yy < h; yy++) {
        int sy = y + yy;
        if (sy < 0 || sy >= src->h)
            continue;
        for (int xx = 0; xx < w; xx++) {
            int sx = x + xx;
            if (sx < 0 || sx >= src->w)
                continue;
            memcpy(&dst->px[((size_t)yy * w + xx) * 4], &src->px[((size_t)sy * src->w + sx) * 4],
                   sizeof(float) * 4);
        }
    }
    return 1;
}

/* img:blit(src, x, y)  -- alpha-composite src over img at (x, y), no scaling */
static int l_image_blit(lua_State *L) {
    Image *dst = check_image(L, 1);
    Image *src = check_image(L, 2);
    int ox = (int)luaL_checkinteger(L, 3), oy = (int)luaL_checkinteger(L, 4);
    for (int y = 0; y < src->h; y++) {
        int dy = oy + y;
        if (dy < 0 || dy >= dst->h)
            continue;
        for (int x = 0; x < src->w; x++) {
            int dx = ox + x;
            if (dx < 0 || dx >= dst->w)
                continue;
            const float *s = &src->px[((size_t)y * src->w + x) * 4];
            float *d = &dst->px[((size_t)dy * dst->w + dx) * 4];
            float k = 1.f - s[3];
            d[0] = s[0] + d[0] * k;
            d[1] = s[1] + d[1] * k;
            d[2] = s[2] + d[2] * k;
            d[3] = s[3] + d[3] * k;
        }
    }
    lua_settop(L, 1);
    return 1;
}

typedef struct {
    unsigned char *data;
    size_t len, cap;
} MemBuf;

static void membuf_write(void *ctx, void *data, int size) {
    MemBuf *m = (MemBuf *)ctx;
    if (size <= 0 || !m->data)
        return;
    if (m->len + (size_t)size > m->cap) {
        size_t nc = (m->cap + (size_t)size) * 2;
        unsigned char *nd = (unsigned char *)realloc(m->data, nc);
        if (!nd) {
            free(m->data);
            m->data = NULL;
            return;
        }
        m->data = nd;
        m->cap = nc;
    }
    memcpy(m->data + m->len, data, (size_t)size);
    m->len += (size_t)size;
}

/* gfx.save_png(img, path) -> true | nil, err */
static int l_image_save_png(lua_State *L) {
    Image *im = check_image(L, 1);
    const char *path = luaL_checkstring(L, 2);
    size_t n = (size_t)im->w * im->h;
    unsigned char *rgba = (unsigned char *)malloc(n * 4);
    if (!rgba)
        return luaL_error(L, "out of memory");
    for (size_t i = 0; i < n; i++) {
        const float *p = &im->px[i * 4];
        float a = p[3];
        for (int c = 0; c < 3; c++) {
            float v = a > 1.f / 512.f ? p[c] / a : 0.f;
            rgba[i * 4 + c] = (unsigned char)(clampf(v, 0, 1) * 255.f + 0.5f);
        }
        rgba[i * 4 + 3] = (unsigned char)(clampf(a, 0, 1) * 255.f + 0.5f);
    }
    MemBuf mb = {(unsigned char *)malloc(65536), 0, 65536};
    int ok = mb.data && stbi_write_png_to_func(membuf_write, &mb, im->w, im->h, 4, rgba, im->w * 4);
    free(rgba);
    ok = ok && mb.data && fs_write(path, mb.data, mb.len);
    free(mb.data);
    if (!ok) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot write %s", path);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

void canvas_register(lua_State *L, int gfx_table) {
    static const luaL_Reg shape_methods[] = {
        {"circle", l_shape_circle},   {"ellipse", l_shape_ellipse}, {"rect", l_shape_rect},
        {"capsule", l_shape_capsule}, {"poly", l_shape_poly},       {NULL, NULL},
    };
    luaL_newmetatable(L, SHAPE_MT);
    lua_pushcfunction(L, l_shape_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, shape_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    static const luaL_Reg image_methods[] = {
        {"fill", l_image_fill},   {"gradient", l_image_gradient},
        {"pixel", l_image_pixel}, {"texture", l_image_texture},
        {"size", l_image_size},   {"crop", l_image_crop},
        {"blit", l_image_blit},   {NULL, NULL},
    };
    luaL_newmetatable(L, IMAGE_MT);
    lua_pushcfunction(L, l_image_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, image_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    lua_pushcfunction(L, l_shape_new);
    lua_setfield(L, gfx_table, "shape");
    lua_pushcfunction(L, l_image_new);
    lua_setfield(L, gfx_table, "image");
    lua_pushcfunction(L, l_image_load);
    lua_setfield(L, gfx_table, "image_load");
    lua_pushcfunction(L, l_image_save_png);
    lua_setfield(L, gfx_table, "save_png");
}
