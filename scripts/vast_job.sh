#!/usr/bin/env bash
# Run a job unattended on a vast.ai box, then save its results and remove the box -- whatever happens.
#
#   RESULTS_DIR=/workspace/results HF_REPO=user/proj-runs RUN_ID=exp1 JOB_TIMEOUT=6h \
#     setsid nohup bash vast_job.sh job.sh > /workspace/wrapper.log 2>&1 < /dev/null &
#
# The job is a script FILE (not a command string), so this controller's own command line never contains the
# job's commands and a stray `pkill -f <job pattern>` can't kill it.
#
# On ANY exit (success, error, JOB_TIMEOUT, SIGTERM/INT/HUP) the EXIT trap:
#   HF_REPO set:   uploads RESULTS_DIR to the private HF repo under RUN_ID/, verifies every file's size on the
#                  Hub (3 attempts), then DESTROYS this instance. Unverified -> STOPS it instead (disk kept).
#   HF_REPO unset: writes RESULTS_DIR/READY_TO_PULL and waits up to PULL_GRACE_MIN minutes for the laptop to
#                  `touch RESULTS_DIR/PULLED`; pulled -> destroy, not pulled -> stop.
# RESULTS_DIR/STATUS always holds one machine-readable line for the monitor.
# Token: /root/.hf_token (mode 600; override HF_TOKEN_FILE) or $HF_TOKEN. Never add `set -x` here.
# SIGKILL / host loss can't be trapped: keep the laptop guard (guard.py) running as the backup.
set -u
JOB=${1:?usage: vast_job.sh job.sh}
JOB=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$JOB")
if [ -z "${RESULTS_DIR:-}" ]; then
  if [ -d /workspace ] && [ -w /workspace ]; then RESULTS_DIR=/workspace/results; else RESULTS_DIR=$PWD/results; fi
  echo "vast_job: RESULTS_DIR unset; using $RESULTS_DIR" >&2
fi
export RESULTS_DIR RUN_ID=${RUN_ID:-run-$(date -u +%Y%m%d-%H%M)}
JOB_TIMEOUT=${JOB_TIMEOUT:-6h}; PULL_GRACE_MIN=${PULL_GRACE_MIN:-30}
HF_REPO=${HF_REPO:-}; HF_TOKEN_FILE=${HF_TOKEN_FILE:-/root/.hf_token}
[ -n "$HF_REPO" ] || echo "vast_job: WARN no HF_REPO: results survive only if the laptop pulls them before the box stops" >&2
export PATH=$PATH:$HOME/.local/bin
mkdir -p "$RESULTS_DIR"
cp "$JOB" "$RESULTS_DIR/" 2>/dev/null

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$RESULTS_DIR/wrapper.log"; }
status() { echo "$(date -u +%FT%TZ) $*" > "$RESULTS_DIR/STATUS"; log "STATUS $*"; }

container_env() {  # vast injects these into PID 1; ssh sessions don't inherit them
  local name=$1
  if [ -n "${!name:-}" ]; then printf '%s' "${!name}"; return; fi
  tr '\0' '\n' < /proc/1/environ | sed -n "s/^$name=//p" | head -1
}
vast() {  # the CLI if present (verified path), else via uvx, else install it
  if command -v vastai > /dev/null; then vastai "$@"; return; fi
  if command -v uvx > /dev/null; then uvx vastai "$@"; return; fi
  python3 -m pip install -q --user vastai > /dev/null 2>&1 && "$HOME/.local/bin/vastai" "$@"
}
remove_box() {  # $1 = destroy | stop
  local id key; id=$(container_env CONTAINER_ID); key=$(container_env CONTAINER_API_KEY)
  [ -n "$id" ] && [ -n "$key" ] || { status "NO CONTAINER KEY: cannot $1 myself; laptop guard must do it"; return 1; }
  sync
  if [ "$1" = destroy ]; then
    status "DONE: destroying instance $id"
    vast destroy instance "$id" -y --api-key "$key" \
      || curl -sf -m 60 -X DELETE "https://console.vast.ai/api/v0/instances/$id/" -H "Authorization: Bearer $key" \
      || { status "DESTROY FAILED: stopping $id"; vast stop instance "$id" --api-key "$key"; }
  else
    status "STOPPING instance $id (disk kept)"
    vast stop instance "$id" --api-key "$key" \
      || curl -sf -m 60 -X PUT "https://console.vast.ai/api/v0/instances/$id/" -H "Authorization: Bearer $key" \
           -H "Content-Type: application/json" -d '{"state": "stopped"}'
  fi
}

upload_verified() {
  python3 -c "import huggingface_hub" 2>/dev/null || python3 -m pip install -q huggingface_hub > /dev/null 2>&1 \
    || pip install -q huggingface_hub > /dev/null 2>&1
  python3 - "$RESULTS_DIR" "$RUN_ID" "$HF_REPO" "$HF_TOKEN_FILE" <<'PY'
import os, sys
from pathlib import Path
from huggingface_hub import HfApi
out, run_id, repo, tok_file = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
token = tok_file.read_text().strip() if tok_file.exists() else os.environ.get("HF_TOKEN")
api = HfApi(token=token)
api.create_repo(repo, private=True, exist_ok=True)
api.upload_folder(folder_path=out, path_in_repo=run_id, repo_id=repo, commit_message=f"{run_id}: results")
local = {str(p.relative_to(out)): p.stat().st_size for p in out.rglob("*") if p.is_file()}
remote = {f.path[len(run_id) + 1:]: f.size for f in api.list_repo_tree(repo, path_in_repo=run_id, recursive=True)
          if getattr(f, "size", None) is not None}
# STATUS/wrapper.log keep changing while we upload; everything else must match exactly
bad = [k for k, v in local.items() if remote.get(k) != v and k not in ("STATUS", "wrapper.log")]
print(f"uploaded {len(local)} files to {repo}/{run_id}; mismatched: {bad}")
sys.exit(1 if bad else 0)
PY
}

finish() {
  local code=$?
  trap - EXIT TERM INT HUP
  echo "$code" > "$RESULTS_DIR/EXIT_CODE"
  if [ -n "$HF_REPO" ]; then
    status "FINISHING (job exit $code): uploading to $HF_REPO/$RUN_ID"
    for attempt in 1 2 3; do
      if upload_verified >> "$RESULTS_DIR/wrapper.log" 2>&1; then remove_box destroy; return; fi
      log "upload attempt $attempt failed; retrying in 60s"; sleep 60
    done
    status "UPLOAD NOT VERIFIED (job exit $code)"
    remove_box stop
  else
    status "READY_TO_PULL (job exit $code): waiting up to ${PULL_GRACE_MIN}m for $RESULTS_DIR/PULLED"
    touch "$RESULTS_DIR/READY_TO_PULL"
    for _ in $(seq $((PULL_GRACE_MIN * 6))); do
      [ -e "$RESULTS_DIR/PULLED" ] && { remove_box destroy; return; }
      sleep 10
    done
    remove_box stop
  fi
}
trap finish EXIT
trap 'exit 143' TERM INT HUP   # make signals go through the EXIT trap

status "RUNNING $RUN_ID: $(basename "$JOB") (hard cap $JOB_TIMEOUT)"
cd "$(dirname "$JOB")" || exit 1
timeout --signal=TERM --kill-after=5m "$JOB_TIMEOUT" bash "$JOB" >> "$RESULTS_DIR/job.log" 2>&1
rc=$?
[ $rc = 124 ] && log "job hit JOB_TIMEOUT=$JOB_TIMEOUT"
exit $rc
