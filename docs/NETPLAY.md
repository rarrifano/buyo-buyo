# Playing online

Buyo Buyo plays online **peer to peer**: your game talks directly to your
friend's game. There is no server, no account and no matchmaking - you
exchange a short code (by chat, voice, whatever) and play.

The netcode is **rollback**, the same approach used by modern fighting
games: your own moves respond instantly, and the few frames it takes for
your opponent's input to arrive are predicted and corrected on the fly.

## How to connect

1. Both players: main menu -> **ONLINE**. You'll see **YOUR CODE**, e.g.
   `3R5XC-8Q2MA`, plus a LAN code for players on the same network.
2. Send your code to your friend (**COPY MY CODE** puts it on the
   clipboard).
3. One of you types (or pastes with **Ctrl+V**) the other's code into
   **FRIEND'S CODE** and presses **Enter**.
4. Connected: pick characters, the host (chosen automatically) picks the
   mode, stage and rules, and the match starts.

**It doesn't connect?** Have *both* players enter each other's code at
about the same time. Both games then send packets to each other at once,
which opens a path through most home routers (this is called *UDP hole
punching*).

You can also type an address directly: `192.168.1.20:7777` or
`myfriend.example.org:7777`.

### When codes can't get through

Some networks (strict corporate/school firewalls, some mobile carriers,
"double NAT") block direct connections. Options that always work:

- **Same network (LAN)**: use the LAN code.
- **A virtual LAN** such as [Tailscale](https://tailscale.com) or
  [ZeroTier](https://www.zerotier.com): both install it, then use the
  address it gives you (`100.x.y.z:7777`).
- **Port forwarding**: the host forwards **UDP port 7777** on their router
  to their computer; the guest enters the host's public code or
  `public-ip:7777`.

The internet code is found by asking a public *STUN* server "what address
do I have?" (Google / Cloudflare). They only see that one question, never
your game traffic.

## Input delay and what the HUD means

During an online match the middle column shows:

- **PING** - round trip time to your opponent in milliseconds.
- **DELAY** - input delay in frames (1 frame = 16.7 ms). Your inputs are
  applied that many frames later, on both machines. More delay = fewer
  corrections, but the game feels a bit less immediate.
- **ROLLBACK** - how many frames are currently predicted. The engine
  corrects up to 8; beyond that it briefly waits (**WAITING...**).

Change the delay in **ONLINE -> INPUT DELAY** or **SETTINGS**
(0-8, default 2):

| Ping | Suggested delay |
|---|---|
| under 40 ms (same city) | 1 |
| 40-100 ms | 2 |
| 100-160 ms | 3 |
| above 160 ms | 4+ (expect some corrections) |

## What both players need

| Content | Must match? |
|---|---|
| Game version | **yes** - the simulation code must be identical; different versions refuse to connect |
| The mode being played | **yes** - identical `mode.lua` (checked by fingerprint) |
| Characters, stages, skins, music | no - cosmetic; a character you don't have shows up with its name and color |

## Troubleshooting

| Message | Meaning |
|---|---|
| "different game version" | update both games to the same release |
| "you don't have the same '...' mode" | copy the host's mode folder (or pick another mode) |
| CONNECTION LOST | no packets for 6 seconds |
| DESYNC | both games computed different results - a bug or a non-deterministic mode. Report it with both game versions (and the mode, if custom). |

## For developers: how it works

- **Deterministic simulation** (`game/puyo/`): integer math only, fixed
  point positions (`Rules.SUB`), seeded RNGs, no clocks, no `pairs()`
  ordering in logic. Given the same seed and inputs, every machine
  produces bit-identical results.
- **Inputs** are one byte per frame per player (six buttons). The
  simulation derives presses from consecutive frames itself.
- **Rollback** (`game/net/rollback.lua`, GGPO-style): local input is
  delayed by `delay` frames; remote input not yet received is predicted
  (repeat the last one). A snapshot is saved before every frame
  (`Match:save()`); when a real input differs from the prediction, the
  engine loads the snapshot from that frame and re-simulates to the
  present, within one tick. Prediction is capped at 8 frames.
- **Time sync** (`game/net/netgame.lua`): each packet carries the sender's
  frame; the side that runs ahead (compensating half the ping) holds a
  frame now and then so both stay aligned and rollbacks stay short.
- **Packets** (`game/net/session.lua`, UDP): every packet re-sends all
  inputs the peer hasn't acknowledged, so lost packets cost nothing.
  Handshake with random nonces (the lower one hosts), lobby state, start,
  pings, checksums of confirmed frames every 30 frames for desync
  detection. Peer data is decoded with a strict, size-limited decoder.
- **Effects during replays**: sounds and particles triggered while
  re-simulating are de-duplicated, so they fire once.
- **Tests**: `game/tests/netplay_test.lua` runs two peers through a
  simulated network (latency, jitter, loss) and checks the checksums
  against a straight replay; `scripts/netplay-test.sh` plays a full match
  between two real processes over UDP. Both run in `make test`.
