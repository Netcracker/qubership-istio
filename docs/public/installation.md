<!-- TOC -->
- [Prerequisites](#prerequisites)
  - [Common](#common)
  - [Kubernetes](#kubernetes)
    - [Pod Security Admission](#pod-security-admission)
- [Best practices and recommendations](#best-practices-and-recommendations)
  - [HWE](#hwe)
- [Parameters](#parameters)
  - [qubership-istio](#qubership-istio)
- [Installation](#installation)
  - [Before you begin](#before-you-begin)
  - [On-prem](#on-prem)
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

Kubernetes Gateway API CRDs are not included into this distro - they should be preinstalled on the cluster.

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

The property runs a pre-install hook Job with the `kubectl` image named by
`global.kubectl.image`. The node tuning init container runs that same image, so a cluster
that cannot reach the default registry redirects it once:

```yaml
global:
  kubectl:
    image: <registry>/<repository>:<tag>
```


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
|global.kubectl.image|string|no|`ghcr.io/netcracker/qubership-docker-kubectl:0.0.9`|Full reference of the kubectl image, shared by the PSS patch Job and the node tuning init container. Neither can run an Istio image, because both need a shell and the ambient profile pulls distroless variants. Set it to pull from a registry this cluster can reach; a digest reference works too|
|patchPss.imagePullPolicy|string|no   |IfNotPresent |Image pull policy for the PSS patch Job                                                     |
|patchPss.resources |object |no       |75m/75Mi requests, 150m/150Mi limits|Resources for the PSS patch Job container                                          |
|patchPss.podSecurityContext|object|no|`runAsNonRoot: true`, `runAsUser: 1001`, `seccompProfile.type: RuntimeDefault`|Pod security context of the PSS patch Job. Must stay compliant with the policy currently enforced on the namespace, otherwise the Job cannot be admitted in order to relax it|
|patchPss.containerSecurityContext|object|no|no privilege escalation, drop `ALL`, read-only root filesystem|Container security context of the PSS patch Job|
|global.nodeTuning.enabled|boolean|no|true|Run an init container in the `cni` and `ztunnel` DaemonSets that raises the node inotify limits before the agent starts. Set it to `false` where the platform already tunes them, through `/etc/sysctl.d` or a `Tuned` profile|
|global.nodeTuning.maxUserInstances|integer|no|`8192`|Target value for `fs.inotify.max_user_instances`. The kernel default of 128 is a per-UID budget shared with kubelet and containerd, and the agents fail to start with `Too many open files` once it runs out|
|global.nodeTuning.maxUserWatches|integer|no|`65536`|Target value for `fs.inotify.max_user_watches`|

The init container writes to `/proc/sys/fs/inotify` through a `hostPath` mount, so it runs as root
on the node. The `privileged` policy this distribution already requires on `istio-system` covers that.

A limit is raised only when the node sits below the target, so a node tuned higher keeps its own
value. The container never fails the pod. Neither DaemonSet sets `updateStrategy`, so both roll at
the Kubernetes default of `maxSurge: 0`: a pod that cannot start leaves the node without its agent.

In Helm values you can provide any configuration parameters supported by corresponding vanilla Istio helm chart, e.g. to set default connectTimeout for `istiod`:
```yaml
qubership-istio: # root helm chart
  istiod: # nested helm chart
    meshConfig:
      defaultConfig:
        connectTimeout: 5s
```

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

# Upgrade
Install and upgrade procedures are identical.

# Rollback
Install via Helm with the previous version.

# See also

* [Namespace Enrollment into Istio Ambient Mesh](namespace-enrollment.md)
