#!/usr/bin/env python3
"""Turns tests/sizing/measure.sh output into a Markdown report.

Usage: tests/sizing/report.py <measurements.csv> > report.md

Fits the coefficients of docs/internal/hardware-sizing-model.md from the
measurements of docs/internal/hardware-sizing-calibration.md and compares
them with the values the model uses. Standard library only, so it runs on a
bare CI runner.
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
    "ztunnel_base_mi": 150.0,
    "ztunnel_per_connection_mi": 0.05,
    "istiod_per_pod_mi": 1.5,
    "istiod_per_config_object_mi": 0.5,
}
DEVIATION = 0.10
# Set high on purpose: a measured value below them leaves the model on the safe side.
# clusters_per_waypoint_port is measured on Services without endpoints, which may
# give a waypoint fewer clusters than real ones.
CONSERVATIVE = {"gateway_base_mi", "waypoint_base_mi", "clusters_per_service",
                "clusters_per_waypoint_port", "startup_margin", "ztunnel_base_mi"}
# The trafficReserveMi of the profiles, read against kConn and kReq.
TRAFFIC_RESERVES_MI = (32, 128)


def fit(xs, ys):
    """Least squares y = a + b*x over the pairs where both are known;
    returns (a, b, r2) or None."""
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    xs, ys = [x for x, _ in pairs], [y for _, y in pairs]
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


def fit2(x1s, x2s, ys):
    """Least squares y = a + b1*x1 + b2*x2 over the rows where all are known;
    returns (a, b1, b2, r2) or None."""
    rows = [(1.0, x1, x2, y) for x1, x2, y in zip(x1s, x2s, ys)
            if x1 is not None and x2 is not None and y is not None]
    if len(rows) < 3:
        return None
    # Normal equations, solved by Gaussian elimination.
    m = [[sum(r[i] * r[j] for r in rows) for j in range(3)] + [sum(r[i] * r[3] for r in rows)]
         for i in range(3)]
    for c in range(3):
        piv = max(range(c, 3), key=lambda k: abs(m[k][c]))
        if abs(m[piv][c]) < 1e-12:
            return None
        m[c], m[piv] = m[piv], m[c]
        for k in range(3):
            if k != c:
                f = m[k][c] / m[c][c]
                m[k] = [a - f * b for a, b in zip(m[k], m[c])]
    a, b1, b2 = (m[i][3] / m[i][i] for i in range(3))
    my = sum(r[3] for r in rows) / len(rows)
    ss_tot = sum((r[3] - my) ** 2 for r in rows)
    ss_res = sum((r[3] - (a + b1 * r[1] + b2 * r[2])) ** 2 for r in rows)
    r2 = 1 - ss_res / ss_tot if ss_tot else 1.0
    return a, b1, b2, r2


def cell(v, fmt="{:g}"):
    return "–" if v is None else fmt.format(v)


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
                  "active_clusters", "heap_mi", "allocated_mi", "working_set_mi", "peak_mi",
                  "cds_kb", "lds_kb", "rds_kb", "endpoints_per_service", "hosts", "pods",
                  "connections", "inflight", "payload_kb", "rps", "cpu_m", "workloads",
                  "config_objects", "fake_proxies", "xds_clients", "churn_per_min", "window_s",
                  "cpu_s", "pushes", "convergence_ms", "open_connections", "latency_ms",
                  "sockets", "load_errors_pct"):
            r[k] = num(r.get(k))
    by_exp = defaultdict(list)
    for r in rows:
        by_exp[r["measurement"]].append(r)
    # Rows whose load did not run as asked are shown but left out of the fits.
    # CSVs from before load_ok: a step under load whose proxy used next to no
    # CPU was read after fortio had stopped.
    for r in rows:
        if not r.get("load_ok") and (r["connections"] or 0) > 0 and r["cpu_m"] is not None and r["cpu_m"] < 20:
            r["load_ok"] = "false"
    failed_loads = [r for r in rows if r.get("load_ok") == "false"]

    out = []
    p = out.append
    versions = sorted({r["istio_version"] for r in rows})
    p("# Sizing calibration report\n")
    p(f"Istio: {', '.join(versions) or 'unknown'}. Measurements: {len(rows)}.\n")

    found = {}   # coefficient -> measured value
    notes = []

    # 1. gateway, flag off
    # A gateway restarts with its whole config, so the model is compared with
    # pods that received their config at start: the 1-worker readings of
    # measurements 2 and 3. A pod that grew into the same config holds less.
    fresh = [r for r in by_exp["gateway-workers"] + by_exp["gateway-startup"] if r["workers"] == 1]
    f_fresh = fit([r["active_clusters"] for r in fresh], [r["working_set_mi"] for r in fresh])

    gw = by_exp["gateway-services"]
    if gw or f_fresh:
        f_ws = fit([r["active_clusters"] for r in gw], [r["working_set_mi"] for r in gw])
        f_heap = fit([r["active_clusters"] for r in gw], [r["heap_mi"] for r in gw])
        p("## 1. Envoy memory per cluster\n")
        p("### Gateway against Envoy clusters, flag off\n")
        if f_fresh:
            a, b, r2 = f_fresh
            found["per_cluster_mi"] = b
            found["gateway_base_mi"] = a
            p(f"- Working set of pods that received their config at start (1 worker, measurements 2 and 3): "
              f"**{a:.1f} Mi + {b:.4f} Mi per cluster** ({b * 1024:.0f} KiB), R² {r2:.3f}. Compared with the model")
        if f_ws:
            a, b, r2 = f_ws
            if "per_cluster_mi" not in found:
                found["per_cluster_mi"] = b
                found["gateway_base_mi"] = a
            p(f"- Working set of one pod that grew into the config: {a:.1f} Mi + {b:.4f} Mi per cluster "
              f"({b * 1024:.0f} KiB), R² {r2:.3f}")
        elif not f_fresh:
            p("- Working set: not measured")
        if f_heap:
            a, b, r2 = f_heap
            p(f"- Envoy heap (tcmalloc physical): {a:.1f} Mi + {b:.4f} Mi per cluster, R² {r2:.3f}")
        f_alloc = fit([r["active_clusters"] for r in gw], [r["allocated_mi"] for r in gw])
        if f_alloc:
            a, b, r2 = f_alloc
            p(f"- Envoy heap in use: {a:.1f} Mi + {b:.4f} Mi per cluster, R² {r2:.3f}")
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
    gwf = by_exp["gateway-referenced-services"]
    if gwf:
        p("### Gateway with PILOT_FILTER_GATEWAY_CLUSTER_CONFIG\n")
        f_cl = fit([r["referenced"] for r in gwf], [r["active_clusters"] for r in gwf])
        f_ws = fit([r["active_clusters"] for r in gwf], [r["working_set_mi"] for r in gwf])
        for r in gwf:
            ws = f"{r['working_set_mi']:.1f} Mi" if r["working_set_mi"] is not None else "working set not measured"
            p(f"- {r['services']:.0f} Services in the cluster, {r['referenced']:.0f} referenced: "
              f"{r['active_clusters']:.0f} clusters, {ws}")
        if f_cl:
            p(f"- Clusters per referenced Service: {f_cl[1]:.2f}")
        if f_ws:
            p(f"- Working set: {f_ws[0]:.1f} Mi + {f_ws[1]:.4f} Mi per cluster, R² {f_ws[2]:.3f}")
        p("")

    # 1. waypoint
    wpp = by_exp["waypoint-bound-ports"]
    if wpp:
        p("### Waypoint against its bound Service ports\n")
        f_cl = fit([r["bound_ports"] for r in wpp], [r["active_clusters"] for r in wpp])
        f_ws = fit([r["active_clusters"] for r in wpp], [r["working_set_mi"] for r in wpp])
        if f_cl:
            found["clusters_per_waypoint_port"] = f_cl[1]
            p(f"- {f_cl[1]:.2f} Envoy clusters per bound Service port, {f_cl[0]:.0f} with none")
            if f_cl[1] < 0.5:
                notes.append("The waypoint added almost no clusters for bound Services without endpoints: "
                             "check the clusters of the waypoint in measurement 4, where its Services have endpoints.")
        if f_ws:
            found["waypoint_base_mi"] = f_ws[0]
            p(f"- Working set: **{f_ws[0]:.1f} Mi + {f_ws[1]:.4f} Mi per cluster**, R² {f_ws[2]:.3f}")
        else:
            p("- Working set: not measured")
        f_heap = fit([r["active_clusters"] for r in wpp], [r["heap_mi"] for r in wpp])
        if f_heap:
            p(f"- Envoy heap (tcmalloc physical): {f_heap[0]:.1f} Mi + {f_heap[1]:.4f} Mi per cluster, R² {f_heap[2]:.3f}")
        p("")
    wpc = by_exp["waypoint-cluster-services"]
    if wpc:
        p("### Waypoint against the Services of the cluster\n")
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
        p("| Services in the cluster | Clusters | Working set, Mi | Heap, Mi | CDS, kB | LDS, kB | RDS, kB |")
        p("|---|---|---|---|---|---|---|")
        for r in wpc:
            sizes = [f"{r[k]:g}" if r[k] is not None else "–" for k in ("cds_kb", "lds_kb", "rds_kb")]
            ws = f"{r['working_set_mi']:g}" if r["working_set_mi"] is not None else "–"
            heap = f"{r['heap_mi']:g}" if r["heap_mi"] is not None else "–"
            p(f"| {r['services']:g} | {r['active_clusters']:g} | {ws} | {heap} | " + " | ".join(sizes) + " |")
        p("")

    # 2. Envoy workers
    workers = by_exp["gateway-workers"]
    if workers:
        p("## 2. Gateway against Envoy workers\n")
        p("| CPU limit | Workers | Working set: base, Mi | per cluster, KiB | Heap: base, Mi | per cluster, KiB |")
        p("|---|---|---|---|---|---|")
        by_workers = defaultdict(list)
        for r in workers:
            by_workers[(r["cpu_limit"], r["workers"])].append(r)
        for (cpu, workers), sub in sorted(by_workers.items(), key=lambda kv: kv[0][1] or 0):
            cells = []
            for col in ("working_set_mi", "heap_mi"):
                f = fit([r["active_clusters"] for r in sub], [r[col] for r in sub])
                cells += [f"{f[0]:.1f}", f"{f[1] * 1024:.0f}"] if f else ["–", "–"]
            p(f"| {cpu} | {workers:.0f} | " + " | ".join(cells) + " |")
        per_worker = []
        for (cpu, w), sub in by_workers.items():
            f = fit([r["active_clusters"] for r in sub], [r["working_set_mi"] for r in sub])
            if f and w:
                per_worker.append((w, f[1] * 1024))
        f_w = fit([w for w, _ in per_worker], [k for _, k in per_worker])
        if f_w:
            p(f"\nWorking set per cluster: about {f_w[0]:.0f} KiB + {f_w[1]:.1f} KiB per worker, R² {f_w[2]:.3f}")
        p("")

    # 3. Startup peak
    startup = by_exp["gateway-startup"]
    if startup:
        p("## 3. Gateway startup peak\n")
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
    # Fresh pods with endpoints load more at start: their peak counts too.
    ep_ratios = [(r["peak_mi"] / r["working_set_mi"], r) for r in by_exp["gateway-endpoints"] + by_exp["waypoint-endpoints"]
                 if r["peak_mi"] and r["working_set_mi"]]
    if ep_ratios:
        worst, wr = max(ep_ratios, key=lambda t: t[0])
        if worst > found.get("startup_margin", 0):
            found["startup_margin"] = worst
            notes.append(f"The startup peak is highest with endpoints: {worst:.2f} times the steady working set on the "
                         f"{wr['proxy']} with {wr['endpoints_per_service']:g} endpoints per Service (measurement 4).")

    # 4. Endpoints
    if by_exp["gateway-endpoints"] or by_exp["waypoint-endpoints"]:
        p("## 4. Envoy memory per endpoint\n")
        p("Fresh pods; the Services are the same and only their endpoints change.\n")
        per_cluster = found.get("per_cluster_mi", MODEL["per_cluster_mi"])
        for exp, name in (("gateway-endpoints", "Gateway"), ("waypoint-endpoints", "Waypoint")):
            sub = by_exp[exp]
            if not sub:
                continue
            p(f"### {name}\n")
            p("| Endpoints per Service | Hosts in Envoy | Clusters | Working set, Mi | Peak, Mi | Peak / working set | Heap, Mi | Heap in use, Mi |")
            p("|---|---|---|---|---|---|---|---|")
            for r in sub:
                ratio = r["peak_mi"] / r["working_set_mi"] if r["peak_mi"] and r["working_set_mi"] else None
                p(f"| {cell(r['endpoints_per_service'])} | {cell(r['hosts'])} | {cell(r['active_clusters'])} | "
                  f"{cell(r['working_set_mi'])} | {cell(r['peak_mi'])} | {cell(ratio, '{:.2f}')} | "
                  f"{cell(r['heap_mi'])} | {cell(r['allocated_mi'])} |")
            p("")
            f_ws = fit([r["pods"] for r in sub], [r["working_set_mi"] for r in sub])
            f_al = fit([r["pods"] for r in sub], [r["allocated_mi"] for r in sub])
            if f_ws:
                kib = f_ws[1] * 1024
                found[f"{exp}_kib"] = kib
                p(f"- Working set: **{kib:.1f} KiB per endpoint**, R² {f_ws[2]:.3f}")
                share = 3 * f_ws[1] / per_cluster
                p(f"- At 3 endpoints per Service, endpoints add {share:.0%} to the {per_cluster * 1024:.0f} KiB of a cluster")
                if share > DEVIATION:
                    notes.append(f"{name}: endpoints cost {kib:.1f} KiB each, {share:.0%} of a cluster at 3 per Service: "
                                 "make endpoints per Service an input of the model.")
            if f_al:
                p(f"- Heap in use: {f_al[1] * 1024:.1f} KiB per endpoint, R² {f_al[2]:.3f}")
            p("")

    # 5. Traffic
    if by_exp["gateway-traffic"] or by_exp["waypoint-traffic"]:
        p("## 5. Gateway and waypoint under load\n")
        p("Fresh pod per step, read under load. kConn comes from connections at about one request per "
          "second each, kReq from connections that each hold a request in flight for "
          "two seconds; requests in flight are fortio's rate times its mean latency. Steps whose load failed "
          "(load_ok false: fortio aborted, more than 1% errors, or keep-alive broken) are shown and left out. "
          "CPU on a shared CI runner is indicative only.\n")
        for exp, name in (("gateway-traffic", "Gateway"), ("waypoint-traffic", "Waypoint")):
            sub = by_exp[exp]
            if not sub:
                continue
            p(f"### {name}\n")
            p("| Connections | Sockets | In flight | Body, KiB | Requests/s | Latency, ms | Errors, % | Load ok | "
              "Working set, Mi | Heap in use, Mi | CPU, m |")
            p("|---|---|---|---|---|---|---|---|---|---|---|")
            for r in sub:
                p(f"| {cell(r['connections'])} | {cell(r['sockets'])} | {cell(r['inflight'])} | {cell(r['payload_kb'])} | "
                  f"{cell(r['rps'])} | {cell(r['latency_ms'])} | {cell(r['load_errors_pct'])} | {r.get('load_ok') or '–'} | "
                  f"{cell(r['working_set_mi'])} | {cell(r['allocated_mi'])} | {cell(r['cpu_m'])} |")
            p("")
            sub = [r for r in sub if r.get("load_ok") != "false"]
            small = [r for r in sub if (r["payload_kb"] or 0) <= 1]
            for col, label in (("working_set_mi", "Working set"), ("allocated_mi", "Heap in use")):
                f = fit2([r["connections"] for r in small], [r["inflight"] for r in small], [r[col] for r in small])
                if not f:
                    continue
                a, kc, kr, r2 = f
                p(f"- {label}: {a:.1f} Mi + **{kc * 1024:.1f} KiB per connection** + "
                  f"**{kr * 1024:.1f} KiB per request in flight**, R² {r2:.3f}")
                if col == "working_set_mi":
                    found[f"{exp}_kconn_kib"] = kc * 1024
                    found[f"{exp}_kreq_kib"] = kr * 1024
                    for reserve in TRAFFIC_RESERVES_MI:
                        if kc > 0:
                            p(f"- trafficReserveMi {reserve} covers {reserve / kc:,.0f} idle connections, "
                              f"or {reserve / (kc + kr):,.0f} connections with a request in flight each")
                    big = [r for r in sub if (r["payload_kb"] or 0) > 1 and r["inflight"]]
                    for r in big:
                        if r[col] is None:
                            continue
                        extra = (r[col] - (a + kc * r["connections"] + kr * r["inflight"])) / r["inflight"]
                        p(f"- {r['payload_kb']:g} KiB bodies: {(kr + extra) * 1024:.1f} KiB per request in flight")
            conn = [r for r in sub if not r["inflight"]]
            f_cpu = fit([r["rps"] for r in conn], [r["cpu_m"] for r in conn])
            if f_cpu:
                p(f"- CPU: about {f_cpu[1] * 1000:.0f} millicores per 1000 requests per second, R² {f_cpu[2]:.3f} (indicative)")
            p("")

    # 6. ztunnel
    zt_series = (("ztunnel-mesh-pods", "pods", "pods in the mesh"),
                 ("ztunnel-other-pods", "pods", "pods outside the mesh"),
                 ("ztunnel-services", "services", "Services without endpoints"))
    if any(by_exp[e] for e, _, _ in zt_series) or by_exp["ztunnel-connections"]:
        p("## 6. ztunnel\n")
        p("### Against the size of the cluster\n")
        p("Fresh ztunnel on a real node per step; the pods are fake and on other nodes.\n")
        p("| Series | Pods | Services | Workloads in ztunnel | Working set, Mi |")
        p("|---|---|---|---|---|")
        for exp, _, label in zt_series:
            for r in by_exp[exp]:
                p(f"| {label} | {cell(r['pods'])} | {cell(r['services'])} | {cell(r['workloads'])} | {cell(r['working_set_mi'])} |")
        p("")
        for exp, col, label in zt_series:
            sub = by_exp[exp]
            f = fit([r[col] for r in sub], [r["working_set_mi"] for r in sub])
            if f:
                p(f"- {label}: **{f[1] * 1000:.1f} Mi per 1000**, R² {f[2]:.3f}")
                if exp == "ztunnel-mesh-pods":
                    found["ztunnel_base_mi"] = f[0]
                    found["ztunnel_mi_per_1000_pods"] = f[1] * 1000
        if "ztunnel_mi_per_1000_pods" in found:
            notes.append(f"ztunnel grows by {found['ztunnel_mi_per_1000_pods']:.1f} Mi per 1000 pods of the cluster on "
                         "every node: add the term to ztunnelMemPerNodeMi.")
        conns = by_exp["ztunnel-connections"]
        if conns:
            p("\n### Per connection\n")
            p("client-mesh to echo-direct: the ztunnel of the client node and the ztunnel of the server node, "
              "no waypoint, about one request per second per connection.\n")
            p("| ztunnel | Connections | Sockets | Requests/s | Errors, % | Load ok | Working set, Mi | CPU, m |")
            p("|---|---|---|---|---|---|---|---|")
            for r in conns:
                p(f"| {r['proxy']} | {cell(r['connections'])} | {cell(r['sockets'])} | {cell(r['rps'])} | "
                  f"{cell(r['load_errors_pct'])} | {r.get('load_ok') or '–'} | {cell(r['working_set_mi'])} | {cell(r['cpu_m'])} |")
            p("")
            conns = [r for r in conns if r.get("load_ok") != "false"]
            total = 0.0
            sides = 0
            for side in sorted({r["proxy"] for r in conns}):
                sub = [r for r in conns if r["proxy"] == side]
                f = fit([r["connections"] for r in sub], [r["working_set_mi"] for r in sub])
                if f:
                    total += f[1]
                    sides += 1
                    p(f"- {side}: {f[1] * 1024:.1f} KiB per connection, R² {f[2]:.3f}")
            if sides:
                found["ztunnel_per_connection_mi"] = total
                p(f"- Both ends of a connection together: **{total:.3f} Mi**; the model counts each connection once per node")
        p("")

    # 7. istiod
    size = by_exp["istiod-cluster-size"]
    if size or by_exp["istiod-routes"] or by_exp["istiod-churn"]:
        p("## 7. istiod\n")
        p("Fresh istiod per step for Services, pods and routes. Heap is the Go heap in use right after a forced GC.\n")
        if size:
            p("### Services and pods\n")
            p("| Services | Pods | Working set, Mi | Heap, Mi |")
            p("|---|---|---|---|")
            for r in size:
                p(f"| {cell(r['services'])} | {cell(r['pods'])} | {cell(r['working_set_mi'])} | {cell(r['heap_mi'])} |")
            p("")
            for col, label in (("working_set_mi", "Working set"), ("heap_mi", "Heap")):
                f = fit2([r["services"] for r in size], [r["pods"] for r in size], [r[col] for r in size])
                if f:
                    a, bs, bp, r2 = f
                    p(f"- {label}: {a:.0f} Mi + **{bs * 1024:.0f} KiB per Service** + **{bp * 1024:.0f} KiB per pod**, R² {r2:.3f}")
                    if col == "working_set_mi":
                        found["istiod_per_pod_mi"] = bp
                        found["istiod_per_service_mi"] = bs
            p("")
        routes = by_exp["istiod-routes"]
        if routes:
            p("### HTTPRoutes\n")
            for col, label in (("working_set_mi", "Working set"), ("heap_mi", "Heap")):
                f = fit([r["config_objects"] for r in routes], [r[col] for r in routes])
                if f:
                    p(f"- {label}: **{f[1] * 1024:.0f} KiB per HTTPRoute** of one rule, R² {f[2]:.3f}")
                    if col == "working_set_mi":
                        found["istiod_per_config_object_mi"] = f[1]
            p("")
        for exp, label in (("istiod-ztunnels", "ztunnel"), ("istiod-waypoints", "waypoint")):
            sub = by_exp[exp]
            if not sub:
                continue
            p(f"### Connected {label}s (simulated)\n")
            for col, name in (("working_set_mi", "Working set"), ("heap_mi", "Heap")):
                f = fit([r["fake_proxies"] for r in sub], [r[col] for r in sub])
                if f:
                    p(f"- {name}: **{f[1]:.2f} Mi per connected {label}**, R² {f[2]:.3f}")
            p(f"- at {cell(sub[0]['services'])} Services and {cell(sub[0]['pods'])} pods; "
              + ("each waypoint comes with a namespace, two Services and two pods" if label == "waypoint"
                 else "each ztunnel receives every workload and Service"))
            p("")
        churn = by_exp["istiod-churn"]
        if churn:
            p("### Pod churn\n")
            p("Deployments of two fake pods restarted at a steady rate. CPU seconds are counted by istiod itself; "
              "on a shared runner they are indicative only.\n")
            p("| Restarts/min | Fake ztunnels | Window, s | CPU, s | CPU, cores | Pushes | Convergence, ms |")
            p("|---|---|---|---|---|---|---|")
            idle = {}
            for r in churn:
                cores = r["cpu_s"] / r["window_s"] if r["cpu_s"] is not None and r["window_s"] else None
                if not r["churn_per_min"]:
                    idle[r["fake_proxies"] or 0] = cores
                p(f"| {cell(r['churn_per_min'])} | {cell(r['fake_proxies'])} | {cell(r['window_s'])} | {cell(r['cpu_s'])} | "
                  f"{cell(cores, '{:.2f}')} | {cell(r['pushes'])} | {cell(r['convergence_ms'])} |")
            p("")
            for r in churn:
                if not r["churn_per_min"] or r["cpu_s"] is None or not r["window_s"]:
                    continue
                base = idle.get(0.0, idle.get(0))
                if base is None:
                    continue
                pods_per_s = r["churn_per_min"] * 2 / 60
                extra = r["cpu_s"] / r["window_s"] - base
                p(f"- {r['churn_per_min']:g} restarts/min with {r['fake_proxies'] or 0:g} fake ztunnels: "
                  f"{extra * 1000 / pods_per_s:.0f} CPU milliseconds per replaced pod over the idle CPU without fake ztunnels")
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
        if key in CONSERVATIVE and dev > 0:
            # Set high on purpose, so any measured value above it is unsafe.
            mark = " **update**"
        elif abs(dev) > DEVIATION:
            mark = " model on the safe side" if key in CONSERVATIVE and dev < 0 else " **update**"
        p(f"| {key} | {model} | {got:.4g} | {dev:+.0%}{mark} |")
    p("")
    p(f"Deviations above {DEVIATION:.0%} are marked. Bases, clusters per Service and the margin are set high "
      "on purpose, so a lower measured value leaves the model on the safe side and any higher one is marked. `clusters_per_service` is not measured here: "
      "synthetic Services have no subsets, so the measurements give clusters per port only.\n")
    if failed_loads:
        notes.append(f"{len(failed_loads)} load step(s) did not run as asked and are left out of the fits: "
                     + ", ".join(f"{r['measurement']} {r['proxy']} {r['connections']:g} connections" for r in failed_loads)
                     + ". The fortio lines of the Measure step log say why.")
    if notes:
        p("## Notes\n")
        for n in notes:
            p(f"- {n}")
        p("")

    p("## All measurements\n")
    cols = ["measurement", "proxy", "cpu_limit", "workers", "services", "ports_per_service",
            "bound_ports", "referenced", "flag", "active_clusters", "heap_mi", "allocated_mi",
            "working_set_mi", "peak_mi", "cds_kb", "lds_kb", "rds_kb", "endpoints_per_service",
            "hosts", "pods", "connections", "inflight", "payload_kb", "rps", "cpu_m", "workloads",
            "config_objects", "fake_proxies", "xds_clients", "churn_per_min", "window_s", "cpu_s",
            "pushes", "convergence_ms", "open_connections", "latency_ms", "sockets", "load_errors_pct", "load_ok"]
    # Columns no row has a value in are left out.
    cols = [c for c in cols if any(r.get(c) not in (None, "") for r in rows)]
    p("| " + " | ".join(cols) + " |")
    p("|" + "---|" * len(cols))
    for r in rows:
        cells = []
        for c in cols:
            v = r.get(c)
            cells.append(f"{v:g}" if isinstance(v, float) else ("–" if v is None else str(v)))
        p("| " + " | ".join(cells) + " |")

    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: report.py <measurements.csv>")
    main(sys.argv[1])
