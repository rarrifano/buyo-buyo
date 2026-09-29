/*
 * fs: portable filesystem helpers.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * File contents go through SDL_RWops so UTF-8 paths work on every platform
 * (including Windows). Directory listing uses FindFirstFile / opendir.
 *
 * Lua (added to `sys`, trusted engine scripts only - content sandboxes never
 * see these):
 *   sys.list_dir(path)          -> { {name=, dir=bool}, ... }   (unsorted, no dotfiles)
 *   sys.read_file(path)         -> string | nil, err
 *   sys.write_file(path, data)  -> true | nil, err
 *   sys.exists(path)            -> "file" | "dir" | nil
 *   sys.mkdir(path)             -> bool   (creates parents too)
 */
#include "engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#endif

void *fs_read(const char *path, size_t *len)
{
    SDL_RWops *rw = SDL_RWFromFile(path, "rb");
    if (!rw) return NULL;
    Sint64 size = SDL_RWsize(rw);
    if (size < 0 || size > (Sint64)512 * 1024 * 1024) {
        SDL_RWclose(rw);
        return NULL;
    }
    char *buf = (char *)malloc((size_t)size + 1);
    if (!buf) {
        SDL_RWclose(rw);
        return NULL;
    }
    size_t got = 0;
    while (got < (size_t)size) {
        size_t n = SDL_RWread(rw, buf + got, 1, (size_t)size - got);
        if (n == 0) break;
        got += n;
    }
    SDL_RWclose(rw);
    if (got != (size_t)size) {
        free(buf);
        return NULL;
    }
    buf[size] = '\0';
    if (len) *len = (size_t)size;
    return buf;
}

bool fs_write(const char *path, const void *data, size_t len)
{
    SDL_RWops *rw = SDL_RWFromFile(path, "wb");
    if (!rw) return false;
    bool ok = SDL_RWwrite(rw, data, 1, len) == len;
    if (SDL_RWclose(rw) != 0) ok = false;
    return ok;
}

int fs_kind(const char *path)
{
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wlen <= 0) return 0;
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)wlen);
    if (!w) return 0;
    MultiByteToWideChar(CP_UTF8, 0, path, -1, w, wlen);
    DWORD attr = GetFileAttributesW(w);
    free(w);
    if (attr == INVALID_FILE_ATTRIBUTES) return 0;
    return (attr & FILE_ATTRIBUTE_DIRECTORY) ? 2 : 1;
#else
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 2 : 1;
#endif
}

static bool mkdir_one(const char *path)
{
    if (fs_kind(path) == 2) return true;
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wlen <= 0) return false;
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)wlen);
    if (!w) return false;
    MultiByteToWideChar(CP_UTF8, 0, path, -1, w, wlen);
    bool ok = CreateDirectoryW(w, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
    free(w);
    return ok;
#else
    return mkdir(path, 0755) == 0 || fs_kind(path) == 2;
#endif
}

bool fs_mkdirs(const char *path)
{
    char buf[1024];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof buf) return false;
    memcpy(buf, path, n + 1);
    for (size_t i = 1; i < n; i++) {
        if (buf[i] == '/' || buf[i] == '\\') {
            char c = buf[i];
            buf[i] = '\0';
            if (!(i == 2 && buf[1] == ':')) mkdir_one(buf); /* skip "C:" */
            buf[i] = c;
        }
    }
    return mkdir_one(buf);
}

/* ------------------------------------------------------------------ */
/* Lua                                                                 */
/* ------------------------------------------------------------------ */

static void push_entry(lua_State *L, int *n, const char *name, bool dir)
{
    lua_createtable(L, 0, 2);
    lua_pushstring(L, name);
    lua_setfield(L, -2, "name");
    lua_pushboolean(L, dir);
    lua_setfield(L, -2, "dir");
    lua_rawseti(L, -2, ++*n);
}

static int l_list_dir(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    lua_newtable(L);
    int n = 0;
#ifdef _WIN32
    char pattern[1100];
    snprintf(pattern, sizeof pattern, "%s\\*", path);
    int wlen = MultiByteToWideChar(CP_UTF8, 0, pattern, -1, NULL, 0);
    wchar_t *wpat = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)(wlen > 0 ? wlen : 1));
    if (!wpat) return 1;
    MultiByteToWideChar(CP_UTF8, 0, pattern, -1, wpat, wlen);
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(wpat, &fd);
    free(wpat);
    if (h == INVALID_HANDLE_VALUE) return 1;
    do {
        char name[MAX_PATH * 4];
        if (WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, name, sizeof name, NULL, NULL) <= 0) continue;
        if (name[0] == '.') continue;
        push_entry(L, &n, name, (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
#else
    DIR *d = opendir(path);
    if (!d) return 1;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        char full[1400];
        snprintf(full, sizeof full, "%s/%s", path, e->d_name);
        push_entry(L, &n, e->d_name, fs_kind(full) == 2);
    }
    closedir(d);
#endif
    return 1;
}

static int l_read_file(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    size_t len = 0;
    char *buf = (char *)fs_read(path, &len);
    if (!buf) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot read %s", path);
        return 2;
    }
    lua_pushlstring(L, buf, len);
    free(buf);
    return 1;
}

static int l_write_file(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    size_t len;
    const char *data = luaL_checklstring(L, 2, &len);
    if (!fs_write(path, data, len)) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot write %s", path);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_exists(lua_State *L)
{
    int k = fs_kind(luaL_checkstring(L, 1));
    if (k == 0) lua_pushnil(L);
    else lua_pushstring(L, k == 2 ? "dir" : "file");
    return 1;
}

static int l_mkdir(lua_State *L)
{
    lua_pushboolean(L, fs_mkdirs(luaL_checkstring(L, 1)));
    return 1;
}

void fs_register(lua_State *L, int sys_table)
{
    static const luaL_Reg fns[] = {
        { "list_dir", l_list_dir }, { "read_file", l_read_file }, { "write_file", l_write_file },
        { "exists", l_exists },     { "mkdir", l_mkdir },         { NULL, NULL },
    };
    for (const luaL_Reg *r = fns; r->name; r++) {
        lua_pushcfunction(L, r->func);
        lua_setfield(L, sys_table, r->name);
    }
}
