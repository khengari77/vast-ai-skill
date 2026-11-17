#!/usr/bin/env python3
"""Rank vast.ai offers by estimated TOTAL cost of a job, not by $/hour.

  est = hours * dph_total (GPU + the requested disk) + gb_in * inet_down_cost + gb_out * inet_up_cost

  python3 rank_offers.py --hours 3.5 --gb-in 6 --gb-out 0.5 --disk 40 --query 'gpu_ram>=16 cuda_max_good>=13.0'
  python3 rank_offers.py --offers-json saved.json --hours 2   # rank a saved `vastai search offers --raw` dump
"""
import argparse, json, subprocess, sys

BASE = "reliability>0.99 num_gpus=1 verified=true rentable=true direct_port_count>=1"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--query", default="", help="extra vastai search filters, e.g. 'gpu_ram>=24 cuda_max_good>=12.4'")
    ap.add_argument("--no-base", action="store_true", help=f"don't add the default filters: {BASE}")
    ap.add_argument("--hours", type=float, required=True, help="expected wall-clock hours incl. setup")
    ap.add_argument("--gb-in", type=float, default=0.0, help="GB the box downloads (models, data, wheels)")
    ap.add_argument("--gb-out", type=float, default=0.0, help="GB the box uploads (results, checkpoints)")
    ap.add_argument("--disk", type=float, default=40, help="disk GB to price in (vastai --storage)")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--offers-json", help="read offers from this file instead of calling vastai")
    a = ap.parse_args()

    if a.offers_json:
        rows = json.load(open(a.offers_json))
    else:
        q = a.query if a.no_base else f"{BASE} {a.query}".strip()
        if f"disk_space>=" not in q:
            q += f" disk_space>={a.disk:g}"
        p = subprocess.run(["vastai", "search", "offers", q, "--storage", str(a.disk), "-o", "dph_total", "--raw"],
                           capture_output=True, text=True, timeout=120)
        try:
            rows = json.loads(p.stdout)
        except json.JSONDecodeError:
            sys.exit(f"vastai search failed:\n{p.stdout[:500]}\n{p.stderr[:500]}")
    if isinstance(rows, dict):
        rows = rows.get("offers", [])
    if not rows:
        sys.exit("no offers match; loosen the query")

    def parts(r):
        gpu = a.hours * r["dph_total"]
        net = a.gb_in * (r.get("inet_down_cost") or 0) + a.gb_out * (r.get("inet_up_cost") or 0)
        return gpu + net, gpu, net

    rows.sort(key=lambda r: parts(r)[0])
    disk_note = "offers file, disk not re-priced" if a.offers_json else f"incl. {a.disk:g} GB disk"
    print(f"{len(rows)} offers. est = {a.hours}h x dph_total ({disk_note})"
          f" + {a.gb_in} GB x down$/GB + {a.gb_out} GB x up$/GB")
    print(f"{'offer':>9} {'gpu':<14}{'vram':>5} {'$/h':>6} {'dn$/GB':>7} {'up$/GB':>7} {'EST$':>6} {'=gpu':>6} {'+net':>6}"
          f" {'rel':>6} {'dnMbps':>7} {'upMbps':>7} {'cpu':>4} {'ram':>4} {'cuda':>5}  location")
    for r in rows[:a.top]:
        est, gpu, net = parts(r)
        print(f"{r['id']:>9} {r['gpu_name'][:13]:<14}{r['gpu_ram'] / 1024:>4.0f}G {r['dph_total']:>6.3f}"
              f" {r.get('inet_down_cost') or 0:>7.4f} {r.get('inet_up_cost') or 0:>7.4f} {est:>6.2f} {gpu:>6.2f} {net:>6.2f}"
              f" {r.get('reliability2', r.get('reliability', 0)):>6.4f} {r.get('inet_down', 0):>7.0f} {r.get('inet_up', 0):>7.0f}"
              f" {r.get('cpu_cores_effective', 0):>4.0f} {r.get('cpu_ram', 0) / 1024:>3.0f}G {r.get('cuda_max_good', 0):>5}"
              f"  {r.get('geolocation')}")
    print("\nSpec-sheet Mbps is not the path to the user's machine: measure with nettest.sh before moving big files.")


if __name__ == "__main__":
    main()
