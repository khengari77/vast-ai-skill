#!/usr/bin/env bash
# Measure the real network path from THIS machine to rented vast.ai boxes: 3 ssh round trips and
# 2 rounds of 8 MiB upload + download each. Run it on 2-3 freshly rented candidates and keep the best.
#   bash nettest.sh <instance_id> [<instance_id> ...]
# Identity: VAST_KEY (default ~/.ssh/id_ed25519), VAST_AGENT (agent socket, optional).
set -u
. "$(dirname "$0")/lib.sh"
vast_ssh_opts
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
head -c 8388608 /dev/urandom > "$TMP/rand8M.bin"
rate() { python3 -c "print(int(8192 / max(float('$1'), 1e-3)))"; }   # 8 MiB = 8192 KiB

for id in "$@"; do
  url=$(vastai ssh-url "$id" 2>/dev/null)                      # ssh://root@HOST:PORT
  hp=${url#ssh://root@}; host=${hp%:*}; port=${hp##*:}
  if [ -z "$host" ] || [ "$host" = "$hp" ]; then echo "=== $id: no ssh url ($url)"; continue; fi
  SSH=(ssh "${SSH_OPTS[@]}" -p "$port" -o ServerAliveInterval=10 "root@$host")
  echo "=== $id ($host:$port)"
  lat=()
  for _ in 1 2 3; do
    t0=$(now); if "${SSH[@]}" true < /dev/null 2>/dev/null; then lat+=("$(python3 -c "print(round($(now)-$t0,2))")"); else lat+=(FAIL); fi
  done
  echo "  ssh round trip (s): ${lat[*]}"
  for round in 1 2; do
    t0=$(now); tmo 300 "${SSH[@]}" 'cat > /dev/null' < "$TMP/rand8M.bin" 2>/dev/null; rc=$?
    t=$(python3 -c "print($(now)-$t0)"); up=$([ $rc = 0 ] && rate "$t" || echo "FAIL(rc=$rc)")
    t0=$(now); got=$(tmo 300 "${SSH[@]}" 'head -c 8388608 /dev/urandom' < /dev/null 2>/dev/null | wc -c)
    t=$(python3 -c "print($(now)-$t0)"); down=$([ "$got" = 8388608 ] && rate "$t" || echo "FAIL(got $got B)")
    echo "  round $round: upload $up KB/s, download $down KB/s"
  done
done
