#!/usr/bin/env bash
# Template for the job script that vast_job.sh runs. Copy it and replace the steps.
# Everything under $RESULTS_DIR is uploaded (or pulled) after the run, whatever the exit code.
set -euo pipefail
: "${RESULTS_DIR:?set by vast_job.sh}"

log() { echo "== $* ==" >> "$RESULTS_DIR/job.log"; }

log "start $(date -u +%FT%TZ)"
nvidia-smi >> "$RESULTS_DIR/job.log" 2>&1
python3 -c "import torch; print('cuda', torch.cuda.is_available())" >> "$RESULTS_DIR/job.log" 2>&1

# Keep small results (metrics, eval files, logs) here as soon as they exist: they must never
# depend on a large upload succeeding.
log "train"
python3 train.py --out "$RESULTS_DIR/metrics.json" >> "$RESULTS_DIR/train.log" 2>&1

log "done $(date -u +%FT%TZ)"

# If the job starts a server, do not wait on it forever: a dead server must exit this script,
# or the kill switch never fires. Example:
#   python3 serve.py > "$RESULTS_DIR/serve.log" 2>&1 &
#   for i in $(seq 120); do
#     grep -qiE 'engine core initialization failed|out of memory' "$RESULTS_DIR/serve.log" && exit 1
#     curl -sf localhost:8000/health > /dev/null && break
#     sleep 5
#   done
#   <run the evaluation against localhost:8000>
