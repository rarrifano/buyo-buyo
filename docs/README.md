# The Buyo Buyo Creator's Handbook

Buyo Buyo is a **platform**: the engine runs the versus puzzle battle, and
everything you see and hear - characters, stages, puyo skins, game modes and
music - is *content* that anyone can make and share. Think M.U.G.E.N, but for
falling-blob puzzle battles.

You don't need to compile anything, and you don't need to touch the engine.
A piece of content is a folder with one small Lua file in it (plus any images
or sounds you want). Drop the folder in, press **F5** in the game, done.

## What can I make?

| You want to...                                 | Make a | Guide |
|---|---|---|
| add a new fighter with a portrait, voice and CPU personality | **character** | [CHARACTERS.md](CHARACTERS.md) |
| draw a background, animated or static           | **stage**     | [STAGES.md](STAGES.md) |
| change how the puyos look (pixel art, gems...)  | **skin**      | [SKINS.md](SKINS.md) |
| change the rules: speed, garbage, win conditions | **mode**     | [MODES.md](MODES.md) |
| add songs (chiptune or OGG/WAV files)           | **music**     | [MUSIC.md](MUSIC.md) |

Also useful:

- [GETTING_STARTED.md](GETTING_STARTED.md) - your first mod in 5 minutes,
  where files go, testing, sharing.
- [API.md](API.md) - every function and value content files can use.
- [NETPLAY.md](NETPLAY.md) - playing online, and what content has to match.
- [CLI.md](CLI.md) - command line options (testing tools included).

## The 30-second version

1. Start the game, open **CONTENT**, pick any item (say the character
   *Buyo*), press **Z** and choose **REMIX INTO MY MODS**.
2. A copy appears in your mods folder as `chars/my_buyo/` (the path is shown
   on screen and copied to your clipboard).
3. Open `char.lua` in any text editor. Change `name`, change the colors in
   `paint`, save.
4. Press **F5** in the game. Your character is in the select screen.

Every built-in item is written to be read: the files in `content/` are the
best examples there are.

## Golden rules

- **One folder = one item.** The folder name is the item's id
  (`chars/professor_blu/char.lua` -> id `professor_blu`). Use letters,
  digits, `_` and `-`.
- **Your mods override built-ins with the same id.** A `skins/classic/`
  folder in your mods folder replaces the built-in Classic skin.
- **Broken content never crashes the game.** Errors are listed in
  **CONTENT -> ERRORS** and the item (or just the broken function) is
  disabled. Run `buyo-buyo -- --check-content` to validate everything.
- **Modes must be deterministic** (online play replays them on both
  machines). The other kinds of content are purely visual/audio and can do
  whatever they like. See [MODES.md](MODES.md#determinism).
- **Say who made it.** Every file can carry `author = "you"`; it's shown in
  the select screen and the content browser. Consider adding a
  `LICENSE.txt` to your pack (CC-BY-4.0 is a popular choice for art).
