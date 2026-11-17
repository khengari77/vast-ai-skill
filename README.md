# vast-ai-skill

An agent skill for renting GPU (or big-CPU) machines on [vast.ai](https://vast.ai) for unattended jobs —
and making sure they **stop billing when the job ends**, even if your laptop, your agent, or the network
is gone.

The organizing idea is one sentence: *the smallest bill that gets the results home safely*. A box bills
from the moment it is created until it is destroyed, so everything here is built around never leaving one
idle: it uploads its own results, verifies them, and destroys itself on **any** exit path.

## What it does

- **Prices the whole job, not the GPU.** Offers are ranked by
  `hours × $/h + GB_in × down$/GB + GB_out × up$/GB`, so a host with cheap GPUs and expensive network
  does not win by accident.
- **Measures the real network** instead of trusting the spec sheet: rent 2–3 candidates, test, keep the
  best, and have the losers destroy themselves.
- **Runs unattended**: `scripts/vast_job.sh` survives success, error, timeout, SIGTERM and SIGKILL-adjacent
  failures; uploads `RESULTS_DIR` to a private Hugging Face repo, verifies every file size, then destroys
  the box with its own restricted API key.
- **Has a laptop-side floor**: `scripts/guard.py --daemon` enforces a dollar cap and a deadline, and
  treats a failed API call as "unknown, retry" — never as "gone".
- **Knows how it breaks**: `references/gotchas.md` is a symptom → cause → fix table collected from real
  runs (2FA expiry, authorized_keys permissions, CUDA 804, cgroup CPU quotas, `pkill -f` killing the
  controller, and more).

## Requirements

- `vastai` CLI (`pip install --user vastai`), an account with credit, and a recent 2FA login for renting.
- `ssh` and `rsync`, `python3` 3.8+.
- Linux or macOS. The scripts avoid GNU-only commands; where a tool is missing (macOS `timeout`,
  `setsid`, BSD `date`/`head`) they fall back rather than fail.
- Optional but recommended: a Hugging Face token and a private results repo, so results survive the loss
  of your laptop.

## Install

With the Skills CLI:

```bash
npx skills add khengari77/vast-ai-skill
```

Or clone it into your agent's skills directory:

```bash
git clone https://github.com/khengari77/vast-ai-skill ~/.claude/skills/vast-ai
```

Other agents use their own skills directory; the skill is plain `SKILL.md` + `scripts/` + `references/`
and has no harness-specific dependencies.

Then check the machine:

```bash
bash ~/.claude/skills/vast-ai/scripts/preflight.sh
```

It reports what is missing (CLI, key, agent, token, writable run dir, credit) and exits non-zero until
the required pieces are there.

## First run

1. `scripts/preflight.sh` — fix the `MISS` lines.
2. Estimate: GPU memory, hours (pad ~30%), GB in/out, disk (largest model + ~50%).
3. Rank on **total** cost:
   ```bash
   python3 scripts/rank_offers.py --hours 3.5 --gb-in 6 --gb-out 0.5 --disk 40 \
       --query 'gpu_ram>=16 cuda_max_good>=13.0'
   ```
4. Show the plan (GPU, hours, GB, itemised cost, hard cap) and get a yes.
5. Rent, write `job.sh` from `examples/job.sh`, launch `scripts/vast_job.sh`, start
   `scripts/guard.py --daemon --cap-usd … --max-hours …`, and check `scripts/status.sh` periodically.
6. Finish by verifying the results and confirming your labelled instance is gone.

`SKILL.md` has the full workflow, the flags, and the traps.

## Configuration

Every machine-specific value is an environment variable with a default (see `examples/env.sh`).

| Variable | Default | What it is |
|---|---|---|
| `VAST_KEY` | `~/.ssh/id_ed25519` | Private key registered on your vast.ai account |
| `VAST_AGENT` | unset (ssh uses `SSH_AUTH_SOCK`) | Agent socket, when the key has a passphrase |
| `RESULTS_DIR` | `/workspace/results` on the box | Where the job writes logs and results |
| `HF_REPO` | unset | Private results repo; **strongly recommended** |
| `HF_TOKEN_FILE` | `/root/.hf_token` on the box | Where the wrapper reads the token (on the laptop, the file you copy from) |
| `VAST_RUNS_DIR` | `~/vast-runs` | Laptop side: guard logs and pulls |

## Recommended: keep results on Hugging Face

Without `HF_REPO`, results exist only on the box. The wrapper then writes `READY_TO_PULL` and waits for
your laptop to pull them before stopping — which works only if your laptop is awake and the link holds.

The durable path is two minutes of setup:

1. Create a **private** repo, e.g. `you/my-project-runs`.
2. Create a **fine-grained, write-only token scoped to that repo** (not an account-wide write token).
3. `export HF_REPO=you/my-project-runs` and copy the token to the box as shown in `SKILL.md` step 5.

On exit the wrapper uploads under `RUN_ID/`, compares every file's size with the Hub, and only then
destroys. If verification fails it **stops** the box instead, keeping the disk alive.

## Safety model

Three independent layers, so one failing never means a runaway bill:

1. **On-box wrapper** (`scripts/vast_job.sh`) — the primary kill switch, armed for any exit path.
2. **Laptop guard** (`scripts/guard.py --daemon`) — cap and deadline, for SIGKILL, host loss and
   forgotten boxes.
3. **A periodic look** (`scripts/status.sh`) — credit, spend, job state, GPU and disk, in one screen.

The skill also assumes accounts are shared: label every instance, and only destroy instances you created
in this session.

## Troubleshooting

`references/gotchas.md`. Most "dead box" reports are a host-key prompt, a missing ssh-agent, or a
2FA session, not a broken host.

## License

MIT — see `LICENSE`.
