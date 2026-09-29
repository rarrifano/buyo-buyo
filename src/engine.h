/*
 * Buyo Buyo - engine core (C side).
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The C host is a small, portable platform layer: window, renderer, audio
 * synth + sample/stream playback, input, filesystem, UDP networking and the
 * Lua VM. It exposes the Lua modules `gfx`, `audio`, `input`, `net`, `sys`.
 * Everything else - rules, AI, rollback netcode, menus and all content
 * (characters, stages, skins, modes, music) - lives in Lua.
 */
#ifndef BUYO_ENGINE_H
#define BUYO_ENGINE_H

#include <SDL.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdbool.h>
#include <stddef.h>

#define BUYO_VERSION "0.2.0"
#ifndef BUYO_COMMIT
#define BUYO_COMMIT "unknown" /* set by the Makefile from `git rev-parse --short HEAD` */
#endif
#define GAME_W 1280 /* logical resolution */
#define GAME_H 720
#define TICK_HZ 60 /* fixed simulation rate */

typedef struct {
    SDL_Window *window;
    bool headless;
    bool fullscreen;
    bool failed; /* a script error happened (headless runs exit with 1) */
    int argc;    /* arguments forwarded to Lua (sys.args) */
    char **argv;
    char data_dir[1024]; /* engine scripts (game/) */
    char pref_dir[1024]; /* per-user writable dir, ends with a separator */
} Engine;

extern Engine g_engine;

/* ---- fs.c : portable file helpers (UTF-8 paths via SDL_RWops) ---- */
void *fs_read(const char *path, size_t *len); /* malloc'd, NUL-terminated */
bool fs_write(const char *path, const void *data, size_t len);
int fs_kind(const char *path); /* 0 missing, 1 file, 2 dir */
bool fs_mkdirs(const char *path);
void fs_register(lua_State *L, int sys_table); /* adds sys.list_dir & co. */

/* ---- gfx.c : renderer, bitmap font, textures, primitives ---- */
bool gfx_init(SDL_Window *win, bool software, bool vsync);
void gfx_shutdown(void);
void gfx_reset_state(void);
void gfx_end_frame(void);
void gfx_draw_error(const char *msg);
void gfx_request_screenshot(const char *path);
SDL_Texture *gfx_create_texture_rgba(const unsigned char *rgba, int w, int h, bool linear);
void gfx_bleed_rgba(unsigned char *px, int w, int h);
unsigned char *gfx_decode_file(const char *path, int *w, int *h, char *err, size_t errlen);
void gfx_push_texture(lua_State *L, SDL_Texture *tex, int w, int h);
int luaopen_gfx(lua_State *L);

/* ---- canvas.c : CPU-side images + anti-aliased SDF shapes ---- */
void canvas_register(lua_State *L, int gfx_table);

/* ---- audio.c : synth voices, samples, music sequencer + file streams ---- */
bool audio_init(bool enabled);
void audio_shutdown(void);
void audio_stop_all(void);
int luaopen_audio(lua_State *L);

/* ---- input.c : keyboard + game controllers ---- */
void input_init(void);
void input_shutdown(void);
void input_handle_event(const SDL_Event *e);
int luaopen_input(lua_State *L);

/* ---- net.c : UDP sockets for peer-to-peer netplay ---- */
int luaopen_net(lua_State *L);
void net_shutdown(void);

/* ---- script.c : Lua VM host, callbacks, error screen, `sys` ---- */
bool script_init(void);
void script_shutdown(void);
void script_reload(void);
void script_update(double dt);
void script_draw(void);
void script_key(SDL_Scancode sc, bool down, bool repeat);
void script_text(const char *utf8);
void script_focus(bool focused);
void script_quit(void);

/* ---- main.c ---- */
void engine_set_fullscreen(bool on);

#endif
