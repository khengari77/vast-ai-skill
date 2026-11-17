# Changelog

## v0.1.0 — 2026-11-17

First public release.

- Machine-agnostic pass: no personal paths or key names, configuration through environment variables
  with defaults (`VAST_KEY`, `VAST_AGENT`, `RESULTS_DIR`, `HF_REPO`, `HF_TOKEN_FILE`, `VAST_RUNS_DIR`).
- Removal of harness-specific monitoring: the periodic check is any scheduler, background task or manual
  run of `scripts/status.sh`; `scripts/guard.py` remains the automated floor.
- Portability: `scripts/lib.sh` provides portable timing, timeout (GNU `timeout` → `gtimeout` → python)
  and ssh options; BSD `date`/`head` and the missing `setsid` on macOS are handled.
- `scripts/guard.py --daemon` double-forks and logs to `guard_<id>.log`.
- New `scripts/preflight.sh`: one checklist for CLI, key, agent, token, run dir and credit.
- `scripts/vast_job.sh`: `RESULTS_DIR` defaults sensibly, warns loudly when `HF_REPO` is unset, and no
  longer needs `readlink -f`.
- `scripts/rank_offers.py`: no longer claims a disk was priced when ranking a saved offers file.
- Docs: README, LICENSE (MIT), `examples/job.sh`, `examples/env.sh`, and a portability section in
  `references/gotchas.md`.
