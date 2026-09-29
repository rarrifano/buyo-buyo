/*
 * Buyo Buyo - entry point and main loop.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Fixed 60 Hz simulation (Lua `update`) with rendering every display frame.
 */
#include "engine.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Engine g_engine;

static void usage(const char *argv0)
{
    printf("Buyo Buyo " BUYO_VERSION " - a moddable versus puzzle platform (C + SDL2 + Lua)\n\n"
           "Usage: %s [options] [-- game-args]\n\n"
           "  --data DIR      game script directory (default: auto-detect)\n"
           "  --fullscreen    start in fullscreen (toggle: F11 / Alt+Enter)\n"
           "  --scale N       window scale factor (default: fit the screen)\n"
           "  --software      force the software renderer\n"
           "  --no-vsync      disable vsync\n"
           "  --mute          disable audio\n"
           "  --headless      no visible window / audio, run as fast as possible\n"
           "  --realtime      with --headless: keep real-time 60 Hz pacing (netplay tests)\n"
           "  --frames N      quit after N simulation frames\n"
           "  -h, --help      show this help\n\n"
           "Game args (forwarded to Lua, see docs/CLI.md for all of them):\n"
           "  --mods DIR              extra content folder (chars/stages/skins/modes/music)\n"
           "  --mode cpu|2p|watch     jump straight into a match\n"
           "  --connect CODE          join an online match (code or ip:port)\n"
           "  --host                  wait for an online opponent\n"
           "  --export-skin ID FILE   write a skin as a PNG sheet (template for artists)\n"
           "  --check-content         load every content item, report errors, quit\n"
           "  --test                  run the self-tests and quit\n\n"
           "Dev keys: F5 reload Lua scripts + content, F12 screenshot\n",
           argv0);
}

static bool file_exists(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

static bool try_data_dir(const char *dir)
{
    char path[1200];
    snprintf(path, sizeof path, "%s/main.lua", dir);
    if (!file_exists(path)) return false;
    snprintf(g_engine.data_dir, sizeof g_engine.data_dir, "%s", dir);
    return true;
}

static bool find_data_dir(const char *override)
{
    if (override) return try_data_dir(override);

    const char *env = getenv("BUYO_DATA");
    if (env && try_data_dir(env)) return true;

    bool ok = false;
    char *base = SDL_GetBasePath();
    if (base) {
        static const char *rel[] = { "game", "../game", "../../game", "../Resources/game",
                                     "../share/buyo-buyo/game" };
        char buf[1100];
        for (size_t i = 0; i < sizeof rel / sizeof rel[0] && !ok; i++) {
            snprintf(buf, sizeof buf, "%s%s", base, rel[i]);
            ok = try_data_dir(buf);
        }
        SDL_free(base);
    }
    if (!ok) ok = try_data_dir("game");
    return ok;
}

void engine_set_fullscreen(bool on)
{
    if (!g_engine.window || g_engine.headless) return;
    g_engine.fullscreen = on;
    SDL_SetWindowFullscreen(g_engine.window, on ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
    SDL_ShowCursor(on ? SDL_DISABLE : SDL_ENABLE);
}

static double default_scale(void)
{
    SDL_Rect ub;
    if (SDL_GetDisplayUsableBounds(0, &ub) != 0) return 1.0;
    double s = fmin(ub.w * 0.92 / GAME_W, ub.h * 0.92 / GAME_H);
    s = floor(s * 4.0) / 4.0; /* quarter steps */
    if (s < 0.5) s = 0.5;
    if (s > 3.0) s = 3.0;
    return s;
}

int main(int argc, char **argv)
{
    const char *data_override = NULL;
    bool software = false, vsync = true, mute = false, realtime = false;
    double scale = 0.0;
    long max_frames = 0;
    static char *lua_args[128];
    int nlua = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--data") && i + 1 < argc) data_override = argv[++i];
        else if (!strcmp(a, "--fullscreen")) g_engine.fullscreen = true;
        else if (!strcmp(a, "--scale") && i + 1 < argc) scale = atof(argv[++i]);
        else if (!strcmp(a, "--software")) software = true;
        else if (!strcmp(a, "--no-vsync")) vsync = false;
        else if (!strcmp(a, "--mute")) mute = true;
        else if (!strcmp(a, "--headless")) g_engine.headless = true;
        else if (!strcmp(a, "--realtime")) realtime = true;
        else if (!strcmp(a, "--frames") && i + 1 < argc) max_frames = atol(argv[++i]);
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(a, "--")) { while (++i < argc && nlua < 128) lua_args[nlua++] = argv[i]; }
        else if (nlua < 128) lua_args[nlua++] = argv[i];
    }
    g_engine.argc = nlua;
    g_engine.argv = lua_args;

    if (g_engine.headless) {
        /* SDL2 and SDL3 (sdl2-compat) spell these differently */
        SDL_setenv("SDL_VIDEODRIVER", "offscreen", 1);
        SDL_setenv("SDL_VIDEO_DRIVER", "offscreen", 1);
        software = true;
        vsync = false;
        mute = true;
        g_engine.fullscreen = false;
    }

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    if (!g_engine.headless && SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) != 0)
        SDL_Log("game controllers unavailable: %s", SDL_GetError());

    {
        char *pref = SDL_GetPrefPath("buyo-buyo", "buyo-buyo");
        if (pref) {
            snprintf(g_engine.pref_dir, sizeof g_engine.pref_dir, "%s", pref);
            SDL_free(pref);
        }
    }

    if (!find_data_dir(data_override)) {
        fprintf(stderr, "error: cannot find the game scripts (main.lua). Use --data DIR.\n");
        SDL_Quit();
        return 1;
    }

    int ww = GAME_W, wh = GAME_H;
    if (!g_engine.headless) {
        if (scale <= 0.0) scale = default_scale();
        ww = (int)(GAME_W * scale);
        wh = (int)(GAME_H * scale);
    }

    Uint32 wflags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
    if (g_engine.fullscreen) wflags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    g_engine.window = SDL_CreateWindow("Buyo Buyo", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                       ww, wh, wflags);
    if (!g_engine.window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_SetWindowMinimumSize(g_engine.window, GAME_W / 4, GAME_H / 4);
    SDL_StopTextInput(); /* SDL2 starts with text input on; Lua enables it when needed */
    if (g_engine.fullscreen) SDL_ShowCursor(SDL_DISABLE);

    if (!gfx_init(g_engine.window, software, vsync)) {
        SDL_DestroyWindow(g_engine.window);
        SDL_Quit();
        return 1;
    }
    audio_init(!mute);
    input_init();
    script_init();

    const double step = 1.0 / TICK_HZ;
    const double freq = (double)SDL_GetPerformanceFrequency();
    Uint64 last = SDL_GetPerformanceCounter();
    double acc = 0.0;
    long frames = 0;
    bool running = true;
    bool had_focus = false;

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
            case SDL_QUIT:
                running = false;
                break;
            case SDL_KEYDOWN: {
                SDL_Keycode k = e.key.keysym.sym;
                bool alt = (e.key.keysym.mod & KMOD_ALT) != 0;
                if (!e.key.repeat && (k == SDLK_F11 || (alt && (k == SDLK_RETURN || k == SDLK_KP_ENTER)))) {
                    engine_set_fullscreen(!g_engine.fullscreen);
                } else if (!e.key.repeat && k == SDLK_F5) {
                    script_reload();
                } else if (!e.key.repeat && k == SDLK_F12) {
                    char path[64];
                    snprintf(path, sizeof path, "buyo-shot-%ld.bmp", frames);
                    gfx_request_screenshot(path);
                    SDL_Log("screenshot: %s", path);
                } else {
                    script_key(e.key.keysym.scancode, true, e.key.repeat != 0);
                }
                break;
            }
            case SDL_KEYUP:
                script_key(e.key.keysym.scancode, false, false);
                break;
            case SDL_TEXTINPUT:
                script_text(e.text.text);
                break;
            case SDL_WINDOWEVENT:
                /* only report focus loss after we actually had focus: some
                 * compositors (and the offscreen driver) send a spurious
                 * FOCUS_LOST at startup, which would auto-pause the game */
                if (g_engine.headless) break;
                if (e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED) {
                    had_focus = true;
                    script_focus(true);
                } else if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST && had_focus) {
                    script_focus(false);
                }
                break;
            default:
                input_handle_event(&e);
                break;
            }
        }
        if (!running) break;

        Uint64 now = SDL_GetPerformanceCounter();
        double dt = (double)(now - last) / freq;
        last = now;
        if (dt > 0.25) dt = 0.25;
        if (fabs(dt - step) < 0.0015) dt = step; /* absorb vsync jitter */

        int updates = 0;
        if (g_engine.headless && !realtime) {
            script_update(step);
            updates = 1;
            frames++;
        } else {
            acc += dt;
            while (acc >= step && updates < 5) {
                script_update(step);
                acc -= step;
                updates++;
                frames++;
            }
            if (updates == 5) acc = 0.0; /* way behind: drop time instead of spiralling */
        }

        script_draw();
        gfx_end_frame();

        if (max_frames > 0 && frames >= max_frames) running = false;
        if ((!vsync || g_engine.headless) && acc < step && (!g_engine.headless || realtime)) SDL_Delay(1);
    }

    script_quit();
    script_shutdown();
    net_shutdown();
    input_shutdown();
    audio_shutdown();
    gfx_shutdown();
    SDL_DestroyWindow(g_engine.window);
    SDL_Quit();
    return g_engine.failed ? 1 : 0;
}
