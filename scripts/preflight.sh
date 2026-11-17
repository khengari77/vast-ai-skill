#!/usr/bin/env bash
# Is this machine ready to rent a vast.ai box with this skill? One checklist, no side effects.
#   bash preflight.sh            # also asks the account for the credit balance (needs the CLI)
#   bash preflight.sh --offline  # skip the network call
# Exit status 1 if anything required is missing.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
ONLINE=1; [ "${1:-}" = "--offline" ] && ONLINE=0
BAD=0

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
miss() { printf '  MISS  %s\n' "$*"; BAD=1; }

echo "vast-ai preflight ($(uname -s))"

# --- python ---
if command -v python3 > /dev/null 2>&1; then
  pyv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
  case "$pyv" in
    3.[89]|3.1[0-9]) ok "python3 $pyv" ;;
    *) miss "python3 $pyv (need 3.8+)" ;;
  esac
else miss "python3 (need 3.8+)"; fi

# --- tools ---
for c in ssh rsync vastai; do
  if command -v "$c" > /dev/null 2>&1; then ok "$c ($(command -v "$c"))"; else
    [ "$c" = vastai ] && miss "vastai CLI (pip install --user vastai)" || miss "$c"
  fi
done

# --- portable-timeout fallbacks (informational: lib.sh handles all three) ---
if command -v timeout > /dev/null 2>&1; then ok "timeout (GNU coreutils)"
elif command -v gtimeout > /dev/null 2>&1; then ok "gtimeout (coreutils)"
else warn "no timeout/gtimeout; lib.sh falls back to python (slower to abort)"; fi
command -v setsid > /dev/null 2>&1 || warn "no setsid (not needed: use guard.py --daemon)"

# --- ssh identity ---
KEY=${VAST_KEY:-$HOME/.ssh/id_ed25519}
if [ -f "$KEY" ]; then ok "private key $KEY"
else
  found=$(find "$HOME/.ssh" -maxdepth 1 -type f -name 'id_*' ! -name '*.pub' 2>/dev/null | head -3 | tr '\n' ' ')
  miss "private key $KEY not found${found:+ (candidates: $found)}; set VAST_KEY"
fi
if [ -n "${VAST_AGENT:-}" ]; then
  [ -S "$VAST_AGENT" ] && ok "agent socket $VAST_AGENT" || miss "VAST_AGENT=$VAST_AGENT is not a socket"
elif [ -n "${SSH_AUTH_SOCK:-}" ]; then
  n=$(ssh-add -l 2>/dev/null | grep -vc 'no identities' || true)
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ok "ssh-agent has $n key(s)" || warn "ssh-agent running but empty; passphrase-protected keys need ssh-add"
else warn "no ssh-agent (fine if the key has no passphrase; else set VAST_AGENT)"; fi

# --- results destination (recommended, not required) ---
if [ -n "${HF_TOKEN:-}" ] || [ -f "${HF_TOKEN_FILE:-$HOME/.hf_token}" ] || [ -f "$HOME/.cache/huggingface/token" ]; then
  ok "Hugging Face token found"
else warn "no HF token: set HF_TOKEN or HF_TOKEN_FILE; without it results exist only on the box"
fi
[ -n "${HF_REPO:-}" ] && ok "HF_REPO=$HF_REPO" || warn "HF_REPO unset: the private-results-repo path is off"

RUNS=${VAST_RUNS_DIR:-$HOME/vast-runs}
mkdir -p "$RUNS" 2>/dev/null && [ -w "$RUNS" ] && ok "run dir $RUNS" || miss "run dir $RUNS is not writable"

# --- account (optional network call) ---
if [ "$ONLINE" = 1 ]; then
  out=$(vastai show user --raw 2>&1) || true
  credit=$(printf '%s' "$out" | python3 -c 'import json,sys; print("%.2f" % json.load(sys.stdin)["credit"])' 2>/dev/null)
  if [ -n "${credit:-}" ]; then ok "account credit \$$credit"
  elif printf '%s' "$out" | grep -qi "two factor"; then warn "2FA expired: vastai tfa login --method-type totp -c <code>"
  else warn "could not read the account (check the CLI login)"; fi
fi

echo
if [ "$BAD" = 0 ]; then echo "ready. See README.md for a first run."; else echo "fix the MISS lines above, then rerun."; exit 1; fi
