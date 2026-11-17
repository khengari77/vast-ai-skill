#!/usr/bin/env bash
# Runs ON a vast.ai box: destroy (default) or stop THIS instance with the restricted key vast.ai injects into
# every container. CONTAINER_ID / CONTAINER_API_KEY live in PID 1's environment, not in ssh sessions.
#   bash self_destroy.sh            # destroy now
#   bash self_destroy.sh stop       # stop instead (keeps the disk, keeps billing storage)
#   bash self_destroy.sh destroy 90 # destroy after 90 minutes (a crude deadline guard)
set -u
ACTION=${1:-destroy}; DELAY_MIN=${2:-0}
container_env() {
  local name=$1
  if [ -n "${!name:-}" ]; then printf '%s' "${!name}"; return; fi
  tr '\0' '\n' < /proc/1/environ | sed -n "s/^$name=//p" | head -1
}
ID=$(container_env CONTAINER_ID); KEY=$(container_env CONTAINER_API_KEY)
[ -n "$ID" ] && [ -n "$KEY" ] || { echo "no CONTAINER_ID/CONTAINER_API_KEY in /proc/1/environ"; exit 1; }
[ "$DELAY_MIN" -gt 0 ] && { echo "$(date -u +%FT%TZ) $ACTION of $ID armed for $DELAY_MIN min"; sleep $((DELAY_MIN * 60)); }
sync
echo "$(date -u +%FT%TZ) requesting $ACTION of instance $ID"

vast() {  # the CLI if present (verified path), else the REST API it wraps
  if command -v vastai > /dev/null; then vastai "$@"; return; fi
  if command -v uvx > /dev/null || [ -x "$HOME/.local/bin/uvx" ]; then PATH=$HOME/.local/bin:$PATH uvx vastai "$@"; return; fi
  return 127
}
if [ "$ACTION" = stop ]; then
  vast stop instance "$ID" --api-key "$KEY" || curl -sf -m 60 -X PUT "https://console.vast.ai/api/v0/instances/$ID/" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"state": "stopped"}'
else
  vast destroy instance "$ID" -y --api-key "$KEY" || curl -sf -m 60 -X DELETE "https://console.vast.ai/api/v0/instances/$ID/" \
    -H "Authorization: Bearer $KEY"
fi
echo
