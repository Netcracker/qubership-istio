<!-- TOC -->
- [Prerequisites](#prerequisites)
  - [Common](#common)
  - [Kubernetes](#kubernetes)
    - [Gateway API](#gateway-api)
    - [Pod Security Admission](#pod-security-admission)
  - [RBAC](#rbac)
  - [Monitoring](#monitoring)
- [Best practices and recommendations](#best-practices-and-recommendations)
  - [HWE](#hwe)
- [Parameters](#parameters)
  - [qubership-istio](#qubership-istio)
  - [Istio subcharts](#istio-subcharts)
    - [What the distribution presets](#what-the-distribution-presets)
- [Installation](#installation)
  - [Before you begin](#before-you-begin)
  - [On-prem](#on-prem)
  - [Post-deployment check](#post-deployment-check)
- [Upgrade](#upgrade)
- [Rollback](#rollback)
<!-- /TOC -->

# Prerequisites
## Common
This is Qubership Istio Ambient Mesh Distribution. It includes vanilla Istio Ambient Mode helm charts with minimal modifications.

This distribution Helm chart has the following structure:

- `qubership-istio` - Docker registry override; monitoring resources.
  - `base` - resources shared by all Istio revisions. This includes Istio CRDs.
  - `cni`- Istio CNI Plugin.
  - `ztunnel` - Istio ztunnel.
  - `istiod` - istiod (pilot) - Istio control plane.

Installation should be performed with Helm version 3.6+ or Helm version 4.

Qubership Istio should be installed under the service account with cluster-admin permissions in kubernetes.

## Kubernetes
Supported k8s versions: 1.31, 1.32, 1.33, 1.34, 1.35.

### Gateway API
The Kubernetes Gateway API CRDs are not part of this distribution. Install them on the cluster before the chart: without them no `Gateway` or `HTTPRoute` can exist, and a namespace labeled `istio.io/use-waypoint` gets no waypoint, because a waypoint is itself a `Gateway`.

Istio names the Gateway API version that goes with each of its releases, so take the version from [the Istio 1.30 ambient install guide](https://istio.io/v1.30/docs/ambient/install/helm/) and apply `standard-install.yaml`. The guide installs the experimental channel, a superset that this distribution does not need.

The CRDs are cluster-scoped, so check whether the cluster already has them:

```bash
kubectl get crd gateways.gateway.networking.k8s.io
```

Applying a `Gateway` without them fails with:

```text
no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"
```

### Pod Security Admission
Istio Ambient Mesh requires privileged pods: `istio-cni` and `ztunnel` need `hostNetwork` together with the `NET_ADMIN` and `SYS_ADMIN` capabilities.
If Pod Security Admission enforces `baseline` or `restricted` on `istio-system`, both DaemonSets are created but their pods are rejected at admission.
To be able to install the distro you need to provide `privileged` policy to `istio-system` namespace as prerequisite step.

It can be performed with the following command:

```bash
kubectl label --overwrite ns istio-system pod-security.kubernetes.io/enforce=privileged
```

This is what the chart does by default: `ENABLE_PRIVILEGED_PSS` is `true`, and a pre-install hook Job applies the label. Set it to `false` to opt out and label the namespace yourself.
It requires the following cluster rights for deployment user:

```yaml
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "patch"]
    resourceNames:
    - istio-system
```

The property runs a pre-install hook Job with the `kubectl` image. The node tuning init
container runs that same image, so a cluster that cannot reach `ghcr.io` redirects the
registry once; the repository and the tag stay as shipped, and a chart upgrade still moves
the version:

```yaml
global:
  kubectl:
    registry: <registry>
```


## RBAC
No cluster entity has to be created by hand. The chart creates every identity and permission it needs, which is what the cluster-admin service account in [Common](#common) is for.

The release reaches past its namespace: Istio's CRDs, the ClusterRoles and bindings for istiod and the CNI, and the validating and mutating webhook configurations are all cluster-scoped.

This distribution narrows the upstream `istiod` ClusterRole. Write verbs on webhook configurations are restricted by `resourceNames` to istiod's own webhooks, while `list` and `watch` stay cluster-wide.

## Monitoring
`MONITORING_ENABLED` defaults to `true`, and the release then carries a `ServiceMonitor`, two `PodMonitor`s, and two `GrafanaDashboard`s. Their CRDs have to be on the cluster first, otherwise `helm install` fails before a single Istio manifest is applied:

- `monitoring.coreos.com/v1`, from the Prometheus Operator
- `integreatly.org/v1alpha1`, from grafana-operator v4. Version 5 serves `grafana.integreatly.org/v1beta1` and does not satisfy this

For how to install them, see [the qubership-monitoring-operator deployment guide](https://github.com/Netcracker/qubership-monitoring-operator/blob/main/docs/installation/deploy.md).

Set `MONITORING_ENABLED=false` if you do not need monitoring.

# Best practices and recommendations
## HWE
### Small
Recommended for development purposes, PoC and demos

|Module      |CPU req|CPU lim|RAM req, Mi|RAM lim, Mi|
|------------|-------|-------|-----------|-----------|
|cni         |100m   |200m   |100        |500        |
|istiod      |500m   |1000m  |2048       |2048       |
|ztunnel     |100m   |1000m  |256        |1024       |
|**Total**   |**700m**|**2200m**|**2404** |**3572**   |

### Medium
Recommended for deployments with average load.

|Module      |CPU req|CPU lim|RAM req, Mi|RAM lim, Mi|
|------------|-------|-------|-----------|-----------|
|cni         |100m   |400m   |256        |1024       |
|istiod      |500m   |1000m  |2048       |3072       |
|ztunnel     |4000m  |8000m  |1024       |3072       |
|**Total**   |**4600m**|**9400m**|**3328**|**7168**   |

### Large
Recommended for deployments with high workload and large amount of data.

|Module      |CPU req|CPU lim|RAM req, Mi|RAM lim, Mi|
|------------|-------|-------|-----------|-----------|
|cni         |100m   |400m   |256        |1024       |
|istiod      |500m   |4000m  |2048       |5120       |
|ztunnel     |4000m  |8000m  |1024       |3072       |
|**Total**   |**4600m**|**12400m**|**3328**|**9216**  |

# Parameters
## qubership-istio
|Parameter          |Type   |Mandatory|Default value|Description                                                                                 |
|-------------------|-------|---------|-------------|--------------------------------------------------------------------------------------------|
|MONITORING_ENABLED |boolean|no       |true         |Flag to install custom resources (PodMonitor and grafana dashboard) for prometheus monitoring|
|ENABLE_PRIVILEGED_PSS|boolean|no     |true         |Label the release namespace `pod-security.kubernetes.io/enforce=privileged` from a pre-install/pre-upgrade hook Job, for clusters where Pod Security Admission would otherwise reject the Ambient Mesh pods. Needs `get` and `patch` on the namespace|
|global.kubectl.registry|string|no|`ghcr.io`|Registry the kubectl image is pulled from, shared by the PSS patch Job and the node tuning init container. Redirect this alone for a private registry: the repository and the tag stay as shipped|
|global.kubectl.repository|string|no|`netcracker/qubership-docker-kubectl`|Repository of the kubectl image. Not an Istio image, so it is not derived from `global.hub`|
|global.kubectl.tag|string|no|`0.0.9`|Tag of that image. Used only when `global.kubectl.digest` is unset|
|global.kubectl.digest|string|no|unset|Digest of that image (`sha256:...`). When set, the image is pinned by digest and the tag is ignored|
|global.kubectl.image|string|no|unset|Whole reference, replacing registry, repository, tag and digest at once. For an image that does not follow the shipped naming|
|patchPss.resources |object |no       |75m/75Mi requests, 150m/150Mi limits|Resources for the PSS patch Job container                                          |
|patchPss.podSecurityContext|object|no|`runAsNonRoot: true`, `runAsUser: 1001`, `seccompProfile.type: RuntimeDefault`|Pod security context of the PSS patch Job. Must stay compliant with the policy currently enforced on the namespace, otherwise the Job cannot be admitted in order to relax it|
|patchPss.containerSecurityContext|object|no|no privilege escalation, drop `ALL`, read-only root filesystem|Container security context of the PSS patch Job|
|global.nodeTuning.enabled|boolean|no|`true`|Run an init container in the `cni` and `ztunnel` DaemonSets that raises the node inotify limits before the agent starts. Set it to `false` where the platform already tunes these limits, through `/etc/sysctl.d` or a `Tuned` profile|
|global.nodeTuning.inotify.maxUserInstances|integer|no|`8192`|Target value for `fs.inotify.max_user_instances`. The kernel default of 128 is a per-UID budget shared with kubelet and containerd, and the agents fail to start with `Too many open files` once it runs out|
|global.nodeTuning.inotify.maxUserWatches|integer|no|`65536`|Target value for `fs.inotify.max_user_watches`|

The init container writes to `/proc/sys/fs/inotify` through a `hostPath` mount, so it runs as root
on the node. The `privileged` policy this distribution already requires on `istio-system` covers that.

A limit is raised only when the node sits below the target, so a node tuned higher keeps its own
value. The container never fails the pod. Neither DaemonSet sets `updateStrategy`, so both roll at
the Kubernetes default of `maxSurge: 0`: a pod that cannot start leaves the node without its agent.

## Istio subcharts
Every value of the vanilla `base`, `cni`, `istiod`, and `ztunnel` charts can be set here, under the subchart key. Read the full list from the pinned subchart itself, so the version always matches the one this distribution ships:

```bash
helm dependency build helm-templates/qubership-istio
helm show values helm-templates/qubership-istio/charts/istiod-*.tgz
```

Values are nested one level under the subchart name, for example to set `connectTimeout` for `istiod`:

```yaml
istiod:
  meshConfig:
    defaultConfig:
      connectTimeout: 5s
```

Prefix the whole block with `qubership-istio:` when this chart is installed as a dependency of a parent chart.

### What the distribution presets
The values below are set by this chart; everything else keeps the vanilla default. Each can be overridden.

| Value                                                                                             |Set to| Effect of changing it                                                                                                                                                                            |
|---------------------------------------------------------------------------------------------------|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `global.profile`                                                                                  |`ambient`| Ambient mode is the only mode this distribution ships and tests                                                                                                                                  |
| `global.proxy.privileged`                                                                         |`false`| Proxies run unprivileged. `istio-cni-node` and `ztunnel` are privileged regardless, see [Pod Security Admission](#pod-security-admission)                                                        |
| `base.base.validationFailurePolicy`, `istiod.base.validationFailurePolicy`                        |`Fail`| The validating webhook rejects invalid Istio config from the start. The vanilla `Ignore` lets istiod flip the policy once it is ready, which server-side apply tools see as a change on every run |
| `istiod.meshConfig.accessLogFile`                                                                 |`/dev/stdout`| Proxy access logs go to the pod log. Empty turns them off                                                                                                                                        |
| `istiod.meshConfig.defaultConfig.gatewayTopology.numTrustedProxies`                               |`1`| How many proxies sit in front of a gateway, which decides the client address a gateway reads from `X-Forwarded-For`. Set it to the real number of hops, otherwise the address is wrong           |
| `istiod.gatewayClasses.istio.service.spec.type`                                                   |`ClusterIP`| Gateways created from the `istio` class get no cloud load balancer. Set `LoadBalancer` where one is wanted                                                                                       |
| `istiod.env.ISTIO_DUAL_STACK` and `istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK` |`"false"`| Dual-stack support. Both have to be changed together: the mesh config carries the flag into gateway pods, and only a restarted istiod reconciles existing gateways with it                       |
| `ztunnel.meshConfig.defaultConfig.proxyMetadata`                                                  |`ISTIO_META_DNS_CAPTURE: "true"`, `ISTIO_META_ROUTER_MODE: "sni-dnat"`| Proxy metadata the chart sets for ztunnel                                                                                                                                                        |
| `seccompProfile.type` on `global.proxy`, `cni`, `istiod`, and `istiod.gateways`                   |`RuntimeDefault`| Keeps the istiod and gateway pods admissible under `restricted`. No effect on the admission of `istio-cni-node` or `ztunnel`, which need `privileged` regardless |
| `resources` on `cni`, `istiod`, `ztunnel`                                                         |see [HWE](#hwe)| Requests and limits for the three components                                                                                                                                                     |

# Installation
## Before you begin
Qubership Istio distro should always be installed into `istio-system` namespace. No other applications should be installed in this namespace. Only single instance of Qubership Istio must be installed on kubernetes cluster.

### Helm
Install via Helm into `istio-system` namespace.

## On-prem
### HA scheme
Not applicable
### DR scheme
Not applicable
### Non-HA scheme
Not applicable

## Post-deployment check
The release brings up three workloads, and all three have to report a completed rollout:

```bash
kubectl rollout status deployment/istiod -n istio-system
kubectl rollout status daemonset/istio-cni-node -n istio-system
kubectl rollout status daemonset/ztunnel -n istio-system
```

`istio-cni-node` and `ztunnel` are DaemonSets, so each command returns only once the pod is ready on every node the DaemonSet targets. Workloads on a node that carries neither pod stay outside the mesh.

A DaemonSet that stays at 0 ready pods is usually Pod Security Admission rejecting them. The DaemonSet status does not say so; the rejection is in the events:

```bash
kubectl get events -n istio-system --field-selector reason=FailedCreate
```

See [Pod Security Admission](#pod-security-admission) for the fix.

With `MONITORING_ENABLED` left at `true`, the release also creates the monitoring resources:

```bash
kubectl get servicemonitor istiod-monitor -n istio-system
kubectl get podmonitor ztunnel-monitor istio-cni-node-monitor -n istio-system
kubectl get grafanadashboard istio-control-plane-dashboard istio-ztunnel-dashboard -n istio-system
```

A healthy release carries no traffic on its own. Workloads reach the mesh only after their namespace is enrolled, see [Namespace Enrollment into Istio Ambient Mesh](namespace-enrollment.md).

# Upgrade
Install and upgrade procedures are identical.

# Rollback
Install via Helm with the previous version.

# See also

* [Namespace Enrollment into Istio Ambient Mesh](namespace-enrollment.md)
