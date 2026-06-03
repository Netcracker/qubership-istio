# Qubership Istio Installation Notes

<!-- TOC -->

## General Information

This is Qubership Istio Ambient Mesh Distribution. It includes vanilla Istio Ambient Mode helm charts with minimal modifications. 

This distribution Helm chart has the following structure:

- `qubership-istio` - Docker registry override; monitoring resources.
  - `base` - resources shared by all Istio revisions. This includes Istio CRDs.
  - `cni`- Istio CNI Plugin.
  - `ztunnel` - Istio ztunnel.
  - `istiod` - istiod (pilot) - Istio control plane.

## Prerequisites

This section describes prerequsites for Qubership Istio distribution. 

### Third-Party Software

#### Helm

Installation should be performed with Helm version 3.6+ or Helm version 4.

#### Kubernetes Version

Supported k8s versions: 1.31, 1.32, 1.33, 1.34, 1.35.

#### Kubernetes Gateway API CRDs

Kubernetes Gateway API CRDs are not included into this distro - they should be preinstalled on the cluster.

### Kubernetes RBAC Configuration

Qubership Istio should be installed under the service account with cluster-admin permissions in kubernetes.

## Deployment

### Layout

Qubership Istio distro should always be installed into `istio-system` namespace. No other applications should be installed in this namespace. Only single instance of Qubership Istio must be installed on kubernetes cluster. 

### HWE

#### Small

cni:
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
    limits:
      cpu: 200m
      memory: 500Mi

istiod:
  resources:
    requests:
      cpu: 500m
      memory: 2048Mi
    limits:
      cpu: 1000m
      memory: 2048Mi

ztunnel:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1024Mi

#### Medium

cni:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 400m
      memory: 1Gi
istiod:
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 1
      memory: 3Gi
ztunnel:
  resources:
    requests:
      cpu: 4
      memory: 1Gi
    limits:
      cpu: 8
      memory: 3Gi

#### Large

cni:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 400m
      memory: 1Gi
istiod:
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 4
      memory: 5Gi
ztunnel:
  resources:
    requests:
      cpu: 4
      memory: 1Gi
    limits:
      cpu: 8
      memory: 3Gi

### Deploy Parameters

#### Qubership Specific Parameters

| Name | Default Value | Description |
|------|---------------|-------------|
| MONITORING_ENABLED | `true`| Flag to install custom resources (PodMonitor and grafana dashboard) for prometheus monitoring. |

#### Vanilla Istio Parameters

In Helm values you can provide any configuration parameters supported by corresponding vanilla Istio helm chart, e.g. to set default connectTimeout for `istiod` you can set the following: 
```yaml
qubership-istio: # root helm chart
  istiod: # nested helm chart
    meshConfig:
      defaultConfig:
        connectTimeout: 5s
```

## Namespace Enrollment into Istio Ambient Mesh

### Creating New Namespace

When creating new namespace that should be enrolled into Istio Ambient Mesh, specify the following labels on the namespace: 

* `istio.io/dataplane-mode`: `ambient`
* `istio.io/use-waypoint`: `waypoint`

### Existing Namespace Enrollment

In order to enroll existing namespace into Istio Ambient Mesh follow the steps below: 

1. Add these two labels to namespace: 
  * `istio.io/dataplane-mode`: `ambient`
  * `istio.io/use-waypoint`: `waypoint`
2. Restart all workloads in namespace.