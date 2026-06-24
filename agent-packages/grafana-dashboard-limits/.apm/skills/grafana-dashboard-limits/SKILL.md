---
name: grafana-dashboard-limits
description: Adapt a Grafana dashboard JSON to overlay CPU and memory resource limits on resource-usage panels. Use when adding limit lines to CPU/memory panels, overlaying kube_pod_container_resource_limits, or making an Istio/Kubernetes dashboard show resource limits as a red reference line.
---

# Grafana Dashboard Limits Adapter

Adds CPU and memory resource-limit overlays to Grafana dashboard panels,
using `kube_pod_container_resource_limits` metrics rendered as a red,
unfilled reference line.

Given a Grafana dashboard JSON (a URL, pasted JSON, or a file in the
repo), produce an adapted version where the **Memory Usage** and **CPU
Usage** panels each carry a `kube_pod_container_resource_limits` target
(`resource="memory"` / `resource="cpu"`) styled as a red, unfilled
reference line.

## Process

### 1. Obtain the source dashboard

- A URL → fetch it.
- Pasted JSON → use it directly.
- A repo file → read it (in this repo, dashboards live under
  `helm-templates/qubership-istio/dashboards`).

### 2. Identify the panels

Find panels by `title` (case-insensitive) or by inspecting
`targets[].expr`:

| Panel  | Title match    | Expr match                          |
|--------|----------------|-------------------------------------|
| Memory | `Memory Usage` | `container_memory_working_set_bytes`|
| CPU    | `CPU Usage`    | `container_cpu_usage_seconds_total` |

From the existing targets, extract the `container` label value (e.g.
`discovery`) and the `pod` regex pattern (e.g. `istiod-.*`). Reuse those
same values in the limit queries — do not invent new ones.

### 3. Apply the memory limit overlay

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

### 4. Apply the CPU limit overlay

Reuse the same target and override shape on the CPU panel, changing only:

- `resource` → `"cpu"`
- `legendFormat` → `"CPU Limit ({{pod}})"`
- `refId` → the next unused letter (commonly `B`), in both the target
  and its `byFrameRefID` override

The red-line override properties (`lineWidth`, `fillOpacity`, `color`)
are identical to the memory override.

### 5. Preserve everything else

Do not touch any other panel, or the top-level fields `uid`, `title`,
`schemaVersion`, `templating`, `time`, `refresh`, `__inputs`,
`__requires`. The only changes are the two added targets and their two
overrides.

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
