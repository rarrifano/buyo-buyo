/*
 * Implementation unit for the vendored stb libraries (public domain / MIT).
 * Compiled without warning flags; see third_party/README.md.
 */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_NO_STDIO /* all file access goes through SDL_RWops (UTF-8 paths) */
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"
