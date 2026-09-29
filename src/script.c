/*
 * script: hosts the Lua VM.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * game/main.lua must return a table with any of these callbacks:
 *   load()  update(dt)  draw()  key(name, down, is_repeat)  text(utf8)
 *   focus(bool)  quit()
 *
 * Every callback runs under lua_pcall with a traceback. On error the engine
 * shows the message on an error screen; F5 reloads all scripts.
 *
 * `sys` module: time, quit, fullscreen, save/load (user dir), args, headless,
 * data_dir, pref_dir, clipboard, text_input, version, platform, plus the
 * filesystem helpers from fs.c.
 */
#include "engine.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static lua_State *L;
static int app_ref = LUA_NOREF;
static char *error_msg;

static int l_quit(lua_State *Ls);

static void set_error(const char *msg) {
    SDL_free(error_msg);
    error_msg = SDL_strdup(msg ? msg : "unknown error");
    fprintf(stderr, "\n[lua] %s\n\n", error_msg);
    audio_stop_all();
    g_engine.failed = true;
    if (g_engine.headless)
        l_quit(NULL); /* nobody can press F5: stop right away */
}

static int traceback(lua_State *Ls) {
    const char *msg = lua_tostring(Ls, 1);
    if (!msg) {
        if (luaL_callmeta(Ls, 1, "__tostring") && lua_type(Ls, -1) == LUA_TSTRING)
            return 1;
        msg = lua_pushfstring(Ls, "(error object is a %s value)", luaL_typename(Ls, 1));
    }
    luaL_traceback(Ls, Ls, msg, 1);
    return 1;
}

/* push app[name]; returns false (and pushes nothing) if missing */
static bool push_callback(const char *name) {
    if (!L || error_msg || app_ref == LUA_NOREF)
        return false;
    lua_rawgeti(L, LUA_REGISTRYINDEX, app_ref);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    return true;
}

/* stack: fn, args... */
static bool pcall_callback(int nargs) {
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, traceback);
    lua_insert(L, base);
    int rc = lua_pcall(L, nargs, 0, base);
    if (rc != LUA_OK) {
        set_error(lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    lua_remove(L, base);
    return rc == LUA_OK;
}

/* ------------------------------------------------------------------ */
/* sys module                                                          */
/* ------------------------------------------------------------------ */

static int l_time(lua_State *Ls) {
    lua_pushnumber(Ls, (double)SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency());
    return 1;
}

static int l_quit(lua_State *Ls) {
    (void)Ls;
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_QUIT;
    SDL_PushEvent(&e);
    return 0;
}

static int l_fullscreen(lua_State *Ls) {
    if (lua_gettop(Ls) >= 1)
        engine_set_fullscreen(lua_toboolean(Ls, 1));
    lua_pushboolean(Ls, g_engine.fullscreen);
    return 1;
}

static bool valid_name(const char *s) {
    if (!*s || strlen(s) > 64 || s[0] == '.')
        return false;
    for (; *s; s++)
        if (!isalnum((unsigned char)*s) && *s != '_' && *s != '-' && *s != '.')
            return false;
    return true;
}

/* sys.save(name, string) -> bool   (file in the user dir) */
static int l_save(lua_State *Ls) {
    const char *name = luaL_checkstring(Ls, 1);
    size_t len;
    const char *data = luaL_checklstring(Ls, 2, &len);
    if (!g_engine.pref_dir[0] || !valid_name(name)) {
        lua_pushboolean(Ls, 0);
        return 1;
    }
    char path[1200];
    snprintf(path, sizeof path, "%s%s", g_engine.pref_dir, name);
    lua_pushboolean(Ls, fs_write(path, data, len));
    return 1;
}

/* sys.load(name) -> string | nil */
static int l_load(lua_State *Ls) {
    const char *name = luaL_checkstring(Ls, 1);
    if (!g_engine.pref_dir[0] || !valid_name(name))
        return 0;
    char path[1200];
    snprintf(path, sizeof path, "%s%s", g_engine.pref_dir, name);
    size_t len = 0;
    char *buf = (char *)fs_read(path, &len);
    if (!buf)
        return 0;
    lua_pushlstring(Ls, buf, len);
    free(buf);
    return 1;
}

static int l_args(lua_State *Ls) {
    lua_createtable(Ls, g_engine.argc, 0);
    for (int i = 0; i < g_engine.argc; i++) {
        lua_pushstring(Ls, g_engine.argv[i]);
        lua_rawseti(Ls, -2, i + 1);
    }
    return 1;
}

static int l_headless(lua_State *Ls) {
    lua_pushboolean(Ls, g_engine.headless);
    return 1;
}

static int l_data_dir(lua_State *Ls) {
    lua_pushstring(Ls, g_engine.data_dir);
    return 1;
}

static int l_pref_dir(lua_State *Ls) {
    lua_pushstring(Ls, g_engine.pref_dir);
    return 1;
}

static int l_set_title(lua_State *Ls) {
    if (g_engine.window)
        SDL_SetWindowTitle(g_engine.window, luaL_checkstring(Ls, 1));
    return 0;
}

/* sys.clipboard() -> text | nil ;  sys.clipboard(text) */
static int l_clipboard(lua_State *Ls) {
    if (lua_gettop(Ls) >= 1) {
        SDL_SetClipboardText(luaL_checkstring(Ls, 1));
        return 0;
    }
    if (!SDL_HasClipboardText())
        return 0;
    char *t = SDL_GetClipboardText();
    if (!t)
        return 0;
    lua_pushstring(Ls, t);
    SDL_free(t);
    return 1;
}

/* sys.open_url(url) -> bool   (e.g. "file:///path" opens a file manager) */
static int l_open_url(lua_State *Ls) {
    const char *url = luaL_checkstring(Ls, 1);
    lua_pushboolean(Ls, !g_engine.headless && SDL_OpenURL(url) == 0);
    return 1;
}

/* sys.text_input(bool): enable text() callbacks (for typing codes, names) */
static int l_text_input(lua_State *Ls) {
    if (lua_toboolean(Ls, 1))
        SDL_StartTextInput();
    else
        SDL_StopTextInput();
    return 0;
}

int luaopen_sys(lua_State *Ls) {
    static const luaL_Reg fns[] = {
        {"time", l_time},
        {"quit", l_quit},
        {"fullscreen", l_fullscreen},
        {"save", l_save},
        {"load", l_load},
        {"args", l_args},
        {"headless", l_headless},
        {"data_dir", l_data_dir},
        {"pref_dir", l_pref_dir},
        {"set_title", l_set_title},
        {"clipboard", l_clipboard},
        {"text_input", l_text_input},
        {"open_url", l_open_url},
        {NULL, NULL},
    };
    luaL_newlib(Ls, fns);
    fs_register(Ls, lua_gettop(Ls));
    lua_pushstring(Ls, SDL_GetPlatform());
    lua_setfield(Ls, -2, "platform");
    lua_pushstring(Ls, BUYO_VERSION);
    lua_setfield(Ls, -2, "version");
    return 1;
}

/* ------------------------------------------------------------------ */
/* lifecycle                                                           */
/* ------------------------------------------------------------------ */

bool script_init(void) {
    SDL_free(error_msg);
    error_msg = NULL;
    gfx_reset_state();

    L = luaL_newstate();
    if (!L) {
        set_error("cannot create Lua state");
        return false;
    }
    luaL_openlibs(L);
    luaL_requiref(L, "gfx", luaopen_gfx, 1);
    luaL_requiref(L, "audio", luaopen_audio, 1);
    luaL_requiref(L, "input", luaopen_input, 1);
    luaL_requiref(L, "net", luaopen_net, 1);
    luaL_requiref(L, "sys", luaopen_sys, 1);
    lua_pop(L, 5);

    /* require() looks in the data dir only; no native modules */
    lua_getglobal(L, "package");
    lua_pushfstring(L, "%s/?.lua;%s/?/init.lua", g_engine.data_dir, g_engine.data_dir);
    lua_setfield(L, -2, "path");
    lua_pushstring(L, "");
    lua_setfield(L, -2, "cpath");
    lua_pop(L, 1);

    char path[1200];
    snprintf(path, sizeof path, "%s/main.lua", g_engine.data_dir);
    size_t len = 0;
    char *src = (char *)fs_read(path, &len);
    if (!src) {
        char msg[1300];
        snprintf(msg, sizeof msg, "cannot read %s", path);
        set_error(msg);
        return false;
    }
    char chunkname[1300];
    snprintf(chunkname, sizeof chunkname, "@%s", path);
    lua_pushcfunction(L, traceback);
    int rc = luaL_loadbuffer(L, src, len, chunkname);
    free(src);
    if (rc != LUA_OK || lua_pcall(L, 0, 1, -2) != LUA_OK) {
        set_error(lua_tostring(L, -1));
        lua_settop(L, 0);
        return false;
    }
    if (!lua_istable(L, -1)) {
        set_error("main.lua must return a table of callbacks");
        lua_settop(L, 0);
        return false;
    }
    app_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_settop(L, 0);

    if (push_callback("load"))
        return pcall_callback(0);
    return true;
}

void script_shutdown(void) {
    if (L)
        lua_close(L);
    L = NULL;
    app_ref = LUA_NOREF;
}

void script_reload(void) {
    SDL_Log("reloading scripts from %s", g_engine.data_dir);
    audio_stop_all();
    SDL_StopTextInput();
    script_shutdown();
    script_init();
}

void script_update(double dt) {
    if (push_callback("update")) {
        lua_pushnumber(L, dt);
        pcall_callback(1);
    }
}

void script_draw(void) {
    if (error_msg) {
        gfx_draw_error(error_msg);
        return;
    }
    if (push_callback("draw"))
        pcall_callback(0);
    gfx_reset_state();
}

void script_key(SDL_Scancode sc, bool down, bool repeat) {
    if (error_msg) {
        if (down && sc == SDL_SCANCODE_ESCAPE)
            l_quit(NULL);
        return;
    }
    if (push_callback("key")) {
        lua_pushstring(L, SDL_GetScancodeName(sc));
        lua_pushboolean(L, down);
        lua_pushboolean(L, repeat);
        pcall_callback(3);
    }
}

void script_text(const char *utf8) {
    if (push_callback("text")) {
        lua_pushstring(L, utf8);
        pcall_callback(1);
    }
}

void script_focus(bool focused) {
    if (push_callback("focus")) {
        lua_pushboolean(L, focused);
        pcall_callback(1);
    }
}

void script_quit(void) {
    if (push_callback("quit"))
        pcall_callback(0);
}
