---
description: Adapting Grafana dashboard JSON to overlay CPU/memory resource limits.
applyTo: "**/dashboards/**/*.json"
---

When editing a Grafana dashboard JSON to add resource-limit overlays —
adding limit lines to CPU or memory usage panels, or working with
`kube_pod_container_resource_limits` targets — apply the
`grafana-dashboard-limits` skill.
