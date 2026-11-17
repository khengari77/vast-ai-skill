---
name: vast-ai
description: Rent and run GPU (or big-CPU) jobs on vast.ai at minimum total cost with automatic shutdown. Covers budget approval, ranking offers by total cost (GPU + disk + per-GB network), a measured network test, renting with the right image and flags, SSH setup, an unattended job wrapper that uploads results to Hugging Face, verifies them and self-destroys the box, a laptop backup guard, a periodic credit and progress check, and the known failure modes. Use whenever a task needs a vast.ai instance, the vastai CLI, a rented GPU, or stopping or destroying one — and before writing any vastai command by hand, or when a rented box is idle, unreachable, or still billing.
compatibility: Linux or macOS. Needs the vastai CLI (pip install --user vastai), ssh and rsync, python3 (3.8+). Uploading results needs a Hugging Face token.
---

# vast.ai: cheap, watched, self-terminating GPU runs

The goal on every run is **the smallest bill that gets the results home safely**. A box costs money from the
moment it is created until it is destroyed, whether it is working or not. So everything below is built so that
a box never sits idle: it uploads its own results and destroys itself when its job ends, even if this
agent or the user's laptop is gone.

Scripts live in `scripts/` next to this file. Failure modes and their fixes are in
[references/gotchas.md](references/gotchas.md). Read it when something looks broken: most vast.ai failures look
like something else (a dead box is often just a host-key prompt or a missing ssh-agent).

## Rules that always apply

1. **Ask once, then own the run.** Before renting, show the plan: the GPU, hours, the GB to download and upload,
   the itemised cost estimate, and the hard cap. Wait for a yes. After that yes, run the whole plan (installs,
   model downloads, retries within budget) without asking again. A paid box waiting on a question is the most
   expensive mistake. New or larger spend needs a new yes.
2. **Accounts are often shared.** Other projects may run instances on the same account. Label every
   instance you create (`--label <project>-<purpose>`), and only stop or destroy instances you created in
   this session. Check `vastai show instances --raw` and the label before any destroy. Never "clean up all
   instances".
3. **Never read secrets files** (`.env`, token files) with cat, grep or a file read, not even for key names. Load
   them in code (`python-dotenv`) and pipe values over stdin. Never `set -x` in scripts that handle tokens.
4. **Destroy, don't just stop.** A stopped box keeps billing for disk. Its GPU can also be rented by someone else,
   so `vastai start` may queue forever and its disk can become unreachable. Pull or upload everything first,
   then destroy. Stop only as the fallback when results could not be saved.
5. **Long waits go in the background.** Use detached processes and marker lines in logs. Never block the
   foreground for minutes, and never wait with `pgrep -f` (it matches its own shell).

## Configuration

Everything machine-specific is an environment variable with a default, so the same skill runs on someone
else's laptop. Set them in your shell, in `examples/env.sh`, or per command. `scripts/preflight.sh`
reports what is missing on this machine.

| Variable | Default | What it is |
|---|---|---|
| `VAST_KEY` | `~/.ssh/id_ed25519` | Private key registered on your vast.ai account |
| `VAST_AGENT` | unset (ssh uses `SSH_AUTH_SOCK`) | Agent socket, when the key has a passphrase |
| `RESULTS_DIR` | `/workspace/results` on the box | Where the job writes logs and results |
| `HF_REPO` | unset | Private results repo. Strongly recommended: without it, results exist only on the box |
| `HF_TOKEN_FILE` | `/root/.hf_token` on the box | Token the laptop writes for the upload |
| `VAST_RUNS_DIR` | `~/vast-runs` | Laptop side: guard and pull logs |

## Workflow

### 0. Pre-flight (once per session)

```bash
bash scripts/preflight.sh
```

It checks python3, the CLI, ssh and rsync, your key (and whether an agent holds it), the results
destination and the account credit. Fix the `MISS` lines before renting.

- **2FA**: renting needs a recent 2FA login. A 401 "requires Two Factor Authentication" means it expired (about a
  day). Ask the user to run `vastai tfa login --method-type totp -c <6-digit code>` in their own shell
  (`--method-type` is required). Search, list and destroy work without it.
- **SSH key**: register one key on the account and point `VAST_KEY` at it (default `~/.ssh/id_ed25519`). If it
  has a passphrase, load it into an agent for the session: `eval "$(ssh-agent -s)"; ssh-add "$VAST_KEY"`. To
  keep one socket across terminals, start `ssh-agent -a ~/.ssh/vast-agent.sock` and
  `export VAST_AGENT=~/.ssh/vast-agent.sock`; the scripts then pass `IdentityAgent` for you. "Permission denied
  (publickey)" means the key is not in the agent or not registered on the account.

### 1. Estimate and get approval

Work out, before searching:
- **GPU memory**: the largest model plus activations. Quantised 27-31B LLMs need a 44 GB or larger card (A40 or
  A6000), and they fail on 24 GB while *loading*. A 2-3M-parameter model fits on any 8 GB card. A BERT-base
  fine-tune fits on a 12 GB card.
- **Hours** of compute, padded by about 30% for setup and the image pull.
- **GB in** (every model, dataset and wheel the box downloads) and **GB out** (what comes back).
- **Disk**: the largest model plus about 50% headroom. Plan to delete each model's HF cache (`hub` and `xet`)
  after its run, or a full disk forces re-downloads that you pay for again.

### 2. Rank offers on total cost

```bash
python3 scripts/rank_offers.py --hours 3.5 --gb-in 6 --gb-out 0.5 --disk 40 \
    --query 'gpu_ram>=16 cuda_max_good>=13.0 cpu_ram>=32'
```

The script adds the defaults `reliability>0.99 num_gpus=1 verified=true rentable=true direct_port_count>=1` and
ranks by `hours × dph_total (includes the disk) + GB_in × inet_down_cost + GB_out × inet_up_cost`.
**Network pricing can equal the GPU bill**: about 180 GB of weights at $0.004/GB cost as much as the A6000 hours
on one run. Prefer hosts with near-zero `inet_down_cost` when downloads are big. Match `cuda_max_good` to the CUDA
version of the wheels (older-driver hosts fail with CUDA 13 wheels). Older GPUs at the same price are worse:
Pascal (10xx) has no fp16 tensor cores. Report the top 3 with each cost component in the approval message.

### 3. Measure the network, don't trust the spec sheet

Advertised bandwidth says nothing about the path to the user's machine (observed: 50-150 KB/s to some hosts,
2-3 MB/s to others). When results or inputs to move are more than a few hundred MB, or a run is long:
rent the 2-3 best offers at once, then run

```bash
bash scripts/nettest.sh <instance_id> [<instance_id> ...]
```

It reports ssh round-trip time and upload/download KB/s. Keep the best box and have the losers destroy
**themselves** with the on-box key (`scripts/self_destroy.sh`), which also rehearses the kill switch.
A test costs a few cents. Skip it for jobs whose results are tiny and go straight to Hugging Face.

### 4. Rent

```bash
vastai create instance <offer_id> --image <image> --disk <GB> --ssh --direct \
  --label <project>-<purpose> --raw \
  --onstart-cmd 'for i in $(seq 60); do [ -s /root/.ssh/authorized_keys ] && break; sleep 2; done; chown -R root:root /root/.ssh; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; mkdir -p /workspace'
```

- Images: `pytorch/pytorch:<ver>-cuda<x>-cudnn9-runtime` (or `-devel`) for training. Use `vllm/vllm-openai:latest`
  for serving LLMs, because pip-installing vLLM on a slow host can take an hour. The vLLM image ships
  transformers 5.x and no pandas.
- **Check the result says `"success": true`.** `success: false` together with a `new_contract` id means a box
  was created *stopped* (the offer was taken). Its ssh key never gets injected. Destroy it (`-y`) and rent
  another offer.
- The `--onstart-cmd` above fixes the "bad ownership or modes for authorized_keys" failure seen on some
  hosts. Append the job's own setup after it (for example `curl -LsSf https://astral.sh/uv/install.sh | sh`).
- Get the address with `vastai ssh-url <id>` (prints `ssh://root@HOST:PORT`). It is new for every rental.
- **Fail fast.** A fresh box can take up to about 8 minutes to answer ssh (image pull). Probe in the
  background every 20 s with `-o StrictHostKeyChecking=accept-new` and **without** `BatchMode=yes` (the vast
  gateway rejects it). If the box is still unreachable after about 10 minutes, or keeps saying "Permission
  denied" for about 2 minutes once it answers, check `vastai logs <id>`, then destroy it and rent another
  offer. Don't nurse a bad host.

Use direct `ssh -p PORT root@HOST` and `rsync -e "ssh -p PORT"`. `vastai copy` is broken (relay permission
errors, and it cannot read stopped boxes). Add an `~/.ssh/config` host block with `ControlMaster auto`,
`ControlPersist 20m` and `IdentityAgent ~/.ssh/vast-agent.sock` to avoid a slow handshake on every call. Update
its HostName and Port for each new rental.

### 5. First minutes on the box (quick checks)

```bash
nvidia-smi; python3 -c "import torch; print(torch.cuda.is_available())"
cat /sys/fs/cgroup/cpu.max          # CPU quota is often far below nproc
df -h /workspace
```

- `torch.cuda.is_available()` is False with "Error 804 forward compatibility": the container's CUDA compat stub
  is shadowing the host driver. Find the real one with `find / -name 'libcuda.so*'` and prefix the command with
  `LD_LIBRARY_PATH=<its directory>` (Debian/Ubuntu images: `/usr/lib/x86_64-linux-gnu`).
- If `cpu.max` shows, say, `1344000 100000` (≈13 cores) on a "56-core" box, cap thread pools below the
  quota: `OMP_NUM_THREADS=8 OMP_WAIT_POLICY=PASSIVE taskset -c 0-7 ...`. Otherwise OpenMP and LightGBM can stall
  for hours.
- Copy the HF token to the box without printing it into this session. Use whichever line matches where the
  token lives, piped straight into ssh:

  ```bash
  # exported in your environment:   printf %s "$HF_TOKEN"
  # .env via python-dotenv:         python3 -c "from dotenv import dotenv_values; print(dotenv_values()['HF_TOKEN'], end='')"
  # pass or another secret store:   pass show hf/token
  <one of those> | ssh ... 'umask 077; cat > /root/.hf_token'
  ```

### 6. Run unattended with the kill switch

Put the job's steps in a script (`job.sh`), ship it and `scripts/vast_job.sh` to the box, then start:

```bash
ssh ... 'cd /workspace && RESULTS_DIR=/workspace/results HF_REPO=<you>/<project>-runs RUN_ID=<run> \
  JOB_TIMEOUT=6h setsid nohup bash vast_job.sh job.sh > /workspace/wrapper.log 2>&1 < /dev/null &'
```

`RESULTS_DIR` defaults to `/workspace/results` when it is unset and `/workspace` is writable, so the
assignment above is only needed when you want a different location.

`vast_job.sh` runs `job.sh` under a hard timeout. On **any** exit (success, error, timeout, SIGTERM) it:
uploads `RESULTS_DIR` to the private HF repo → verifies every file's size on the Hub → **destroys** the box with
its own `CONTAINER_API_KEY`. If verification fails it **stops** the box instead, so the disk survives. With no
`HF_REPO`, it writes `READY_TO_PULL` and waits up to `PULL_GRACE_MIN` (default 30) for the laptop to touch
`$RESULTS_DIR/PULLED`, then destroys. It keeps a one-line status in `$RESULTS_DIR/STATUS` for the monitor.

Inside `job.sh`:
- Write a log per step into `RESULTS_DIR` and keep small results (metrics, eval parquets, logs) there as soon as
  they exist. Big checkpoints go there too, but the small files must never depend on the big upload.
- Fail fast and loud: `set -euo pipefail`. Detect fatal states (for example "Engine core initialization failed"
  from vLLM, or OOM) and exit instead of waiting on a dead server.
- `CONTAINER_ID` and `CONTAINER_API_KEY` exist only in `/proc/1/environ`, not in ssh sessions. The wrapper reads
  them from there.
- **Never `pkill -f <pattern>`** on a job box. The controller's command line can contain the pattern, so this
  kills the controller and fires the upload and destroy early. Stop a sub-run by its PID only.
- If the job starts thread pools that call APIs (litellm or dspy), import litellm once in the main thread before
  spawning, and raise `ulimit -n`.

### 7. Watch it

The on-box wrapper is the primary kill switch. Two layers on the laptop:

1. **The automated floor.** Start the guard detached. `--daemon` double-forks and writes `guard_<id>.log`
   (override with `--log`), so it survives the terminal, tool timeouts and macOS — no `setsid` needed:

   ```bash
   python3 scripts/guard.py <instance_id> --cap-usd 2.00 --max-hours 7 --daemon
   ```

   It logs status and estimated spend every 5 minutes and destroys at the cap or deadline (`--action stop` keeps
   the disk). It treats a failed API call as "unknown, retry", **never** as "gone", and exits only when the
   instance is confirmed absent.

2. **A look every ~10 minutes.** Run `bash scripts/status.sh <id> <host> <port>` however your environment
   allows: a scheduler if your agent has one, a background task, or a manual run. The output is one screen —
   credit, spend, `STATUS`, log errors, GPU utilisation, disk.

Act on problems right away: errors in the logs, GPU at 0% for two checks in a row, spend running ahead of the
estimate. Fix the problem, or pull what exists and destroy. When `STATUS` says `DONE` or the instance is gone,
verify the results and confirm the box is gone (step 8).

### 8. Finish

1. Confirm the results are home: list the files on the HF repo, or run `ls -la` and `du -sh` on what you pulled.
   Check there are no partial `.*.XXXX` rsync files and that row counts match. Don't trust rsync's exit code alone.
2. `vastai show instances --raw`: confirm *your* labelled instances are gone. Destroy any leftovers with
   `vastai destroy instance <id> -y` (without `-y` it silently aborts when there is no TTY).
3. Report the actual spend (credit before minus credit after) next to the estimate.

## Pulling large files home

A consumer or regional home link can be slow (tens of KB/s), so a 300 MB checkpoint can take more than an
hour. Pull small files first and immediately after each run, never batched with the weights. For anything big,
upload from the box to a private HF repo and download from HF instead. Start uploads well before any deadline.
