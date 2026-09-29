/*
 * input: keyboard state + SDL game controllers (hot-pluggable).
 *
 * Lua API:
 *   input.key(name_or_scancode) -> bool      e.g. input.key("Left")
 *   input.scancode(name) -> int
 *   input.pad(slot, button) -> bool          slot 1..4, button "a", "dpleft", ...
 *   input.axis(slot, axis) -> -1..1          "leftx", "lefty", ...
 *   input.pad_connected(slot) -> bool
 *   input.pad_name(slot) -> string|nil
 */
#include "engine.h"

#include <string.h>

#define MAX_PADS 4

static SDL_GameController *pads[MAX_PADS];

static SDL_JoystickID pad_id(SDL_GameController *gc)
{
    return SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(gc));
}

static void open_pad(int device_index)
{
    if (!SDL_IsGameController(device_index)) return;
    SDL_JoystickID id = SDL_JoystickGetDeviceInstanceID(device_index);
    for (int i = 0; i < MAX_PADS; i++)
        if (pads[i] && pad_id(pads[i]) == id) return; /* already open */
    for (int i = 0; i < MAX_PADS; i++) {
        if (!pads[i]) {
            pads[i] = SDL_GameControllerOpen(device_index);
            if (pads[i]) SDL_Log("gamepad %d connected: %s", i + 1, SDL_GameControllerName(pads[i]));
            return;
        }
    }
}

static void close_pad(SDL_JoystickID id)
{
    for (int i = 0; i < MAX_PADS; i++) {
        if (pads[i] && pad_id(pads[i]) == id) {
            SDL_Log("gamepad %d disconnected", i + 1);
            SDL_GameControllerClose(pads[i]);
            pads[i] = NULL;
        }
    }
}

void input_init(void)
{
    if (!SDL_WasInit(SDL_INIT_GAMECONTROLLER)) return;
    for (int i = 0; i < SDL_NumJoysticks(); i++) open_pad(i);
}

void input_shutdown(void)
{
    for (int i = 0; i < MAX_PADS; i++) {
        if (pads[i]) SDL_GameControllerClose(pads[i]);
        pads[i] = NULL;
    }
}

void input_handle_event(const SDL_Event *e)
{
    if (e->type == SDL_CONTROLLERDEVICEADDED) open_pad(e->cdevice.which);
    else if (e->type == SDL_CONTROLLERDEVICEREMOVED) close_pad(e->cdevice.which);
}

static int l_key(lua_State *L)
{
    int sc;
    if (lua_type(L, 1) == LUA_TNUMBER) sc = (int)lua_tointeger(L, 1);
    else sc = (int)SDL_GetScancodeFromName(luaL_checkstring(L, 1));
    int n = 0;
    const Uint8 *ks = SDL_GetKeyboardState(&n);
    lua_pushboolean(L, sc > 0 && sc < n && ks[sc]);
    return 1;
}

static int l_scancode(lua_State *L)
{
    lua_pushinteger(L, (lua_Integer)SDL_GetScancodeFromName(luaL_checkstring(L, 1)));
    return 1;
}

static SDL_GameController *pad_arg(lua_State *L, int i)
{
    lua_Integer slot = luaL_checkinteger(L, i);
    if (slot < 1 || slot > MAX_PADS) return NULL;
    return pads[slot - 1];
}

static int l_pad(lua_State *L)
{
    SDL_GameController *gc = pad_arg(L, 1);
    SDL_GameControllerButton b = SDL_GameControllerGetButtonFromString(luaL_checkstring(L, 2));
    lua_pushboolean(L, gc && b != SDL_CONTROLLER_BUTTON_INVALID && SDL_GameControllerGetButton(gc, b));
    return 1;
}

static int l_axis(lua_State *L)
{
    SDL_GameController *gc = pad_arg(L, 1);
    SDL_GameControllerAxis a = SDL_GameControllerGetAxisFromString(luaL_checkstring(L, 2));
    double v = 0.0;
    if (gc && a != SDL_CONTROLLER_AXIS_INVALID) {
        v = SDL_GameControllerGetAxis(gc, a) / 32767.0;
        if (v < -1.0) v = -1.0;
    }
    lua_pushnumber(L, v);
    return 1;
}

static int l_pad_connected(lua_State *L)
{
    lua_pushboolean(L, pad_arg(L, 1) != NULL);
    return 1;
}

static int l_pad_name(lua_State *L)
{
    SDL_GameController *gc = pad_arg(L, 1);
    const char *name = gc ? SDL_GameControllerName(gc) : NULL;
    if (name) lua_pushstring(L, name);
    else lua_pushnil(L);
    return 1;
}

int luaopen_input(lua_State *L)
{
    static const luaL_Reg fns[] = {
        { "key", l_key }, { "scancode", l_scancode }, { "pad", l_pad }, { "axis", l_axis },
        { "pad_connected", l_pad_connected }, { "pad_name", l_pad_name }, { NULL, NULL },
    };
    luaL_newlib(L, fns);
    lua_pushinteger(L, MAX_PADS);
    lua_setfield(L, -2, "MAX_PADS");
    return 1;
}
