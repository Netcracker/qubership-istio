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
    - [Gateway cluster filtering](#gateway-cluster-filtering)
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

The published chart carries the Istio subcharts with this distribution's changes from `tweak/` built into them, such as the image registry and the narrower `istiod` ClusterRole. Install and upgrade it as it is. `helm dependency update` and `helm dependency build` download the vanilla Istio subcharts again and replace the ones in the chart, so these changes are lost. This also applies to a deployment tool that runs either command before it installs.

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

To run the mesh on Red Hat OpenShift Service Mesh 3 instead of this distribution, see [Installing Red Hat OpenShift Service Mesh 3 in Ambient Mode](openshift-istio.md).

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
- The CNI plugin goes to `/home/kubernetes/bin`, where GKE looks for it. The upstream chart picks that directory only when the Kubernetes version it renders for contains `-gke`. A render that does not see the real cluster version misses the suffix, such as `helm template` or a deployment tool that drops vendor suffixes from the version, so this distribution sets the directory for `gke` itself. To use another directory, set `cni.cni.cniBinDir`: the `gke` profile overrides the shorter `cni.cniBinDir`.

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
| `istiod.env.PILOT_FILTER_GATEWAY_CLUSTER_CONFIG`                                                   | `"false"`                                                              | `"true"` sends each gateway only the Envoy clusters of the Services it references, so gateway memory no longer grows with the number of Services in the cluster. Keep it off while an EnvoyFilter on a gateway calls a Service by cluster name and no route of that gateway points at the Service, see [Gateway cluster filtering](#gateway-cluster-filtering) |
| `ztunnel.meshConfig.defaultConfig.proxyMetadata`                                                   | `ISTIO_META_DNS_CAPTURE: "true"`, `ISTIO_META_ROUTER_MODE: "sni-dnat"` | Proxy metadata the chart sets for ztunnel                                                                                                                                                                                                                                                                                                                |
| `cni.excludeNamespaces`                                                                            | `kube-system`, and the chart adds the release namespace                | The CNI plugin lets pods of these namespaces through without asking the Kubernetes API. The chart always adds the release namespace to the list, so the pre-install hook starts even on a node where a stopped agent with this list left the plugin behind, see [Troubleshooting](troubleshooting.md#installation-hangs-on-the-pre-install-hook). A list set in the values replaces `kube-system`, so keep it |
| `seccompProfile.type` on `global.proxy`, `cni`, `istiod`, and `istiod.gateways`                    | `RuntimeDefault`                                                       | Keeps the istiod and gateway pods admissible under `restricted`. No effect on the admission of `istio-cni-node` or `ztunnel`, which need `privileged` regardless                                                                                                                                                                                         |
| `resources` on `cni`, `istiod`, `ztunnel`                                                          | see [HWE](#hwe)                                                        | Requests and limits for the three components                                                                                                                                                                                                                                                                                                             |


### Gateway cluster filtering
By default istiod sends every gateway the Envoy cluster of every port of every Service in the cluster, whether its routes use it or not. Gateway memory then grows with the cluster: see [the hardware sizing model](../internal/hardware-sizing-model.md#5-gateway-sizing).

With `istiod.env.PILOT_FILTER_GATEWAY_CLUSTER_CONFIG: "true"`, a gateway gets only the clusters of:

- the backends of the routes attached to it,
- the services of `meshConfig.extensionProviders`,
- the JWKS hosts of the `RequestAuthentication` policies that apply to it,
- the Services listed in the `envoyfilter.istio.io/referenced-services` annotation of the `EnvoyFilter`s that apply to it, but see [EnvoyFilters that name a cluster](#envoyfilters-that-name-a-cluster).

Waypoints are not affected: they get only the Services bound to them either way. The flag applies to every gateway this istiod serves, and is experimental upstream.

#### EnvoyFilters that name a cluster
An `EnvoyFilter` that refers to an Envoy cluster by name, for example an HTTP filter that calls a service through `grpc_service.envoy_grpc.cluster_name`, works because istiod sends the gateway all clusters. No route of the gateway points at that Service, so with the flag on the cluster is no longer sent. Depending on the filter, Envoy either rejects the listener update, or accepts it and every call of the filter fails at request time; the filter's failure mode then decides whether requests pass without the filter or are rejected. The `EnvoyFilter` itself shows no error.

If a route of one gateway already points at the same Service, that gateway still gets the cluster, and the problem shows only on the other gateways the `EnvoyFilter` targets.

Upstream, the `envoyfilter.istio.io/referenced-services` annotation on the `EnvoyFilter` is meant to keep such a cluster. In Istio 1.30.4 it keeps it only until the next route change: a change to any `HTTPRoute` or `VirtualService` in the cluster sends the gateways an incremental update without the annotated Services, and the cluster stays missing until the next full update, such as an `EnvoyFilter` change or an istiod restart ([istio/istio#62067](https://github.com/istio/istio/issues/62067), fixed upstream, in no release yet).

So while a gateway has such an `EnvoyFilter`, either keep the flag off and size the gateway memory for all Services in the cluster (see [the hardware sizing model](../internal/hardware-sizing-model.md#5-gateway-sizing)), or turn it on and [pin the Service with a route](#pinning-a-service-with-a-route). Add the annotation either way. It changes nothing while the flag is off or the Service is pinned, and once a release with the fix is in place the pins can go without touching the `EnvoyFilter`s.

The annotation lists the Service the cluster belongs to as `<namespace>/<hostname>`, several separated by commas:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: request-check
  namespace: istio-gateways
  annotations:
    # The Service behind cluster_name below: <namespace>/<hostname>
    envoyfilter.istio.io/referenced-services: checker/request-checker.checker.svc.cluster.local
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: public-gateway
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: private-gateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.ext_proc
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
            grpc_service:
              envoy_grpc:
                # outbound|<port>||<hostname>: a cluster istiod builds for the Service
                cluster_name: outbound|9000||request-checker.checker.svc.cluster.local
```

The annotation has to be on the `EnvoyFilter` that applies to the gateway, through `targetRefs` or `workloadSelector`, and name the same Service as `cluster_name`. istiod adds the Service to those gateways only.

Services in `meshConfig.extensionProviders` need no annotation: istiod adds them by itself.

To find the `EnvoyFilter`s that name a cluster, before turning the flag on:

```bash
kubectl get envoyfilter -A -o yaml | grep -n -E 'cluster_name|cluster: |outbound\|'
```

Only a name of a cluster istiod builds for a Service, `outbound|<port>|<subset>|<hostname>`, is affected. A cluster that the `EnvoyFilter` adds itself (`applyTo: CLUSTER` with `operation: ADD`) is inserted into every update, full or incremental, and the flag does not filter it: such a filter needs neither the annotation nor a pin. Its connections do not go through the mesh, though: they carry no mTLS, and the target rejects them where a `PeerAuthentication` puts it in `STRICT` mode.

To check a gateway once the flag is on, the cluster has to be in its config, also after a route change:

```bash
istioctl proxy-config cluster deploy/<gateway>-istio -n <gateway namespace> | grep '<hostname>'
```

#### Pinning a Service with a route
A route backend is kept by every update, incremental ones included. A route that points at the Service therefore keeps its cluster on the gateway, and an `AuthorizationPolicy` that denies the route's host keeps anyone from calling the Service through it. One pin per Service, attached to every gateway the `EnvoyFilter` targets:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pin-request-checker
  namespace: checker
spec:
  parentRefs:
    - name: public-gateway
      namespace: istio-gateways
    - name: private-gateway
      namespace: istio-gateways
  # A host nobody calls: .invalid is reserved and never resolves
  hostnames:
    - pin-request-checker.invalid
  rules:
    - backendRefs:
        # The Service and the port of cluster_name: outbound|9000||request-checker.checker.svc.cluster.local
        - name: request-checker
          port: 9000
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-pin-request-checker
  namespace: istio-gateways
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: public-gateway
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: private-gateway
  action: DENY
  rules:
    - to:
        - operation:
            hosts:
              - pin-request-checker.invalid
            # The ports of the gateways' HTTP and HTTPS listeners
            ports:
              - "80"
              - "443"
```

- The route has to be accepted by every gateway in `parentRefs`. A listener takes routes only from the namespaces its `allowedRoutes` allows, by default its own: either allow the Service's namespace there, or put the route into the gateway's namespace and add a `ReferenceGrant` in the Service's namespace that lets `HTTPRoute`s from there refer to `Service`s.
- A listener with a `hostname` accepts only routes whose host matches it. For such a listener use a host under its domain that nobody calls, for example `pin-request-checker.example.com` for `*.example.com`, and deny that host.
- Without `ports` in the rule, a `DENY` rule on HTTP attributes alone denies all traffic of the gateway's TCP listeners, and istiod warns about it when the policy is applied. List the ports of the HTTP and HTTPS listeners, as in the `Gateway`'s `listeners[].port`.

Check that the pin is in place: the route is accepted by each gateway, and the host answers `403`:

```bash
kubectl get httproute pin-request-checker -n checker -o jsonpath='{range .status.parents[*]}{.parentRef.name}: {.conditions[?(@.type=="Accepted")].status}{"\n"}{end}'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pin-request-checker.invalid' http://<gateway address>/
```

The integration test `tests/gateway-cluster-filter` checks this pin: with the annotation removed the cluster stays through route changes, and goes once the route is deleted.

# Installation
## Before you begin
Qubership Istio distro should always be installed into `istio-system` namespace. No other applications should be installed in this namespace. Only single instance of Qubership Istio must be installed on kubernetes cluster.

### Install the release
Install the chart into the `istio-system` namespace with any deployment tool, for example Helm:

```bash
helm upgrade --install qubership-istio <chart> --namespace istio-system --create-namespace -f values.yaml
```

`<chart>` is the published chart, or a chart built from the repository as in the [Quick Start](../../README.md#quick-start). See [OpenShift](#openshift) or [GKE](#gke) for the values those platforms need.

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
Install the previous chart version, for example:

```bash
helm rollback qubership-istio <revision> -n istio-system
```

# Uninstall
Remove Istio in this order. Do not delete the `istio-system` namespace or force-delete its pods instead: the CNI agents then leave their plugin on the nodes, and new pods stop starting, see [Troubleshooting](troubleshooting.md#pods-do-not-start-with-istio-cni-unauthorized).

1. Redeploy the applications that run in Istio mode without it.
2. Remove the mesh labels from every enrolled namespace:

   ```bash
   kubectl get namespaces -l istio.io/dataplane-mode=ambient
   kubectl label namespace <namespace> istio.io/dataplane-mode- istio.io/use-waypoint-
   ```

   The pods leave the mesh within seconds, without a restart.
3. Uninstall the release with the tool that installed it, together with its resources, for example `helm uninstall qubership-istio -n istio-system`.
4. Wait until `istio-system` has no pods left:

   ```bash
   kubectl get pods -n istio-system
   ```

5. If Istio is not coming back, delete its CRDs and the namespace. Deleting the CRDs deletes every Istio resource in the cluster:

   ```bash
   kubectl get crd -o name | grep '\.istio\.io$' | xargs kubectl delete
   kubectl delete namespace istio-system
   ```

# See also

* [Namespace Enrollment into Istio Ambient Mesh](namespace-enrollment.md)
* [Troubleshooting](troubleshooting.md)
