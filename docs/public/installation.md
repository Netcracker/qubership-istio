<!-- TOC -->
- [Prerequisites](#prerequisites)
  - [Common](#common)
  - [Kubernetes](#kubernetes)
    - [Gateway API](#gateway-api)
    - [Pod Security Admission](#pod-security-admission)
  - [OpenShift](#openshift)
    - [Gateway API](#gateway-api-1)
    - [Pod Security Admission](#pod-security-admission-1)
    - [Network](#network)
  - [GKE](#gke)
  - [RBAC](#rbac)
  - [Monitoring](#monitoring)
- [Best practices and recommendations](#best-practices-and-recommendations)
  - [HWE](#hwe)
- [Parameters](#parameters)
  - [General parameters](#general-parameters)
  - [Istio parameters](#istio-parameters)
    - [What the distribution presets](#what-the-distribution-presets)
- [Installation](#installation)
  - [Before you begin](#before-you-begin)
  - [On-prem](#on-prem)
  - [Post-deployment check](#post-deployment-check)
- [Upgrade](#upgrade)
- [Rollback](#rollback)
- [Uninstall](#uninstall)
<!-- /TOC -->

# Prerequisites
## Common
This is Qubership Istio Ambient Mesh Distribution. It includes vanilla Istio Ambient Mode helm charts with minimal modifications.

This distribution Helm chart has the following structure:

- `qubership-istio` - the chart you install. On top of the Istio charts below it adds monitoring resources, the Pod Security Admission hook, the node inotify tuning, the platform defaults for GKE and OpenShift, a narrower `istiod` ClusterRole, and the values listed in [What the distribution presets](#what-the-distribution-presets).
  - `base` - resources shared by all Istio revisions. This includes Istio CRDs.
  - `cni` - Istio CNI Plugin.
  - `ztunnel` - Istio ztunnel.
  - `istiod` - istiod (pilot) - Istio control plane.

Install and upgrade the distribution with Argo CD only. The published chart carries the Istio subcharts with this distribution's changes built in: the image registry, the narrower `istiod` ClusterRole, and the node tuning. Argo CD renders the chart as published. A deployment tool that runs `helm dependency update` or `helm dependency build` before it installs downloads the vanilla Istio subcharts again, and these changes are lost.

Qubership Istio should be installed under the service account with cluster-admin permissions in kubernetes.

## Kubernetes
Supported k8s versions: 1.32, 1.33, 1.34, 1.35, 1.36, the versions [Istio 1.30 supports](https://istio.io/latest/docs/releases/supported-releases/).

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

## OpenShift
Supported versions: 4.19 to 4.22, the OpenShift releases built on the [supported Kubernetes versions](#kubernetes), from 1.32 in 4.19 to 1.35 in 4.22.

Set this value:

```yaml
global:
  platform: openshift
```

This value does three things:

- The Istio [OpenShift profile](https://github.com/istio/istio/blob/1.30.4/manifests/helm-profiles/platform-openshift.yaml) puts the CNI plugin on the Multus paths, gives the agents the `spc_t` SELinux type, and makes the `cni` and `ztunnel` charts grant their service accounts the `privileged` SecurityContextConstraints.
- istiod trusts ztunnel in `istio-system`. The profile points it at `kube-system`, where Istio installs ztunnel on OpenShift, and istiod issues no certificates to a ztunnel outside the trusted namespace. This distribution installs ztunnel in `istio-system`, so it sets `istiod.trustedZtunnelNamespace` to the release namespace itself. A value you set explicitly still takes precedence.
- The Pod Security Admission hook is skipped, see [Pod Security Admission](#pod-security-admission-1).

### Gateway API
OpenShift installs and manages the Gateway API CRDs itself, from the `standard` channel, and rejects changes to them. Do not install them as described in [Gateway API](#gateway-api).

Do not create the `openshift-default` GatewayClass on a cluster with this distribution: OpenShift then brings its own Istio CRDs, and two Istio installations share them.

### Pod Security Admission
OpenShift admits the agents by SecurityContextConstraints, not by the namespace label, and the `cni` and `ztunnel` charts already grant them `privileged`. The hook Job that `ENABLE_PRIVILEGED_PSS` adds runs as UID `1001`, which is outside the UID range OpenShift assigns to the namespace, so it would never be admitted. That is why the chart skips the hook on `openshift`, whatever `ENABLE_PRIVILEGED_PSS` says.

### Network
This step applies only when the cluster network is OVN-Kubernetes, the OpenShift default. Check the network type:

```bash
oc get network.config cluster -o jsonpath='{.status.networkType}'
```

With another network type, such as `Calico`, the setting below does not exist: skip this step.

With `OVNKubernetes`, the network has to route egress through the host. With the default `routingViaHost: false`, the reply to a kubelet probe leaves the node without reaching kubelet, and every pod in ambient stays not ready. Check the value:

```bash
oc get networks.operator.openshift.io cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'
```

If it is not `true`, the cluster administrator switches it. The change applies to the egress of every pod in the cluster:

```bash
oc patch networks.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

## GKE
Supported versions: GKE clusters on the [supported Kubernetes versions](#kubernetes). A GKE version is the Kubernetes version with a `-gke` suffix, for example `1.35.6-gke.1250000`.

Set this value:

```yaml
global:
  platform: gke
```

This value does two things:

- The Istio [GKE profile](https://github.com/istio/istio/blob/1.30.4/manifests/helm-profiles/platform-gke.yaml) makes the `cni` and `ztunnel` charts render ResourceQuotas for the `system-node-critical` priority class, which both agents run with. GKE admits such pods only into a namespace with that quota. Without it the DaemonSets create no pods: `insufficient quota to match these scopes`.
- The CNI plugin goes to `/home/kubernetes/bin`, where GKE looks for it. The upstream chart picks that directory only when the Kubernetes version it renders for contains `-gke`, and Argo CD passes the version without vendor suffixes, so this distribution sets it for `gke` itself. A `cni.cniBinDir` you set explicitly still takes precedence.

Gateway API and Pod Security Admission need nothing beyond [Kubernetes](#kubernetes).

## RBAC
No cluster entity has to be created by hand. The chart creates every identity and permission it needs, which is what the cluster-admin service account in [Common](#common) is for.

The release reaches past its namespace: Istio's CRDs, the ClusterRoles and bindings for istiod and the CNI, and the validating and mutating webhook configurations are all cluster-scoped.

This distribution narrows the upstream `istiod` ClusterRole. Write verbs on webhook configurations are restricted by `resourceNames` to istiod's own webhooks, while `list` and `watch` stay cluster-wide.

## Monitoring
`MONITORING_ENABLED` defaults to `true`, and the release then carries a `ServiceMonitor`, two `PodMonitor`s, and two `GrafanaDashboard`s. Their CRDs have to be on the cluster first, otherwise the sync fails:

- `monitoring.coreos.com/v1`, from the Prometheus Operator
- `integreatly.org/v1alpha1`, from grafana-operator v4. Version 5 serves `grafana.integreatly.org/v1beta1` and does not satisfy this

For how to install them, see [the qubership-monitoring-operator deployment guide](https://github.com/Netcracker/qubership-monitoring-operator/blob/main/docs/installation/deploy.md).

Set `MONITORING_ENABLED=false` if you do not need monitoring.

# Best practices and recommendations
## HWE
### Small
Recommended for development purposes, PoC and demos

| Module    | CPU req  | CPU lim   | RAM req, Mi | RAM lim, Mi |
|-----------|----------|-----------|-------------|-------------|
| cni       | 100m     | 200m      | 100         | 500         |
| istiod    | 500m     | 1000m     | 2048        | 2048        |
| ztunnel   | 100m     | 1000m     | 256         | 1024        |
| **Total** | **700m** | **2200m** | **2404**    | **3572**    |

### Medium
Recommended for deployments with average load.

| Module    | CPU req   | CPU lim   | RAM req, Mi | RAM lim, Mi |
|-----------|-----------|-----------|-------------|-------------|
| cni       | 100m      | 400m      | 256         | 1024        |
| istiod    | 500m      | 1000m     | 2048        | 3072        |
| ztunnel   | 4000m     | 8000m     | 1024        | 3072        |
| **Total** | **4600m** | **9400m** | **3328**    | **7168**    |

### Large
Recommended for deployments with high workload and large amount of data.

| Module    | CPU req   | CPU lim    | RAM req, Mi | RAM lim, Mi |
|-----------|-----------|------------|-------------|-------------|
| cni       | 100m      | 400m       | 256         | 1024        |
| istiod    | 500m      | 4000m      | 2048        | 5120        |
| ztunnel   | 4000m     | 8000m      | 1024        | 3072        |
| **Total** | **4600m** | **12400m** | **3328**    | **9216**    |

# Parameters
Every parameter on this page, the Istio ones included, is a top-level key of the values passed to this chart.

## General parameters
| Parameter                                  | Type    | Mandatory | Default value                                                                  | Description                                                                                                                                                                                                                                                                                                                                         |
|--------------------------------------------|---------|-----------|--------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| MONITORING_ENABLED                         | boolean | no        | true                                                                           | Flag to install custom resources (PodMonitor and grafana dashboard) for prometheus monitoring                                                                                                                                                                                                                                                       |
| ENABLE_PRIVILEGED_PSS                      | boolean | no        | true                                                                           | Label the release namespace `pod-security.kubernetes.io/enforce=privileged` from a pre-install/pre-upgrade hook Job, for clusters where Pod Security Admission would otherwise reject the Ambient Mesh pods. Needs `get` and `patch` on the namespace. Ignored with `global.platform: openshift`, where SecurityContextConstraints admit the agents |
| global.kubectl.registry                    | string  | no        | `ghcr.io`                                                                      | Registry the kubectl image is pulled from, shared by the PSS patch Job and the node tuning init container. Redirect this alone for a private registry: the repository and the tag stay as shipped                                                                                                                                                   |
| global.kubectl.repository                  | string  | no        | `netcracker/qubership-docker-kubectl`                                          | Repository of the kubectl image. Not an Istio image, so it is not derived from `global.hub`                                                                                                                                                                                                                                                         |
| global.kubectl.tag                         | string  | no        | `0.0.9`                                                                        | Tag of that image. Used only when `global.kubectl.digest` is unset                                                                                                                                                                                                                                                                                  |
| global.kubectl.digest                      | string  | no        | unset                                                                          | Digest of that image (`sha256:...`). When set, the image is pinned by digest and the tag is ignored                                                                                                                                                                                                                                                 |
| global.kubectl.image                       | string  | no        | unset                                                                          | Whole reference, replacing registry, repository, tag and digest at once. For an image that does not follow the shipped naming                                                                                                                                                                                                                       |
| patchPss.resources                         | object  | no        | 75m/75Mi requests, 150m/150Mi limits                                           | Resources for the PSS patch Job container                                                                                                                                                                                                                                                                                                           |
| patchPss.podSecurityContext                | object  | no        | `runAsNonRoot: true`, `runAsUser: 1001`, `seccompProfile.type: RuntimeDefault` | Pod security context of the PSS patch Job. Must stay compliant with the policy currently enforced on the namespace, otherwise the Job cannot be admitted in order to relax it                                                                                                                                                                       |
| patchPss.containerSecurityContext          | object  | no        | no privilege escalation, drop `ALL`, read-only root filesystem                 | Container security context of the PSS patch Job                                                                                                                                                                                                                                                                                                     |
| global.nodeTuning.enabled                  | boolean | no        | `true`                                                                         | Run an init container in the `cni` and `ztunnel` DaemonSets that raises the node inotify limits before the agent starts. Set it to `false` where the platform already tunes these limits, through `/etc/sysctl.d` or a `Tuned` profile                                                                                                              |
| global.nodeTuning.inotify.maxUserInstances | integer | no        | `8192`                                                                         | Target value for `fs.inotify.max_user_instances`. The kernel default of 128 is a per-UID budget shared with kubelet and containerd, and the agents fail to start with `Too many open files` once it runs out                                                                                                                                        |
| global.nodeTuning.inotify.maxUserWatches   | integer | no        | `65536`                                                                        | Target value for `fs.inotify.max_user_watches`                                                                                                                                                                                                                                                                                                      |

The init container writes to `/proc/sys/fs/inotify` through a `hostPath` mount, so it runs as root
on the node. The `privileged` policy this distribution already requires on `istio-system` covers that.

A limit is raised only when the node sits below the target, so a node tuned higher keeps its own
value. The container never fails the pod. Neither DaemonSet sets `updateStrategy`, so both roll at
the Kubernetes default of `maxSurge: 0`: a pod that cannot start leaves the node without its agent.

## Istio parameters
Every value of the vanilla Istio charts `base`, `cni`, `istiod`, and `ztunnel` can be set under the top-level key of the same name. Read the full list from the pinned chart itself, so the version always matches the one this distribution ships:

```bash
helm dependency build helm-templates/qubership-istio
helm show values helm-templates/qubership-istio/charts/istiod-*.tgz
```

For example, to set `connectTimeout` for `istiod`:

```yaml
istiod:
  meshConfig:
    defaultConfig:
      connectTimeout: 5s
```

### What the distribution presets
The values below are set by this chart; everything else keeps the vanilla default. Each can be overridden.

| Value                                                                                              | Set to                                                                 | Effect of changing it                                                                                                                                                                                                                                                                                                                                    |
|----------------------------------------------------------------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `global.profile`                                                                                   | `ambient`                                                              | Ambient mode is the only mode this distribution ships and tests                                                                                                                                                                                                                                                                                          |
| `global.proxy.privileged`                                                                          | `false`                                                                | Proxies run unprivileged. `istio-cni-node` and `ztunnel` are privileged regardless, see [Pod Security Admission](#pod-security-admission)                                                                                                                                                                                                                |
| `base.base.validationFailurePolicy`, `istiod.base.validationFailurePolicy`                         | `Fail`                                                                 | The validating webhook rejects invalid Istio config from the start. The vanilla `Ignore` lets istiod flip the policy once it is ready, which server-side apply tools see as a change on every run                                                                                                                                                        |
| `istiod.meshConfig.accessLogFile`                                                                  | `/dev/stdout`                                                          | Proxy access logs go to the pod log. Empty turns them off                                                                                                                                                                                                                                                                                                |
| `istiod.meshConfig.defaultConfig.gatewayTopology.numTrustedProxies`                                | `1`                                                                    | How many proxies sit in front of a gateway, which decides the client address a gateway reads from `X-Forwarded-For`. Set it to the real number of hops, otherwise the address is wrong                                                                                                                                                                   |
| `istiod.gatewayClasses.istio.service.spec.type`                                                    | `ClusterIP`                                                            | Gateways created from the `istio` class get no cloud load balancer. Set `LoadBalancer` where one is wanted                                                                                                                                                                                                                                               |
| `istiod.env.ISTIO_DUAL_STACK` and `istiod.meshConfig.defaultConfig.proxyMetadata.ISTIO_DUAL_STACK` | `"false"`                                                              | Dual-stack support. Both have to be changed together: the mesh config carries the flag into gateway pods, and only a restarted istiod reconciles existing gateways with it                                                                                                                                                                               |
| `ztunnel.meshConfig.defaultConfig.proxyMetadata`                                                   | `ISTIO_META_DNS_CAPTURE: "true"`, `ISTIO_META_ROUTER_MODE: "sni-dnat"` | Proxy metadata the chart sets for ztunnel                                                                                                                                                                                                                                                                                                                |
| `cni.excludeNamespaces`                                                                            | `kube-system`, `istio-system`                                          | The CNI plugin lets pods of these namespaces through without asking the Kubernetes API, so the pre-install hook starts even on a node where a stopped agent left the plugin behind, see [Troubleshooting](troubleshooting.md#installation-hangs-on-the-istio-patch-pss-hook). A list replaces the default instead of extending it, so keep `kube-system` |
| `seccompProfile.type` on `global.proxy`, `cni`, `istiod`, and `istiod.gateways`                    | `RuntimeDefault`                                                       | Keeps the istiod and gateway pods admissible under `restricted`. No effect on the admission of `istio-cni-node` or `ztunnel`, which need `privileged` regardless                                                                                                                                                                                         |
| `resources` on `cni`, `istiod`, `ztunnel`                                                          | see [HWE](#hwe)                                                        | Requests and limits for the three components                                                                                                                                                                                                                                                                                                             |

# Installation
## Before you begin
Qubership Istio distro should always be installed into `istio-system` namespace. No other applications should be installed in this namespace. Only single instance of Qubership Istio must be installed on kubernetes cluster.

### Argo CD
Install with an Argo CD Application into the `istio-system` namespace. See [OpenShift](#openshift) or [GKE](#gke) for the values those platforms need.

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
Sync the Argo CD Application to the previous chart version.

# Uninstall
Istio reaches every pod in the cluster: the CNI plugin takes part in creating each pod on every node, and every pod in the mesh sends its traffic and DNS queries through ztunnel. Remove it in the order below. Deleting the `istio-system` namespace instead leaves the nodes and the pods of the mesh broken, see [`istio-system` was deleted](troubleshooting.md#istio-system-was-deleted).

1. Take the workloads out of the mesh. Find the enrolled namespaces and remove both labels from each:

   ```bash
   kubectl get namespaces -l istio.io/dataplane-mode=ambient
   kubectl label namespace <namespace> istio.io/dataplane-mode- istio.io/use-waypoint-
   ```

   The CNI agent takes the running pods out of the mesh within seconds, without restarting them. Wait until this command prints nothing:

   ```bash
   kubectl get pods -A -o jsonpath='{range .items[?(@.metadata.annotations.ambient\.istio\.io/redirection=="enabled")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
   ```

   A pod that is still in the mesh when ztunnel goes away keeps redirecting its outbound traffic and DNS queries to it, and loses both until it is recreated.

   Applications deployed in Istio mode, for example those that create `Gateway` resources of the `istio` or `istio-waypoint` class, stop working without Istio. Redeploy them without Istio before this step.

2. Delete the Argo CD Application with cascade, the default, so that Argo CD deletes the resources it created. Let the pods stop on their own: do not delete the `istio-system` namespace and do not force-delete pods.

   The CNI agent removes its plugin from the node only if its DaemonSet is already deleted when the agent stops. If the agent pods stop first, as they do when the namespace is deleted, each agent takes it for an upgrade and leaves the plugin on its node, and every new pod on that node fails, see [New pods fail with `istio-cni` `Unauthorized`](troubleshooting.md#new-pods-fail-with-istio-cni-unauthorized).

3. Wait until no pod is left in `istio-system`, then check that new pods start on every node:

   ```bash
   kubectl get pods -n istio-system
   kubectl get events -A --field-selector reason=FailedCreatePodSandBox
   ```

   With access to the nodes, check each one directly: `grep istio-cni /etc/cni/net.d/*` prints nothing, and `/var/run/istio-cni/istio-cni-kubeconfig` does not exist.

4. Remove what stays on the cluster. The Istio CRDs carry `helm.sh/resource-policy: keep`, so that a reinstall finds the Istio resources in place. If Istio is not coming back, delete them. This deletes every Istio resource in the cluster:

   ```bash
   kubectl get crd -o name | grep '\.istio\.io$' | xargs kubectl delete
   ```

   Then delete the `istio-system` namespace, or remove its `pod-security.kubernetes.io/enforce` label if the namespace stays. The Gateway API CRDs are not part of this distribution and stay in place.

# See also

* [Namespace Enrollment into Istio Ambient Mesh](namespace-enrollment.md)
* [Troubleshooting](troubleshooting.md)
