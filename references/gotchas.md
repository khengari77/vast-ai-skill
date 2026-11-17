# vast.ai failure modes and fixes

Each entry was hit for real and cost time or money. Symptom first, then the cause and the fix.

## Renting and account

| Symptom | Cause | Fix |
|---|---|---|
| 401 "requires Two Factor Authentication" on create | The 2FA session expired (about a day) | Ask the user to run `vastai tfa login --method-type totp -c <code>` in their own shell. For an email code, `vastai tfa send-email` prints a secret, then `vastai tfa login --method-type email --secret <S> -c <code>`. |
| create returns `success: false` with a `new_contract` id | The offer was taken. The box was created *stopped* and its ssh key was never injected. | Destroy it (`-y`) and rent another offer. Don't try attach, detach or reboot. |
| `vastai destroy instance <id>` does nothing | It prompts `[y/N]`, and with no TTY it aborts silently | Always pass `-y`. |
| Instances you don't recognise | The account is shared with other projects | Leave them alone. Before any destroy, check the label, or ssh in and look for your project dir. |
| Balance falls about 2× faster than $/h suggests | Per-GB download pricing (`inet_down_cost`), plus re-downloads after the disk filled | Rank on total cost (`rank_offers.py`). Size the disk properly. Delete each model's HF cache (`~/.cache/huggingface/hub` and `xet`) after use. |
| A 24 GB card OOMs while *loading* a 27-31B int4 model | Peak memory is about 2× the final size when bf16 weights are quantised on the fly, and vLLM reserves ~90% of the card before profiling the KV cache. The finished weights (~15-16 GB) would fit; the load does not | A pre-quantised AWQ/GPTQ checkpoint, batch 1 and a short context can squeeze into 24 GB. Otherwise rent 40-48 GB (A40 or A6000, ~$0.40-0.50/h). |

## SSH

| Symptom | Cause | Fix |
|---|---|---|
| "Permission denied (publickey)" on every call | `VAST_KEY` has a passphrase and is not in an agent, or the key is not registered on the account | `eval "$(ssh-agent -s)"; ssh-add "$VAST_KEY"`, or export `VAST_AGENT` to a persistent socket. Run `scripts/preflight.sh`. |
| "Permission denied" with the key loaded; `vastai logs <id>` shows "bad ownership or modes for /root/.ssh/authorized_keys" | Image or host permissions bug (seen twice with `vllm/vllm-openai`) | Rent with the `--onstart-cmd` from SKILL.md step 4 (wait for the file, then chown and chmod). |
| "Permission denied" only with `-o BatchMode=yes` | The vast gateway rejects BatchMode | Leave it out. Use `ConnectTimeout` and `< /dev/null` instead. |
| "Host key verification failed" on a new box, which looks dead | A strict host-key check on a new host | `-o StrictHostKeyChecking=accept-new`. |
| A slow "Welcome to vast.ai" banner on every call | A new handshake each time | `ControlMaster auto`, `ControlPersist 20m` in a host block. Update HostName and Port for each rental. |
| No ssh answer for minutes | Image pull (can take about 8 minutes) or a bad host | Probe in the background. After about 10 minutes, destroy it and rent another offer. |
| `vastai copy` fails, or a `\| tail` hides relay permission errors | `vastai copy` is broken through the relay and can't read stopped boxes | Use direct `rsync -e "ssh -p PORT"`. |

## On the box

| Symptom | Cause | Fix |
|---|---|---|
| `torch.cuda.is_available()` False, "Error 804 forward compatibility" | The container's CUDA compat `libcuda` stub shadows the host driver | `find / -iname 'libcuda.so*'`, then prefix with `LD_LIBRARY_PATH=<its dir>` (Debian/Ubuntu: `/usr/lib/x86_64-linux-gnu`) |
| A seconds-long LightGBM, OpenMP or ONNX job runs for hours at about 25% CPU | The cgroup CPU quota (`/sys/fs/cgroup/cpu.max`) is far below `nproc`, so threads spin at barriers | `OMP_NUM_THREADS=8 OMP_WAIT_POLICY=PASSIVE taskset -c 0-7 ...`, below the quota. One heavy job at a time. |
| vLLM pip install takes an hour | Slow route from the host to PyPI's CDN | Use the `vllm/vllm-openai:latest` image. |
| A launcher waits forever on a model server | The server died ("Engine core initialization failed", OOM) | The launcher must grep for fatal lines and exit, so the kill switch fires. |
| Seq2seq (AraT5, BART) outputs garbled on the vLLM image | It ships transformers 5.x, which unties AraT5's lm_head and adds no `<s></s>` for Barthez | `python3 -m venv --system-site-packages /root/pv && /root/pv/bin/pip install transformers==4.57.6`. Check against a known output before trusting scores. |
| `TrainingArguments` has no `warmup_ratio` / `save_safetensors` | transformers 5.x API drift | `warmup_steps=int(0.06*total_steps)`. For custom modules, make params contiguous (`p.data = p.data.contiguous().clone()`). |
| "partially initialized module 'litellm'", then "Too many open files" | Lazy-import race in threads, and about 1.7 leaked sockets per call | Import litellm in the main thread first. `ulimit -n 1048576`. |
| `pkill -f "<pattern>"` killed the controller (exit 144, or the EXIT trap fired early) | The controller's or shell's command line contains the pattern | Kill by PID only, for example the python PID whose argv has your run's checkpoint dir. |
| A `pgrep -f X` wait loop never ends | The wrapping `bash -c "...X..."` matches itself | Wait on a marker line or file (`EXIT=`, `STATUS`). |
| A slim image lacks a compiler (packages building from source fail) | No `build-essential` | `apt-get update && apt-get install -y build-essential`. |
| `uv run` uninstalls an extra you synced | Plain `uv run` re-syncs to the default deps | After `uv sync --extra X`, call `.venv/bin/<tool>` directly. `uv` lives in `/root/.local/bin`. |

## Stopping, guards and pulling

| Symptom | Cause | Fix |
|---|---|---|
| `vastai start` says "Required resources are currently unavailable, state change queued" | A stopped box's GPU was rented to someone else | Never rely on restarting. Save results *before* stopping. Treat a stopped box's disk as possibly lost. |
| A laptop guard died silently mid-run | Background tool calls get killed after about 30 minutes, or the terminal closed | `guard.py --daemon` (double-forks; works on macOS too). Watch `guard_<id>.log`. |
| The guard quit early and nobody pulled results | It treated a failed `vastai show instances` call as "gone" | Only "gone" when the call succeeds and the id is missing (`guard.py` does this). |
| The self-destroy fired before evaluation | Something killed the controller (see pkill above) | Kill by PID. Test the job end to end on a tiny slice first. |
| `CONTAINER_API_KEY` is empty in ssh | It's only in PID 1's env | `tr '\0' '\n' < /proc/1/environ \| sed -n 's/^CONTAINER_API_KEY=//p'`. The restricted key *can* destroy its own instance (verified). |
| A 300 MB checkpoint takes more than an hour to pull | The home link to distant hosts can be 50-150 KB/s | Upload from the box to a private HF repo instead. Pull small result files right after each run. Start uploads long before deadlines. |
| rsync "succeeded" but the file is truncated | A broken transfer left a `.<name>.XXXX` partial | Verify with `ls -la`, `du -sh` and a row count or checksum. Don't rely on rsync's exit code alone. |
| Results written to a temp/scratch dir disappeared | Session scratch dirs get wiped | Copy anything worth keeping into the project as soon as it exists. |
| Results were lost while the laptop slept | No `HF_REPO`, so the box stopped and kept only its disk | Set `HF_REPO` to a private repo; the wrapper then uploads and verifies before destroying. |

## Portability (macOS and Linux)

The scripts avoid GNU-only commands on purpose; these are the traps if you edit them.

| Symptom | Cause | Fix |
|---|---|---|
| Throughput numbers look like `…N`, or `head -c 8M` fails | macOS ships BSD `date` (no `%N`) and BSD `head` (no suffixed sizes) | Use `now` / `tmo` from `scripts/lib.sh`; pass byte counts (`8388608`) not `8M` |
| `timeout: command not found` | macOS has no GNU `timeout` | `tmo` falls back to `gtimeout`, then to python |
| `setsid: command not found` | macOS has no `setsid` | `guard.py --daemon`; only the on-box launch uses `setsid`, and boxes are Linux |
