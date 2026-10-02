The following topics are covered in this chapter:

<!-- TOC -->
* [Deployment problems](#deployment-problems)
  * [Installation hangs on the pre-install hook](#installation-hangs-on-the-pre-install-hook)
* [Common problems](#common-problems)
  * [Pods do not start with `istio-cni` `Unauthorized`](#pods-do-not-start-with-istio-cni-unauthorized)
  * [Pods lose network after Istio is removed](#pods-lose-network-after-istio-is-removed)
  * [Istio resources are rejected by the validating webhook](#istio-resources-are-rejected-by-the-validating-webhook)
<!-- TOC -->

If you face a problem that is not described here, refer to the Istio [common problems](https://istio.io/latest/docs/ops/common-problems/) and [ztunnel troubleshooting](https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/) guides.

# Deployment problems

This section describes the issues you may face while installing or upgrading Qubership Istio.

## Installation hangs on the pre-install hook

The installation does not get past the `istio-patch-pss` hook Job. Its pod stays in `ContainerCreating` with the error from [Pods do not start with `istio-cni` `Unauthorized`](#pods-do-not-start-with-istio-cni-unauthorized): a node still carries the CNI plugin of a previous installation. The hook runs before the `istio-cni-node` DaemonSet, so the agents that would repair the node are never created.

As a solution, label the namespace yourself and install with the hook turned off:

```bash
kubectl label --overwrite ns istio-system pod-security.kubernetes.io/enforce=privileged
```

```yaml
ENABLE_PRIVILEGED_PSS: false
```

For more information, see [CNI plugin left on a node](troubleshooting-scenarios/cni_plugin_left_on_node.md).

# Common problems

## Pods do not start with `istio-cni` `Unauthorized`

New pods stay in `ContainerCreating` on some nodes, in any namespace, with this event:

```text
Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "<id>": plugin type="istio-cni" name="istio-cni" failed (add): Unauthorized
```

The node has the Istio CNI plugin but no `istio-cni-node` agent to keep its credentials valid. This happens after Istio was removed by deleting the `istio-system` namespace or its pods, or when the agent cannot start on the node.

As a solution, get the agent running on the node again: fix what keeps its pod from starting, or install Istio again if it was removed.

For more information, see [CNI plugin left on a node](troubleshooting-scenarios/cni_plugin_left_on_node.md).

## Pods lose network after Istio is removed

After Istio is removed, pods that were in the mesh stay ready but cannot resolve names or open connections. They still send their traffic to ztunnel, which is gone, because Istio was removed before they left the mesh. Such pods carry the annotation `ambient.istio.io/redirection: enabled`.

As a solution, remove the mesh labels from their namespaces and restart the pods of every Deployment, StatefulSet, and DaemonSet there:

```bash
kubectl label namespace <namespace> istio.io/dataplane-mode- istio.io/use-waypoint-
kubectl rollout restart deployment,statefulset,daemonset -n <namespace>
```

Recreate the pods that no controller owns.

## Istio resources are rejected by the validating webhook

Creating or changing any Istio resource fails in every namespace:

```text
failed calling webhook "validation.istio.io": failed to call webhook: Post "https://istiod.istio-system.svc:443/validate?timeout=10s": service "istiod" not found
```

The validating webhook configurations outlived istiod, which happens when the `istio-system` namespace is deleted instead of the release.

As a solution, install Istio again. If it is not coming back, delete the leftover webhook configurations:

```bash
kubectl delete validatingwebhookconfiguration istio-validator-istio-system istiod-default-validator
kubectl delete mutatingwebhookconfiguration istio-sidecar-injector
```
