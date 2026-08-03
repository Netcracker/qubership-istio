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

A scratch Docker image (`qubership-istio-transfer`) is built and pushed to `ghcr.io` by CI. It embeds the packaged Helm chart for platform delivery.

| Build | Image tags | Chart `version` | Chart `appVersion` |
|-------|-----------|-----------------|--------------------|
| Release | `1.0.2`, `1.0`, `latest`, `1.0.2-istio1.30.2` | `1.0.2` | `1.30.2` |
| Branch push | `<branch-slug>` | `0.0.0-<branch-slug>` | `1.30.2` |
| Pull request from a fork, or a renovate branch | none (dry run) | — | — |

Branch tags expire after 8 days; [the weekly cleanup job](.github/workflows/cleanup-old-docker-container.yml) keeps `latest` and every version-shaped tag.

## Versioning and Releases

qubership-istio carries its own SemVer, independent of the Istio version it bundles. The Istio version stays visible through the chart's `appVersion` and the `-istio<version>` image alias.

An Istio bump moves the matching part of the qubership-istio version:

| Change | Version bump |
|--------|-------------|
| Istio major (`1.x` → `2.x`) | major |
| Istio minor (`1.30` → `1.31`) | minor |
| Istio patch (`1.30.1` → `1.30.2`) | patch |
| qubership-only change | patch, or minor for a new capability |

To cut a release, run the [Release workflow](.github/workflows/release.yml) from the Actions tab. The default `auto` version type reads the rule above off the Istio chart dependency in `Chart.yaml`, comparing the dispatched commit against the previous release tag; pick `patch`, `minor`, `major`, or `explicit` to override it. The workflow tags the commit `<version>`, runs the full build and integration matrix, publishes the image, and creates the GitHub release page with notes drafted from the merged pull requests. A failed build removes the tag it was cut for.

Use `dry-run` to resolve the version and run the build without touching tags, the registry, or the release page.

Release notes are grouped by pull request label — `breaking-change`, `feature`, `enhancement`, `bug`, `fix`, `bugfix`, `refactor`, `documentation`, `dependencies`. Renovate labels its Istio pull requests with `dependencies` plus `major`, `minor`, or `patch`, so the required bump is visible before the merge.

## Documentation

- [Installation Notes](docs/public/installation.md) — prerequisites, HWE presets (Small/Medium/Large), full parameter reference
- [Namespace Enrollment](docs/public/namespace-enrollment.md) — how to enroll namespaces into the ambient mesh
- [Hardware sizing model](docs/internal/hardware-sizing-model.md) — capacity planning formulas for ztunnel, istiod, waypoint, and CNI
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of Conduct](CODE-OF-CONDUCT.md)

## License

See [LICENSE](LICENSE).
