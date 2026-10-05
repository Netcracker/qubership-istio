#!/usr/bin/env python3
"""Turns tests/sizing/measure.sh output into a Markdown report.

Usage: tests/sizing/report.py <measurements.csv> > report.md

Fits the coefficients of docs/internal/hardware-sizing-model.md from the
measurements and compares them with the values the document uses. Standard
library only, so it runs on a bare CI runner.
"""
import csv
import sys
from collections import defaultdict

# The values docs/internal/hardware-sizing-model.md uses. Keep in sync.
MODEL = {
    "per_cluster_mi": 0.092,
    "gateway_base_mi": 50.0,
    "waypoint_base_mi": 75.0,
    "clusters_per_service": 1.7,
    "clusters_per_waypoint_port": 1.6,
    "startup_margin": 1.3,
}
DEVIATION = 0.10
# Set high on purpose: a measured value below them leaves the model on the safe side.
CONSERVATIVE = {"gateway_base_mi", "waypoint_base_mi", "clusters_per_service", "startup_margin"}


def fit(xs, ys):
    """Least squares y = a + b*x; returns (a, b, r2) or None."""
    n = len(xs)
    if n < 2 or len(set(xs)) < 2:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    b = sxy / sxx
    a = my - b * mx
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot else 1.0
    return a, b, r2


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in ("workers", "services", "ports_per_service", "bound_ports", "referenced",
                  "active_clusters", "heap_mi", "working_set_mi", "peak_mi", "cds_kb", "lds_kb", "rds_kb"):
            r[k] = num(r[k])
    by_exp = defaultdict(list)
    for r in rows:
        by_exp[r["experiment"]].append(r)

    out = []
    p = out.append
    versions = sorted({r["istio_version"] for r in rows})
    p("# Sizing calibration report\n")
    p(f"Istio: {', '.join(versions) or 'unknown'}. Measurements: {len(rows)}.\n")

    found = {}   # coefficient -> measured value
    notes = []

    # 1. gateway, flag off
    gw = [r for r in by_exp["gateway"]]
    if gw:
        f_ws = fit([r["active_clusters"] for r in gw], [r["working_set_mi"] for r in gw])
        f_heap = fit([r["active_clusters"] for r in gw], [r["heap_mi"] for r in gw])
        p("## 1. Gateway against Envoy clusters, flag off\n")
        if f_ws:
            a, b, r2 = f_ws
            found["per_cluster_mi"] = b
            found["gateway_base_mi"] = a
            p(f"- Working set: **{a:.1f} Mi + {b:.4f} Mi per cluster** ({b * 1024:.0f} KiB), R² {r2:.3f}")
        if f_heap:
            a, b, r2 = f_heap
            p(f"- Envoy heap: {a:.1f} Mi + {b:.4f} Mi per cluster, R² {r2:.3f}")
        per_port = {}
        for ports in sorted({r["ports_per_service"] for r in gw}):
            sub = [r for r in gw if r["ports_per_service"] == ports]
            f_cl = fit([r["services"] for r in sub], [r["active_clusters"] for r in sub])
            if f_cl:
                per_port[ports] = f_cl[1]
                p(f"- Services with {ports:.0f} port(s): {f_cl[1]:.2f} Envoy clusters per Service")
        if per_port:
            per_one_port = per_port.get(1.0) or next(iter(per_port.values()))
            p(f"- Clusters per Service port: {per_one_port:.2f}. The model's {MODEL['clusters_per_service']} "
              "clusters per Service also covers several ports and DestinationRule subsets, "
              "which synthetic Services do not have; check it against real clusters")
        p("")

    # 1. gateway, flag on
    gwf = by_exp["gateway-flag"]
    if gwf:
        p("## 1. Gateway with PILOT_FILTER_GATEWAY_CLUSTER_CONFIG\n")
        f_cl = fit([r["referenced"] for r in gwf], [r["active_clusters"] for r in gwf])
        f_ws = fit([r["active_clusters"] for r in gwf], [r["working_set_mi"] for r in gwf])
        for r in gwf:
            p(f"- {r['services']:.0f} Services in the cluster, {r['referenced']:.0f} referenced: "
              f"{r['active_clusters']:.0f} clusters, {r['working_set_mi']:.1f} Mi")
        if f_cl:
            p(f"- Clusters per referenced Service: {f_cl[1]:.2f}")
        if f_ws:
            p(f"- Working set: {f_ws[0]:.1f} Mi + {f_ws[1]:.4f} Mi per cluster, R² {f_ws[2]:.3f}")
        p("")

    # 1. waypoint
    wpp = by_exp["waypoint-ports"]
    if wpp:
        p("## 1. Waypoint against its bound Service ports\n")
        f_cl = fit([r["bound_ports"] for r in wpp], [r["active_clusters"] for r in wpp])
        f_ws = fit([r["active_clusters"] for r in wpp], [r["working_set_mi"] for r in wpp])
        if f_cl:
            found["clusters_per_waypoint_port"] = f_cl[1]
            p(f"- {f_cl[1]:.2f} Envoy clusters per bound Service port, {f_cl[0]:.0f} with none")
            if f_cl[1] < 0.5:
                notes.append("The waypoint added almost no clusters for bound Services without endpoints: "
                             "repeat the waypoint part with Services that have endpoints (on AWS).")
        if f_ws:
            found["waypoint_base_mi"] = f_ws[0]
            p(f"- Working set: **{f_ws[0]:.1f} Mi + {f_ws[1]:.4f} Mi per cluster**, R² {f_ws[2]:.3f}")
        p("")
    wpc = by_exp["waypoint-cluster"]
    if wpc:
        p("## 1. Waypoint against the Services of the cluster\n")
        f = fit([r["services"] for r in wpc], [r["working_set_mi"] for r in wpc])
        f_cl = fit([r["services"] for r in wpc], [r["active_clusters"] for r in wpc])
        if f:
            per_1000 = f[1] * 1000
            p(f"- Working set: {per_1000:+.1f} Mi per 1000 Services elsewhere in the cluster, R² {f[2]:.3f}")
            if abs(per_1000) > 5:
                notes.append(f"The waypoint grows by {per_1000:.1f} Mi per 1000 Services outside its namespace: "
                             "the waypoint formula needs a cluster-size term.")
        if f_cl:
            p(f"- Envoy clusters: {f_cl[1] * 1000:+.1f} per 1000 Services elsewhere")
        p("")
        p("| Services in the cluster | Clusters | Working set, Mi | CDS, kB | LDS, kB | RDS, kB |")
        p("|---|---|---|---|---|---|")
        for r in wpc:
            sizes = [f"{r[k]:g}" if r[k] is not None else "–" for k in ("cds_kb", "lds_kb", "rds_kb")]
            p(f"| {r['services']:g} | {r['active_clusters']:g} | {r['working_set_mi']:g} | " + " | ".join(sizes) + " |")
        p("")

    # 2. Envoy workers
    workers = by_exp["workers"]
    if workers:
        p("## 2. Envoy workers\n")
        p("| CPU limit | Workers | Base, Mi | Per cluster, Mi | Per cluster, KiB |")
        p("|---|---|---|---|---|")
        by_workers = defaultdict(list)
        for r in workers:
            by_workers[(r["cpu_limit"], r["workers"])].append(r)
        for (cpu, workers), sub in sorted(by_workers.items(), key=lambda kv: kv[0][1] or 0):
            f = fit([r["active_clusters"] for r in sub], [r["working_set_mi"] for r in sub])
            if f:
                p(f"| {cpu} | {workers:.0f} | {f[0]:.1f} | {f[1]:.4f} | {f[1] * 1024:.0f} |")
        p("")

    # 3. Startup peak
    startup = by_exp["startup"]
    if startup:
        p("## 3. Startup peak\n")
        ratios = []
        for r in startup:
            if r["peak_mi"] and r["working_set_mi"]:
                ratio = r["peak_mi"] / r["working_set_mi"]
                ratios.append(ratio)
                p(f"- {r['services']:.0f} Services: peak {r['peak_mi']:.1f} Mi, steady {r['working_set_mi']:.1f} Mi, "
                  f"ratio {ratio:.2f}")
            else:
                p(f"- {r['services']:.0f} Services: no peak reading (memory.peak missing)")
        if ratios:
            found["startup_margin"] = max(ratios)
        p("")

    # Comparison
    p("## Against the model\n")
    p("| Coefficient | Model | Measured | Deviation |")
    p("|---|---|---|---|")
    for key, model in MODEL.items():
        if key not in found:
            p(f"| {key} | {model} | not measured | |")
            continue
        got = found[key]
        dev = (got - model) / model
        mark = ""
        if abs(dev) > DEVIATION:
            mark = " model on the safe side" if key in CONSERVATIVE and dev < 0 else " **update**"
        p(f"| {key} | {model} | {got:.4g} | {dev:+.0%}{mark} |")
    p("")
    p(f"Deviations above {DEVIATION:.0%} are marked. Bases, clusters per Service and the margin are set high "
      "on purpose, so a lower measured value leaves the model on the safe side. `clusters_per_service` is not measured here: "
      "synthetic Services have no subsets, so p1 gives clusters per port only.\n")
    if notes:
        p("## Notes\n")
        for n in notes:
            p(f"- {n}")
        p("")

    p("## All measurements\n")
    cols = ["experiment", "proxy", "cpu_limit", "workers", "services", "ports_per_service",
            "bound_ports", "referenced", "flag", "active_clusters", "heap_mi", "working_set_mi", "peak_mi",
            "cds_kb", "lds_kb", "rds_kb"]
    p("| " + " | ".join(cols) + " |")
    p("|" + "---|" * len(cols))
    for r in rows:
        cells = []
        for c in cols:
            v = r[c]
            cells.append(f"{v:g}" if isinstance(v, float) else ("–" if v is None else str(v)))
        p("| " + " | ".join(cells) + " |")

    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: report.py <measurements.csv>")
    main(sys.argv[1])
