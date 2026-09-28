<!-- TOC -->
- [Troubleshooting](#troubleshooting)
  - [New pods fail with `istio-cni` `Unauthorized`](#new-pods-fail-with-istio-cni-unauthorized)
  - [Installation hangs on the `istio-patch-pss` hook](#installation-hangs-on-the-istio-patch-pss-hook)
  - [Pods lose DNS and connections after Istio is removed](#pods-lose-dns-and-connections-after-istio-is-removed)
  - [Istio resources are rejected with `failed calling webhook`](#istio-resources-are-rejected-with-failed-calling-webhook)
  - [`istio-system` was deleted](#istio-system-was-deleted)
<!-- /TOC -->

# Troubleshooting

Most of the failures below come from removing Istio in the wrong order. [Uninstall](installation.md#uninstall) describes the order that avoids them.

## New pods fail with `istio-cni` `Unauthorized`

Pods in any namespace stay in `ContainerCreating`, and their events show:

```text
Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "<id>": plugin type="istio-cni" name="istio-cni" failed (add): Unauthorized
```

**Cause.** The `istio-cni-node` agent adds the Istio CNI plugin to the CNI configuration of its node, and the container runtime calls the plugin for every new pod on that node, in the mesh or not. The plugin asks the Kubernetes API about each pod, using a copy of the agent pod's token that the agent writes to the node. That token is bound to the agent pod and stops working as soon as the pod is deleted.

When the agent stops while its DaemonSet still exists, it takes the stop for an upgrade or a node reboot and leaves the plugin on the node, so that the next agent takes over. This happens when the agent pods are deleted before the DaemonSet, for example when the `istio-system` namespace is deleted. Until a new agent starts on the node and writes a fresh token, every new pod on it fails as above. The plugin lets through only the agent's own pods, so that a new agent can always start and repair the node, and the pods of the namespaces in `cni.excludeNamespaces`.

**Fix.** Check whether an agent runs on the affected node:

```bash
kubectl get pods -n istio-system -l k8s-app=istio-cni-node -o wide
```

- **Istio is installed, but the node has no agent.** Find out why the agent pod does not start: `kubectl describe` on the DaemonSet and its pods. Typical reasons are an image that cannot be pulled, a Pod Security Admission rejection, the missing ResourceQuota on GKE, or a `nodeSelector` or taint that keeps the agent off the node. The node recovers within seconds after the agent starts.
- **Istio was removed.** Install it again: the new agents repair the nodes. If the installation hangs, see [Installation hangs on the `istio-patch-pss` hook](#installation-hangs-on-the-istio-patch-pss-hook). Then remove Istio as described in [Uninstall](installation.md#uninstall).

Without reinstalling, repair each node by hand: remove the `istio-cni` entry from the `plugins` list of the CNI configuration in `/etc/cni/net.d`, and delete `/var/run/istio-cni/istio-cni-kubeconfig`. A node debug pod uses the host network and starts even on such a node:

```bash
kubectl debug node/<node> -it --image=<image>
chroot /host
grep -l istio-cni /etc/cni/net.d/*
```

## Installation hangs on the `istio-patch-pss` hook

The installation does not get past the pre-install hook: in Argo CD the `istio-patch-pss` PreSync Job never completes, and Helm reports:

```text
Error: INSTALLATION FAILED: failed pre-install: resource not ready, name: istio-patch-pss, kind: Job, status: InProgress
```

The hook pod stays in `ContainerCreating` with the `Unauthorized` error from [the section above](#new-pods-fail-with-istio-cni-unauthorized).

**Cause.** The hook labels `istio-system` for Pod Security Admission before any other manifest of the release is applied. Its pod is an ordinary pod, so it cannot start on a node that still has the plugin with a dead token. The DaemonSets that would repair the node come later in the release and are never created.

**Fix.** Label the namespace yourself and install with the hook turned off:

```bash
kubectl label --overwrite ns istio-system pod-security.kubernetes.io/enforce=privileged
```

```yaml
ENABLE_PRIVILEGED_PSS: false
```

The DaemonSets are created right away, the agents start, and each one writes a fresh token to its node within seconds. Later installations can turn the hook back on.

**Prevention.** Keep `istio-system` in `cni.excludeNamespaces`. The plugin checks the list before it calls the Kubernetes API, so the hook pod starts whatever the state of the node. List `kube-system` as well, because a list in the values replaces the default one instead of extending it:

```yaml
cni:
  excludeNamespaces:
    - kube-system
    - istio-system
```

The agents write the list to the nodes when they start, and changing the value does not restart them. Restart them once after the change:

```bash
kubectl rollout restart daemonset/istio-cni-node -n istio-system
```

A node where the plugin was left behind before that restart keeps the old list, and the fix above is still needed there once.

## Pods lose DNS and connections after Istio is removed

After Istio is removed, some pods stay `Running` and ready but cannot resolve names or open connections. Typical signs are `UnknownHostException` or `Could not resolve host` in the application logs, `nslookup` failing with `Connection refused`, and Envoy-based gateways that lost their control plane. These pods carry the annotation `ambient.istio.io/redirection: enabled`:

```bash
kubectl get pods -A -o jsonpath='{range .items[?(@.metadata.annotations.ambient\.istio\.io/redirection=="enabled")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

**Cause.** Inside the network namespace of every pod in the mesh, the CNI agent installs rules that redirect its outbound traffic and DNS queries to ztunnel. Removing Istio does not remove these rules. Once ztunnel is gone, they send the traffic nowhere. Readiness probes are exempt from the redirection, so the pods still look healthy.

**Fix.** Remove the `istio.io/dataplane-mode` and `istio.io/use-waypoint` labels from the namespaces of these pods, then recreate the pods:

```bash
kubectl label namespace <namespace> istio.io/dataplane-mode- istio.io/use-waypoint-
kubectl rollout restart deployment -n <namespace>
```

Installing Istio again also fixes them without a restart: the new agents take the pods of unlabeled namespaces out of the mesh and put the pods of labeled namespaces back in.

## Istio resources are rejected with `failed calling webhook`

Creating or changing any Istio resource, for example a `PeerAuthentication` or an `EnvoyFilter`, fails in every namespace:

```text
Internal error occurred: failed calling webhook "validation.istio.io": failed to call webhook: Post "https://istiod.istio-system.svc:443/validate?timeout=10s": service "istiod" not found
```

**Cause.** The validating webhook configurations `istio-validator-istio-system` and `istiod-default-validator` are cluster-scoped and outlived istiod, which happens when the `istio-system` namespace is deleted instead of the release. Their failure policy is `Fail`, so the Kubernetes API server rejects every request it cannot validate.

**Fix.** Install Istio again, so that istiod serves the webhooks. If Istio is not coming back, delete the leftover webhook configurations:

```bash
kubectl delete validatingwebhookconfiguration istio-validator-istio-system istiod-default-validator
kubectl delete mutatingwebhookconfiguration istio-sidecar-injector
```

## `istio-system` was deleted

Deleting the namespace instead of the release causes all of the failures above at once:

- the nodes keep the plugin with a dead token, and new pods fail with `Unauthorized`;
- the pods that were in the mesh keep their redirection rules and lose DNS and connections;
- the webhook configurations, the ClusterRoles and ClusterRoleBindings, and the CRDs stay on the cluster, and the webhooks reject every Istio resource.

The shortest way back is to install Istio again, with the hook turned off if the installation hangs, see [Installation hangs on the `istio-patch-pss` hook](#installation-hangs-on-the-istio-patch-pss-hook). The new agents repair the nodes and the pods, and istiod serves the webhooks again. If Istio is not meant to stay, remove it afterwards as described in [Uninstall](installation.md#uninstall).

To clean up without reinstalling, repair the nodes and the pods as described in the sections above, then delete the cluster-scoped leftovers:

```bash
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep istio
kubectl get clusterroles,clusterrolebindings -o name | grep -E 'istio|ztunnel'
kubectl get crd -o name | grep '\.istio\.io$'
```

Deleting the CRDs deletes every Istio resource in the cluster.
