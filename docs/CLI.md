# Command line

```
buyo-buyo [engine options] [-- game options]
```

## Engine options

| Option | |
|---|---|
| `--data DIR` | where the engine scripts (`game/`) are (auto-detected) |
| `--fullscreen` | start in fullscreen (toggle any time with **F11** or **Alt+Enter**) |
| `--scale N` | window size as a multiple of 1280x720 (default: fit the screen) |
| `--software` | force the software renderer |
| `--no-vsync` | disable vsync |
| `--mute` | no audio |
| `--headless` | no window and no audio, runs as fast as possible (tests, tools) |
| `--realtime` | with `--headless`: keep real-time 60 Hz pacing (netplay tests) |
| `--frames N` | quit after N frames |
| `-h`, `--help` | help |

## Game options (after `--`)

**Content**

| Option | |
|---|---|
| `--mods DIR` | load an extra content folder (repeatable; loaded after your mods folder) |
| `--no-user-mods` | ignore your personal mods folder (hermetic tests: `make test` uses it) |
| `--check-content` | load every item for real, smoke-test every mode, print a report, exit 1 on errors |
| `--export-skin ID FILE` | write skin `ID` as a PNG sheet (a template to paint over) |

**Jump into a match**

| Option | |
|---|---|
| `--mode cpu\|2p\|watch` | you vs CPU, two local players, or CPU vs CPU |
| `--game-mode ID` | the content mode (default: your last pick, or `tsu`) |
| `--char1 ID`, `--char2 ID` | characters |
| `--stage ID` | stage (default: player 2's home stage) |
| `--skin ID` | puyo skin for both players (default: your setting) |
| `--level N`, `--level2 N` | CPU strength 1-4 (EASY, NORMAL, HARD, MANIAC) |
| `--first-to N` | rounds to win |
| `--seed N` | fixed random seed (same seed = same pieces) |
| `--demo` | a CPU vs CPU demo that ends on any key |

**Online**

| Option | |
|---|---|
| `--host` | open the online screen and wait for a friend |
| `--connect CODE` | connect right away (`CODE`, `ip:port` or `host:port`) |
| `--net-port N` | UDP port (default 7777) |
| `--no-stun` | don't look up the internet address |
| `--net-bot N` | a CPU plays for you online (testing) |
| `--net-sim LAG,JITTER,LOSS` | simulate a bad network: ms, ms, percent (testing) |

**Testing**

| Option | |
|---|---|
| `--test` | run the rules + netplay self-tests and exit |
| `--quit-at-end` | exit when the match ends (prints the result and a checksum) |
| `--turbo N` | simulate N frames per rendered frame |
| `--skip-draw` | don't render (fast headless runs) |
| `--shots F1,F2,...` | save screenshots at those frames |
| `--shot-prefix PATH` | screenshot file prefix |

## Keys

| Key | |
|---|---|
| **F5** | reload all scripts and content (keep editing while the game runs) |
| **F11** / **Alt+Enter** | fullscreen |
| **F12** | screenshot (`buyo-shot-<frame>.bmp` in the current folder) |
| **Esc** / **Enter** | pause (local matches), leave (online) |

## Examples

```sh
# try your new character against the CPU on your new stage
buyo-buyo -- --mode cpu --char1 tomato --stage tomato_farm

# watch two CPUs play your mode, fast, without a window
buyo-buyo --headless -- --mode watch --game-mode my_mode --skip-draw --turbo 8 --quit-at-end

# validate a pack before sharing it
buyo-buyo --headless -- --mods ~/tomato-pack --check-content

# two games on one machine, playing each other over a simulated bad network
buyo-buyo -- --host --net-port 7001 --net-sim 80,30,5 &
buyo-buyo -- --connect 127.0.0.1:7001 --net-port 7002 --net-sim 80,30,5
```
