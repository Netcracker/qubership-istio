# Qubership Istio

A Qubership-packaged distribution of [Istio Ambient Mesh](https://istio.io/latest/docs/ambient/).

This repository provides an umbrella Helm chart that installs the full Istio Ambient Mesh stack (`base`, `cni`, `istiod`, `ztunnel`) with Qubership-specific registry override support, optional Prometheus/Grafana monitoring, and a transfer Docker image for platform delivery.

## Components

| Subchart | Purpose |
|----------|---------|
| `base` | CRDs and cluster-scoped base resources |
| `cni` | Istio CNI DaemonSet |
| `istiod` | Control plane (Pilot) |
| `ztunnel` | Ambient L4 data plane (DaemonSet) |

## Quick Start

**Prerequisites:** Kubernetes 1.31–1.35, Helm 3.6+, Gateway API CRDs pre-installed, `cluster-admin` privileges.

```bash
helm dependency build helm-templates/qubership-istio
helm upgrade --install qubership-istio helm-templates/qubership-istio \
  --namespace istio-system --create-namespace
```

Install in `istio-system` only — one instance per cluster.

**Enroll a namespace into the ambient mesh:**

```bash
kubectl label namespace <your-ns> \
  istio.io/dataplane-mode=ambient \
  istio.io/use-waypoint=waypoint
```

Restart existing workloads after labeling.

## Key Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `global.profile` | `ambient` | Mesh profile |
| `global.hub` / `tag` | — | Image registry override |
| `MONITORING_ENABLED` | `true` | Deploy ServiceMonitor, PodMonitor, GrafanaDashboards |
| `monitoring.scrapeInterval` | `15s` | Prometheus scrape interval |
| `istiod.*`, `ztunnel.*`, `cni.*` | see `values.yaml` | Pass any upstream Istio values under the subchart key |

> When this chart is used as a sub-dependency of a parent chart, prefix all values with `qubership-istio.`

## Monitoring

When `MONITORING_ENABLED=true` (default), the chart deploys:
- `ServiceMonitor` for istiod
- `PodMonitor` for ztunnel
- Two Grafana dashboards (control plane + ztunnel) via `GrafanaDashboard` CRs

## Transfer Image

A scratch Docker image (`qubership-istio-transfer`) is built and pushed to `ghcr.io` by CI. It embeds the packaged Helm chart for platform delivery and is tagged by Istio minor version + branch/tag.

## Documentation

- [Installation Notes](docs/public/installation.md) — prerequisites, HWE presets (Small/Medium/Large), full parameter reference
- [Namespace Enrollment](docs/public/namespace-enrollment.md) — how to enroll namespaces into the ambient mesh
- [Hardware sizing model](docs/internal/hardware-sizing-model.md) — capacity planning formulas for ztunnel, istiod, waypoint, and CNI
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of Conduct](CODE-OF-CONDUCT.md)

## License

See [LICENSE](LICENSE).
