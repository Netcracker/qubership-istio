# Installing Red Hat OpenShift Service Mesh 3 in Ambient Mode

## Prerequisites

The Red Hat OpenShift Service Mesh 3 operator is installed.

Install it from the `redhat-operators` catalog into the `openshift-operators` namespace. Set Update approval to `Manual`: with `Automatic`, OLM upgrades the operator as soon as a new version appears in the channel.

OVN-Kubernetes must route traffic via the host (`routingViaHost: true`). Red Hat requires it for ambient mode: with `false`, kubelet probes fail for every pod in ambient. Check the current value:

```sh
oc get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'
```

If it is not `true`, the cluster owner switches it. This changes the egress path of every pod in the cluster:

```sh
oc patch networks.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
```

OpenShift runs its own istiod for the Gateway API in `openshift-ingress` (GatewayClass `openshift-default`). It is not the mesh: Cloud-Core uses the `istio` GatewayClass created by this installation.

## Steps

The steps use two placeholders. Replace `<version>` with the Istio version the operator offers, written as `1.30.3`. Replace `<revision>` with the name of the IstioRevision resource the operator creates for it: `default-v` followed by the version with dots replaced by dashes, such as `default-v1-30-3`.

### Step 1: Create project with name istio-system

Navigate to Home -> Projects and create a new project named `istio-system`.

### Step 2: Install istiod

Ecosystem -> Installed Operators -> Red Hat OpenShift Service Mesh 3 -> Istio - Create Instance

Choose namespace `istio-system`.

Choose Istio version `<version>`.

Choose profile `openshift-ambient`.

Set Update strategy to `RevisionBased` for canary updates of Istio later.

Set Update Workloads Automatically to `true`. It applies to `RevisionBased` only: with `InPlace` there is one control plane, and workloads are not moved.

Provide the Helm value `trustedZtunnelNamespace: ztunnel`. ZTunnel is deployed to the `ztunnel` namespace in Step 6. By default, istiod on OpenShift trusts ztunnel only in `kube-system`: the `openshift` platform profile of the Istio charts sets it. Without this value, pods in ambient get no certificates, and ztunnel logs `certificate fetch failed`.

```yaml
pilot:
  trustedZtunnelNamespace: ztunnel
```

**Optionally**, provide the Helm value `numTrustedProxies: 1` to trust forwarded headers from one ingress proxy in front of the mesh, such as HAProxy or an Istio ingress gateway.

```yaml
meshConfig:
  defaultConfig:
    gatewayTopology:
      numTrustedProxies: 1
```

The resulting resource with the `RevisionBased` update strategy:

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
  profile: openshift-ambient
  updateStrategy:
    inactiveRevisionDeletionGracePeriodSeconds: 30
    type: RevisionBased
    updateWorkloads: true
  values:
    pilot:
      trustedZtunnelNamespace: ztunnel
  version: v<version>
```

The same resource with the `InPlace` update strategy and the optional `numTrustedProxies`:

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
  profile: openshift-ambient
  updateStrategy:
    inactiveRevisionDeletionGracePeriodSeconds: 30
    type: InPlace
  values:
    pilot:
      trustedZtunnelNamespace: ztunnel
    meshConfig:
      defaultConfig:
        gatewayTopology:
          numTrustedProxies: 1
  version: v<version>
```

Once istiod is ready, check that its CA secret exists. If the secret is gone, the running istiod keeps its root CA only in memory, and its next restart issues a new one: ztunnel and gateways then fail with `BadSignature` for a few minutes.

```sh
oc -n istio-system get secret istio-ca-secret
```

### Step 3: Create Project for Istio CNI

Istio CNI needs more privileges than istiod. Keeping them in one namespace breaks the OpenShift privilege separation principle and SCC boundaries.

Create project with name `istio-cni`.

### Step 4: Deploy Istio CNI

Ecosystem -> Installed Operators -> Red Hat OpenShift Service Mesh 3 -> Istio CNI

Click "Create IstioCNI"

Check that the Istio version is correct.

Select namespace `istio-cni`.

```yaml
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
  profile: openshift-ambient
  version: v<version>
```

### Step 5: Create Project for ZTunnel

Ztunnel needs more privileges than istiod. Keeping them in one namespace breaks the OpenShift privilege separation principle and SCC boundaries. Ztunnel could share the `istio-cni` namespace, since both need privileged access, but the default OpenShift layout puts each Istio component in its own namespace, and this guide follows it.

Create project with name `ztunnel`.

### Step 6: Deploy ZTunnel

Ecosystem -> Installed Operators -> Red Hat OpenShift Service Mesh 3 -> ZTunnel

Click "Create ZTunnel".

Choose namespace `ztunnel`.

Check that Istio version is correct.

If the Istio update strategy is `RevisionBased`, in `targetRef` choose kind `IstioRevision` and specify the name of the IstioRevision resource, `<revision>`. You can find it in Ecosystem -> Installed Operators -> Red Hat OpenShift Service Mesh 3 -> IstioRevisions.

```yaml
apiVersion: sailoperator.io/v1
kind: ZTunnel
metadata:
  name: default
spec:
  namespace: ztunnel
  targetRef:
    kind: IstioRevision
    name: <revision>
  values:
    ztunnel:
      logLevel: info
      terminationGracePeriodSeconds: 30
  version: v<version>
```

### Step 7: Create Project for Business Applications

Create a project for business applications and add the following labels with the `oc` client:

- `istio.io/dataplane-mode: ambient`
- `istio.io/use-waypoint: waypoint`

```sh
oc new-project core-mesh
```

```sh
oc label namespace core-mesh istio.io/dataplane-mode=ambient
```

```sh
oc label namespace core-mesh istio.io/use-waypoint=waypoint
```

### Step 8: Deploy Cloud-Core into the Project for Business Applications

Once all pods in the `istio-system`, `istio-cni`, and `ztunnel` projects are `Ready`, deploy Cloud-Core and other business applications.

Before that, check that the three resources are `Healthy` and that ztunnel gets certificates. The second command should print nothing:

```sh
oc get istio,istiocni,ztunnel
```

```sh
oc -n ztunnel logs ds/ztunnel | grep 'certificate fetch failed'
```

For Cloud-Core, set the deployment parameter `SERVICE_MESH_TYPE=Istio`. On a cluster without a load balancer, the Cloud-Core gateways need `ClusterIP` services: if they stay `LoadBalancer`, the deployment hangs on the gateway hooks.

After the deployment, pods of the project carry the annotation `ambient.istio.io/redirection: enabled` and pass their probes. Probes timing out with `Startup probe failed ... Client.Timeout exceeded` mean that `routingViaHost` is still `false`.
