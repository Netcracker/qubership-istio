---
description: Adapting an upstream Istio Grafana dashboard JSON for this distribution.
applyTo: "**/dashboards/**/*.json"
---

When editing a Grafana dashboard JSON that came from upstream Istio -
adding resource-limit overlays, adding or changing the cluster selector,
or deciding whether a panel belongs in this distribution - apply the
`istio-dashboard-adapter` skill.

It is also the record of what already diverges from upstream. Read it
before re-importing a dashboard from a newer Istio release, or the
adaptations will be silently dropped.
