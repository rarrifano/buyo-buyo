# Third-party code

Vendored so every platform builds the same way with no extra dependencies
(SDL2 is the only external library).

| Library | Version | License | Used for |
|---|---|---|---|
| [Lua](https://www.lua.org) | 5.4.8 | MIT (`lua/LICENSE`) | scripting VM (game logic, content, netcode) |
| [stb_image](https://github.com/nothings/stb) | 2.30 | Public domain / MIT | PNG, JPG, BMP, TGA loading |
| [stb_image_write](https://github.com/nothings/stb) | 1.16 | Public domain / MIT | PNG export (skin templates) |
| [stb_vorbis](https://github.com/nothings/stb) | 1.22 | Public domain / MIT | OGG Vorbis music & voices |

Local modifications: `lua/luaconf.h` pins `luai_makeseed` to a constant (see
the comment at the end of that file) so string-keyed table iteration order is
identical on every machine - important for deterministic rollback netplay.
`lua.c` and `luac.c` (the standalone interpreter/compiler) were not copied.
