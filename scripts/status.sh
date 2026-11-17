#!/usr/bin/env bash
# One status snapshot for the periodic check: account credit, this instance, and the job's on-box state.
#   bash status.sh <instance_id> <ssh_host> <ssh_port> [results_dir=/workspace/results]
# Identity: VAST_KEY (default ~/.ssh/id_ed25519), VAST_AGENT (agent socket, optional).
set -u
. "$(dirname "$0")/lib.sh"
vast_ssh_opts
ID=$1; HOST=$2; PORT=$3; RES=${4:-/workspace/results}
echo "== $(date -u +%FT%TZ) =="
credit=$(vastai show user --raw 2>/dev/null | python3 -c "import json,sys; print('%.2f' % json.load(sys.stdin)['credit'])" 2>/dev/null)
echo "credit: \$${credit:-? (needs 2FA login or the CLI)}"
vastai show instances --raw 2>/dev/null | python3 -c "
import json, sys, time
rows = json.load(sys.stdin)
mine = [r for r in rows if str(r['id']) == '$ID']
others = [f\"{r['id']}({r.get('label') or 'no label'})\" for r in rows if str(r['id']) != '$ID']
for r in mine:
    h = (time.time() - r['start_date']) / 3600
    print(f\"instance $ID: {r['actual_status']} up {h:.2f}h ~\${h * r['dph_total']:.2f} at \${r['dph_total']:.3f}/h, gpu {r.get('gpu_util')}%\")
if not mine: print('instance $ID: NOT LISTED (gone)')
if others: print('other instances on the account (not ours unless labelled so):', ', '.join(others))
" 2>/dev/null || echo "instances: listing failed (retry next check; do NOT conclude gone)"
SSH=(ssh "${SSH_OPTS[@]}" -p "$PORT" -o ServerAliveInterval=10 "root@$HOST")
"${SSH[@]}" "RES=$RES bash -s" 2>/dev/null <<'EOF' || echo "box: unreachable (destroyed, stopped, or network)"
echo "STATUS: $(cat $RES/STATUS 2>/dev/null || echo none)"
[ -f $RES/job.log ] && { echo "job.log tail:"; tail -n 5 $RES/job.log | cut -c1-200; }
grep -hiE "traceback|error|out of memory|killed" $RES/job.log 2>/dev/null | tail -n 3 | cut -c1-200 | sed 's/^/  !! /'
nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/gpu: /'
df -h /workspace 2>/dev/null | tail -1 | awk '{print "disk: " $3 " used of " $2}'
EOF
