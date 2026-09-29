#!/usr/bin/env bash
# End-to-end netplay test: two game processes play a full online match over
# real UDP sockets on this machine (bots at the controls), through a simulated
# network (lag ms, jitter ms, loss %). Passes when both finish the match with
# the same final checksum and without a desync.
#
#   scripts/netplay-test.sh [binary] [lag,jitter,loss]
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
BIN="${1:-./build/buyo-buyo}"
SIM="${2:-50,20,5}"
PORT_A="${PORT_A:-$((7800 + RANDOM % 100))}"
PORT_B="$((PORT_A + 100))"
TIMEOUT="${TIMEOUT:-240}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

common=(--headless --realtime --frames $((TIMEOUT * 60)) --)
"$BIN" "${common[@]}" --host --net-port "$PORT_A" --net-bot 3 --net-sim "$SIM" --no-stun \
       --first-to 1 --skip-draw --quit-at-end >"$tmp/a.log" 2>&1 &
pid_a=$!
sleep 0.5
"$BIN" "${common[@]}" --connect "127.0.0.1:$PORT_A" --net-port "$PORT_B" --net-bot 4 --net-sim "$SIM" --no-stun \
       --first-to 1 --skip-draw --quit-at-end >"$tmp/b.log" 2>&1 &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?

sum_a="$(sed -n 's/.*checksum \([0-9a-f]*\)).*/\1/p' "$tmp/a.log")"
sum_b="$(sed -n 's/.*checksum \([0-9a-f]*\)).*/\1/p' "$tmp/b.log")"
echo "--- host";  grep -E '^\[(match|net|round)\]|DESYNC|error' "$tmp/a.log"
echo "--- guest"; grep -E '^\[(match|net|round)\]|DESYNC|error' "$tmp/b.log"
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] && [ -n "$sum_a" ] && [ "$sum_a" = "$sum_b" ] \
   && ! grep -q DESYNC "$tmp/a.log" "$tmp/b.log"; then
  echo "netplay loopback test (sim $SIM): OK - both peers ended with checksum $sum_a"
  exit 0
fi
echo "netplay loopback test (sim $SIM): FAILED (rc $rc_a/$rc_b, checksums '$sum_a' vs '$sum_b')"
echo "--- host log";  tail -20 "$tmp/a.log"
echo "--- guest log"; tail -20 "$tmp/b.log"
exit 1
