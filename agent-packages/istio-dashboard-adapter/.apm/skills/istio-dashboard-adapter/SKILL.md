---
name: istio-dashboard-adapter
description: Adapt an upstream Istio Grafana dashboard for this distribution. Use when importing or updating istio-control-plane / ztunnel dashboards, adding resource-limit overlays, adding a cluster selector, or deciding whether an empty panel belongs here. Also the record of what already diverges from upstream.
---

# Istio Dashboard Adapter

The dashboards in `helm-templates/qubership-istio/dashboards` start life
as the upstream Istio ones - `pilot-dashboard.gen.json` and
`ztunnel-dashboard.gen.json` from `manifests/addons/dashboards`. Three
things are done to them here and nothing else: the resource-limit
overlays of steps 3 and 4, the cluster selector of steps 5 and 6, and the
one panel removed in step 7.

**Read this before re-importing a dashboard from a newer Istio release.**
An import overwrites all three, and step 6 touches every query in the
file.

## Process

### 1. Obtain the source dashboard

- A URL - fetch it.
- Pasted JSON - use it directly.
- A repo file - read it (here they live under
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

### 5. Add the cluster variable

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

### 6. Put the cluster selector on every query

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

### 7. Decide which panels belong

Three panels on the control-plane dashboard usually show nothing. Only
one of them is deleted, and the difference is worth understanding before
touching any of them.

#### Injection is removed - ambient never injects a sidecar

`sidecar_injection_success_total` and `sidecar_injection_failure_total`
are current metric names and they work - but only the sidecar injection
webhook ever records them. This distribution runs **ambient** mesh only,
so no sidecar is ever injected and the counters can never be created.

It is deleted rather than left empty: an empty graph reads as "nothing is
wrong", which is the opposite of what a metric that can never exist
means.

Restore this panel if a distribution ever ships sidecar mode.

#### Push Errors and Validation are kept - empty means healthy

Both look broken and are not. Istio registers a counter **lazily**: it
does not appear on the metrics endpoint until something increments it for
the first time. A counter for an event that has not happened is absent,
not zero.

| Panel | Metrics | Absent because |
|---|---|---|
| Push Errors | `pilot_total_xds_rejects`, `pilot_total_xds_internal_errors` | no proxy has rejected a push, and istiod has hit no internal error |
| Validation | `galley_validation_passed`, `galley_validation_failed` | nobody has applied an Istio custom resource since istiod started |

Do not conclude from an empty metrics endpoint that a metric was removed.
The two Push Errors metrics are defined in `pkg/xds/monitoring.go` of
Istio 1.30 - note the path, there is a second `monitoring.go` under
`pilot/pkg/xds/` that does not define them, and looking only there is how
this panel gets mistaken for dead. `istio/istio#56105` reports exactly
that mistake from the outside.

So both panels stay. Deleting a panel because the cluster is healthy
would remove the one thing that shows the cluster stopping being healthy.

#### Closing the layout after a removal

Removing a panel leaves a hole; the row does not reflow by itself.
Injection shared a row with Validation at `w: 12`, so Validation becomes
`w: 24`.

### 8. Preserve everything else

Steps 3 to 7 are the whole diff. Nothing else in the file changes: not
the remaining panels, not their queries beyond the cluster matcher, and
not the top-level fields `uid`, `title`, `schemaVersion`, `time`,
`refresh`, `__inputs`, `__requires`.

Diff the result against the source before committing it. An adaptation
that touched a panel it had no business touching is the kind of thing
that survives review and surfaces months later, when somebody wonders
why this dashboard drifted from upstream in a place nobody decided on.

## Filling an empty panel on demand

For a demo or a screenshot, both can be filled without leaving anything
behind in the cluster.

**Validation.** The webhook server records a pass on a dry run but
returns early on a failed dry run, so the two lines need different
commands:

- **Success** - `kubectl apply --dry-run=server` any valid Istio resource.
  The request goes through admission and is then discarded, so nothing is
  created and the counter still moves.
- **Failure** - a real `kubectl apply` of a resource that passes CRD
  schema validation but fails Istio's own, for instance a `Sidecar` whose
  `egress.hosts` entry is not in `namespace/host` form. The webhook
  rejects it, so nothing is created either.

A schema-invalid resource does not reach the webhook at all and moves
neither counter.

**Push Errors** cannot be triggered as safely: it needs a proxy to reject
a real config push. Leave it alone and read it for what it is - the panel
that stays flat until something goes wrong.

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
- **Reading an absent metric as a removed one.** Istio registers counters
  lazily, so a counter for an event that never happened is missing from
  the metrics endpoint entirely. Check the source before concluding a
  panel is dead - and check every `monitoring.go`, not the first one found.
