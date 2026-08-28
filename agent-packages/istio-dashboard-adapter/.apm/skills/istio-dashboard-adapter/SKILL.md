---
name: istio-dashboard-adapter
description: Adapt an upstream Istio Grafana dashboard for this distribution. Use when importing or updating istio-control-plane / ztunnel dashboards, adding resource-limit overlays, adding a cluster selector, or deciding whether an empty panel belongs here. Also the record of what already diverges from upstream.
---

# Istio Dashboard Adapter

The dashboards in `helm-templates/qubership-istio/dashboards` start life
as the upstream Istio ones - `pilot-dashboard.gen.json` and
`ztunnel-dashboard.gen.json` from `manifests/addons/dashboards`. Three
things are done to them here, and nothing else.

| | Adaptation | Why |
|---|---|---|
| A | resource-limit overlays | usage without its limit does not say whether a pod is close to eviction |
| B | cluster selector | one Grafana serves several clusters through a federating proxy |
| C | one panel removed | its metric is never produced by this distribution; two others look empty for reasons worth knowing |

**Read this before re-importing a dashboard from a newer Istio
release.** An import overwrites all three, and B touches every query in
the file.

---

## A. Resource-limit overlays

Add a `kube_pod_container_resource_limits` target to the **Memory
Usage** and **CPU Usage** panels, styled as a red, unfilled reference
line.

### A.1 Obtain the source dashboard

- A URL - fetch it.
- Pasted JSON - use it directly.
- A repo file - read it (here they live under
  `helm-templates/qubership-istio/dashboards`).

### A.2 Identify the panels

Find panels by `title` (case-insensitive) or by inspecting
`targets[].expr`:

| Panel  | Title match    | Expr match                          |
|--------|----------------|-------------------------------------|
| Memory | `Memory Usage` | `container_memory_working_set_bytes`|
| CPU    | `CPU Usage`    | `container_cpu_usage_seconds_total` |

From the existing targets, extract the `container` label value (e.g.
`discovery`) and the `pod` regex pattern (e.g. `istiod-.*`). Reuse those
same values in the limit queries — do not invent new ones.

### A.3 Apply the memory limit overlay

Add to `targets[]` of the memory panel, using the next unused `refId`:

```json
{
  "datasource": { "type": "prometheus", "uid": "$datasource" },
  "alias": "limit",
  "expr": "kube_pod_container_resource_limits{container=\"<CONTAINER>\",pod=~\"<POD_PATTERN>\",resource=\"memory\"}",
  "legendFormat": "Memory Limit ({{pod}})",
  "refId": "F"
}
```

Add the matching entry to `fieldConfig.overrides[]` (match the `refId`
you used):

```json
{
  "matcher": { "id": "byFrameRefID", "options": "F" },
  "properties": [
    { "id": "custom.lineWidth", "value": 2 },
    { "id": "custom.fillOpacity", "value": 0 },
    { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }
  ]
}
```

### A.4 Apply the CPU limit overlay

Reuse the same target and override shape on the CPU panel, changing only:

- `resource` → `"cpu"`
- `legendFormat` → `"CPU Limit ({{pod}})"`
- `refId` → the next unused letter (commonly `B`), in both the target
  and its `byFrameRefID` override

The red-line override properties (`lineWidth`, `fillOpacity`, `color`)
are identical to the memory override.

### A.5 Preserve everything else

Within this adaptation, do not touch any other panel or the top-level
fields `uid`, `title`, `schemaVersion`, `time`, `refresh`, `__inputs`,
`__requires`. The only changes are the two added targets and their two
overrides. `templating` belongs to adaptation B and is not touched
here.

---

## B. Cluster selector

One Grafana serves several clusters, federated by a proxy that stamps a
`cluster` label onto the series it forwards. The dashboards need a
selector for it, and every query has to honour the selection.

### B.1 The variable

Replace the `cluster` entry of `templating.list`, or add it, with
exactly this. It is the shape the other dashboards in this Grafana use,
and matching them is the point - a variable that behaves differently
from its neighbours is worse than none.

```json
{
  "current": { "isNone": true, "selected": false, "text": "None", "value": "" },
  "datasource": { "type": "prometheus", "uid": "$datasource" },
  "definition": "label_values(up, cluster)",
  "hide": 0,
  "includeAll": false,
  "multi": false,
  "name": "cluster",
  "query": { "query": "label_values(up, cluster)", "refId": "StandardVariableQuery" },
  "refresh": 1,
  "sort": 0,
  "type": "query"
}
```

Three decisions in it are not cosmetic.

**Scoped to `up`, not bare `label_values(cluster)`.** A bare lookup
returns every value of the label from every metric in the datasource,
and `cluster` is not a reserved word: Infinispan exports its own cluster
name under the same label, so an unscoped list offers cluster names that
have nothing to do with Kubernetes. Picking one blanks every panel.
`up` exists for every scrape target and carries only the topology label.

**No All, no multi.** Selecting several clusters would sum series from
different clusters into one line, and the panels here are per-process
gauges: memory of "istiod" across two clusters is not a number that
means anything.

**`isNone` rather than a default value.** Where the federating proxy is
absent the label does not exist, the list comes back empty and the
variable resolves to `""`. That is deliberate: in PromQL `cluster=""`
matches series that carry no `cluster` label at all, so the panels keep
working on a single-cluster installation with no special case.

### B.2 Every query

Add the selector to every `expr` in the file, inside the existing label
set, as the first matcher:

```
sum by (pod) (container_memory_working_set_bytes{cluster="$cluster", container="discovery", pod=~"istiod-.*"})
```

**Exact match, never `cluster=~"$cluster"`.** A regex match is only
needed for an All value that expands to `.*`, and there is no All here.
Leaving the regex form invites someone to re-add All later.

Miss one query and that panel silently ignores the selection - it will
show another cluster's data while the rest of the dashboard shows the
selected one. After editing, assert that the count of `cluster="$cluster"`
equals the count of `expr` fields, and that `cluster=~` appears nowhere.

---

## C. Panels: one removed, two kept for different reasons

Three panels on the control-plane dashboard show nothing here, and the
reasons differ. Only one of them is deleted.

### C.1 Injection is removed - ambient never injects a sidecar

`sidecar_injection_success_total` and `sidecar_injection_failure_total`
are current metric names and they work - but only the sidecar injection
webhook ever records them. This distribution runs **ambient** mesh only,
so no sidecar is ever injected and the counters are never created.

It is deleted rather than left empty: an empty graph reads as "nothing
is wrong", which is the opposite of what a metric that can never exist
means.

Restore this panel if a distribution ever ships sidecar mode.

### C.2 Closing the layout after a removal

Removing a panel leaves a hole; the row does not reflow by itself.
Injection shared a row with Validation at `w: 12`, so Validation becomes
`w: 24`.

### C.3 Push Errors is kept, although it cannot fill either

Upstream queries `pilot_total_xds_rejects` and
`pilot_total_xds_internal_errors`. Neither is defined in Istio 1.30:
they are absent from `pilot/pkg/xds/monitoring.go`, and a running istiod
exposes neither among its metrics. `pilot_xds_pushes` carries only
success types - `cds`, `eds`, `lds`, `rds`, `wads`, `wds`.

**This is an upstream defect, not a local one.** The dashboard shipped by
Istio itself queries the same two metrics. Deleting the panel here would
fix the symptom in a fork and leave the cause upstream, and every later
import would have to remember to delete it again.

So it stays as upstream has it, and the fix is expected to come from
upstream. Track the issue there; when the panel is corrected upstream, an
import brings the correction with it and this note goes away.

### C.4 Validation is kept, and here is why it looks empty

`galley_validation_passed` and `galley_validation_failed` are current,
and they do fire under ambient: the validating webhook checks Istio
custom resources whatever the data plane is.

They are absent until the first admission request, because Istio
registers these counters lazily. So on a quiet cluster the panel is
empty and that is correct - nobody has applied an Istio resource since
istiod started. It fills the moment somebody does.

To make it show data on demand, note the asymmetry in the webhook
server: `reportValidationPass` records on a dry run too, while
`reportValidationFailed` returns early when the request is a dry run.

- **Success line** - `kubectl apply --dry-run=server` any valid Istio
  resource. Nothing is created and the counter appears.
- **Failure line** - a real `kubectl apply` of a resource that passes
  CRD schema validation but fails Istio's own, for instance a `Sidecar`
  whose `egress.hosts` entry is not in `namespace/host` form. The
  webhook rejects it, so nothing is created either, and the counter
  appears.

A schema-invalid resource does not reach the webhook at all and moves
neither counter.

---

## Reference values

| Dashboard                    | Container     | Pod pattern  |
|------------------------------|---------------|--------------|
| Istio control plane (istiod) | `discovery`   | `istiod-.*`  |
| Istio ztunnel                | `istio-proxy` | `ztunnel-.*` |
| Generic k8s app              | app name      | `<app>-.*`   |

Both Istio dashboards use the same `Memory Usage` / `CPU Usage` panel
titles, so the panel-identification step holds across them; only the
`container` / `pod` selectors differ. For the control-plane dashboard
(grafana.com/api/dashboards/7645) the memory panel is id 4 and the CPU
panel is id 6 — panel ids are not stable across dashboards, so match by
title or `expr`, not by id.

## Common pitfalls

- **Reusing an in-use `refId`** — overwrites an existing target. Always
  pick the next unused letter and reference it in the override.
- **Mismatched `container`/`pod` selectors** — the limit line will not
  align with the usage series. Copy the labels from the panel's own
  existing target rather than guessing.
- **Forgetting the override** — without the `byFrameRefID` entry the
  limit series renders as a filled area like the usage series instead of
  a thin red reference line.
- **Re-importing from a newer Istio release and keeping the result.** An
  import returns all three adaptations to upstream: the limit targets go,
  every `cluster="$cluster"` goes, and the removed panel comes back.
  Diff the import against the file in the repo before committing it.
- **Leaving one query without the cluster selector.** That panel ignores
  the dropdown and shows another cluster's data next to panels that
  honour it, with nothing reporting an error.
- **Deleting a panel and leaving the hole.** Grafana does not reflow the
  row; the remaining panels must be widened by hand.
- **Reading an empty panel as healthy.** That is why Injection was
  deleted. Push Errors is empty for the same reason and is kept anyway -
  see C.3, the difference is whose defect it is.
