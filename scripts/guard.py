#!/usr/bin/env python3
"""Laptop-side backup guard for ONE vast.ai instance. The on-box wrapper is the primary kill switch; this
catches what it can't (SIGKILL, a hung job, a host that never comes up, a forgotten box).

Every --every seconds it logs status and estimated spend, and acts (destroy, or stop with --action stop)
when spend >= --cap-usd or uptime >= --max-hours. It exits only when the instance is CONFIRMED gone:
a failed or garbled API call means "unknown, retry", never "gone" (that bug once left results unpulled).

Start it detached so it outlives terminal and tool timeouts:
  python3 guard.py <id> --cap-usd 2 --max-hours 7 --daemon
--daemon double-forks itself and writes --log (default guard_<id>.log), so it works on macOS too
(which has no `setsid`). Without --daemon it stays in the foreground.
"""
import argparse, json, os, subprocess, sys, time


def vast(*args, timeout=90):
    p = subprocess.run(["vastai", *args], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def lookup(iid):
    """('ok', row) | ('gone', None) | ('unknown', reason). 'gone' only from a successful full listing."""
    try:
        rc, out, err = vast("show", "instances", "--raw")
        rows = json.loads(out)
        if rc != 0 or not isinstance(rows, list):
            return "unknown", f"rc={rc} {err[:120]}"
    except Exception as e:  # timeout, JSON error, network blip
        return "unknown", repr(e)[:120]
    for r in rows:
        if str(r.get("id")) == str(iid):
            return "ok", r
    return "gone", None


def daemonize(log_path):
    """Double-fork and detach stdio. Returns in the grandchild only; the parent exits."""
    pid = os.fork()
    if pid > 0:
        print(f"guard started (pid {pid}); log {log_path}")
        sys.exit(0)
    os.setsid()
    pid = os.fork()
    if pid > 0:
        sys.exit(0)
    os.chdir("/")
    sys.stdout.flush()
    sys.stderr.flush()
    log = open(log_path, "a", buffering=1)
    devnull = open(os.devnull)
    os.dup2(devnull.fileno(), 0)
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("instance")
    ap.add_argument("--cap-usd", type=float, required=True)
    ap.add_argument("--max-hours", type=float, default=None)
    ap.add_argument("--action", choices=["destroy", "stop"], default="destroy")
    ap.add_argument("--every", type=int, default=300, help="seconds between checks")
    ap.add_argument("--daemon", action="store_true", help="detach from the terminal (survives tool timeouts)")
    ap.add_argument("--log", default=None, help="log file for --daemon (default guard_<id>.log)")
    a = ap.parse_args()

    if a.daemon:
        log_path = os.path.abspath(a.log or f"guard_{a.instance}.log")
        daemonize(log_path)

    t0, acted = time.time(), False
    deadline = f"max {a.max_hours}h" if a.max_hours else "no deadline"
    print(f"{time.strftime('%FT%TZ', time.gmtime())} guarding {a.instance}: cap ${a.cap_usd}, "
          f"{deadline}, action {a.action}", flush=True)
    while True:
        state, r = lookup(a.instance)
        stamp = time.strftime("%FT%TZ", time.gmtime())
        if state == "gone":
            print(f"{stamp} instance {a.instance} confirmed gone; guard exiting", flush=True)
            return
        if state == "unknown":
            print(f"{stamp} status unknown ({r}); retrying", flush=True)
        else:
            start = r.get("start_date") or t0
            hours = (time.time() - start) / 3600
            spend = hours * (r.get("dph_total") or 0)
            print(f"{stamp} {r.get('actual_status')} up {hours:.2f}h ${spend:.3f} "
                  f"(${r.get('dph_total', 0):.3f}/h) gpu_util={r.get('gpu_util')}", flush=True)
            if acted and a.action == "stop" and r.get("actual_status") != "running":
                print(f"{stamp} stopped; guard exiting (pull what you can, then destroy it)", flush=True)
                return
            if spend >= a.cap_usd or (a.max_hours and hours >= a.max_hours):
                # repeated every minute until the instance is gone (destroy) or no longer running (stop)
                print(f"{stamp} LIMIT HIT (spend ${spend:.3f}, {hours:.2f}h): {a.action} {a.instance}", flush=True)
                args = ["destroy", "instance", a.instance, "-y"] if a.action == "destroy" else ["stop", "instance", a.instance]
                try:
                    print(vast(*args)[1][-300:], flush=True)
                except Exception as e:
                    print(f"{stamp} {a.action} call failed: {e!r}; will retry", flush=True)
                acted = True
        time.sleep(60 if acted else a.every)


if __name__ == "__main__":
    main()
