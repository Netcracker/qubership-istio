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

**Prerequisites:** a [supported Kubernetes version](docs/public/installation.md#kubernetes), Helm 3.6+, Gateway API CRDs pre-installed, `cluster-admin` privileges.

Build the chart from the repository the way CI does, then install it:

```bash
helm dependency build helm-templates/qubership-istio
bash tweak/tweak.sh
helm upgrade --install qubership-istio helm-templates/qubership-istio \
  --namespace istio-system --create-namespace
```

`tweak/tweak.sh` builds this distribution's changes into the Istio subcharts that `helm dependency build` downloads. Without it the chart installs vanilla Istio. Do not run `helm dependency build` or `helm dependency update` again after it, see [Installation Notes](docs/public/installation.md).

Install in `istio-system` only — one instance per cluster.

A pre-install hook labels `istio-system` `pod-security.kubernetes.io/enforce=privileged` by default, for clusters that enforce Pod Security Admission — ambient mode's `istio-cni` and `ztunnel` DaemonSets need privileged pods. See [Pod Security Admission](docs/public/installation.md#pod-security-admission).

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
| `ENABLE_PRIVILEGED_PSS` | `true` | Pre-install hook Job labels the release namespace `pod-security.kubernetes.io/enforce=privileged` (needed on Pod-Security-Admission clusters) |
| `monitoring.scrapeInterval` | `15s` | Prometheus scrape interval |
| `istiod.env.PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` | `"false"` | `"true"` sends each gateway only the Envoy clusters of the Services it references, instead of every Service in the cluster, so gateway memory stops growing with the cluster. Keep it off while an EnvoyFilter on a gateway calls a Service by cluster name and no route of that gateway points at the Service, see [Gateway cluster filtering](docs/public/installation.md#gateway-cluster-filtering) |
| `istiod.*`, `ztunnel.*`, `cni.*` | see `values.yaml` | Pass any upstream Istio values under the subchart key |

> When this chart is used as a sub-dependency of a parent chart, prefix all values with `qubership-istio.`

## Monitoring

When `MONITORING_ENABLED=true` (default), the chart deploys:
- `ServiceMonitor` for istiod
- `PodMonitor` for ztunnel
- `PodMonitor` for istio-cni-node, which has no Service of its own to scrape through
- Two Grafana dashboards (control plane + ztunnel) via `GrafanaDashboard` CRs

## Transfer Image

A scratch Docker image (`qubership-istio-transfer`) is built and pushed to `ghcr.io` by CI. It embeds the packaged Helm chart for platform delivery and is tagged by Istio minor version + branch/tag.

## Documentation

- [Installation Notes](docs/public/installation.md) — prerequisites, HWE presets (Small/Medium/Large), full parameter reference
- [Namespace Enrollment](docs/public/namespace-enrollment.md) — how to enroll namespaces into the ambient mesh
- [Red Hat OpenShift Service Mesh 3 in ambient mode](docs/public/openshift-istio.md) — install the mesh from the Red Hat operator instead of this distribution
- [Troubleshooting](docs/public/troubleshooting.md) — pods that do not start with `istio-cni` `Unauthorized`, a hanging pre-install hook, and other problems after Istio is removed the wrong way
- [Hardware sizing model](docs/internal/hardware-sizing-model.md) — capacity planning formulas for ztunnel, istiod, gateways, waypoints, and CNI
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of Conduct](CODE-OF-CONDUCT.md)

## License

See [LICENSE](LICENSE).
