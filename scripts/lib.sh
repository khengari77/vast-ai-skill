#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for these scripts: portable timing, portable timeout, and ssh options.
# Source it, don't run it:   . "$(dirname "$0")/lib.sh"
#
# The point is that a stranger's machine works. macOS ships BSD date (no %N), BSD head (no 8M),
# no timeout and no setsid, so nothing here may depend on GNU coreutils.

# High-resolution seconds. BSD date prints a literal N for %N, which silently breaks rate math.
now() { python3 -c 'import time; print(time.time())'; }

# timeout: GNU timeout, then macOS gtimeout (coreutils), then python. Same command line everywhere.
tmo() {  # tmo SECONDS command [args...]
  local secs=$1; shift
  if command -v timeout > /dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  if command -v gtimeout > /dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  python3 -c 'import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$secs" "$@"
}

# Options for ssh to a vast.ai box. Sets the SSH_OPTS array.
#   VAST_KEY    private key (default ~/.ssh/id_ed25519); passed only if the file exists
#   VAST_AGENT  agent socket (optional); otherwise ssh uses SSH_AUTH_SOCK
vast_ssh_opts() {
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o LogLevel=ERROR)
  local key=${VAST_KEY:-$HOME/.ssh/id_ed25519}
  [ -f "$key" ] && SSH_OPTS+=(-i "$key")
  [ -n "${VAST_AGENT:-}" ] && SSH_OPTS+=(-o "IdentityAgent=$VAST_AGENT")
  return 0
}
