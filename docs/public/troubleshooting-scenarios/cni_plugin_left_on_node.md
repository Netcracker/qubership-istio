# CNI plugin left on a node

This section describes how to detect and fix a node that keeps the Istio CNI plugin without a working `istio-cni-node` agent.

## How it happens

The `istio-cni-node` agent adds the Istio CNI plugin to the CNI configuration of its node, and the container runtime calls the plugin for every new pod on that node. The plugin asks the Kubernetes API about each pod, using a copy of the agent pod's token that the agent writes to the node. The token stops working when the agent pod is deleted.

When the agent stops while its DaemonSet still exists, it expects another agent to replace it and leaves the plugin in place. This is how upgrades and node reboots work. The node breaks when no agent comes back, for example:

* the `istio-system` namespace or its pods were deleted instead of the release;
* the new agent pod cannot start: its image cannot be pulled, Pod Security Admission rejects it, or a `nodeSelector` or taint keeps it off the node.

The plugin lets through only the agent's own pods, so that a new agent can always start and repair the node, and the pods of the namespaces in `cni.excludeNamespaces`.

## Logging

Pods on the node fail with:

```text
Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "<id>": plugin type="istio-cni" name="istio-cni" failed (add): Unauthorized
```

The last lines of the agent that left the plugin:

```text
terminating, but parent DaemonSet istio-cni-node is still present, this is an upgrade or a node reboot, leaving plugin in place
Ambient node agent shutting down - should stop cleanup? true
```

## Troubleshooting procedure

1. Check whether the node runs an agent:

   ```bash
   kubectl get pods -n istio-system -l k8s-app=istio-cni-node -o wide
   ```

2. If Istio is installed and the node has no agent, find out why its pod does not start: run `kubectl describe` on the `istio-cni-node` DaemonSet and its pods. The node recovers within seconds after the agent starts.
3. If Istio was removed, install it again. If the installation hangs on the `istio-patch-pss` hook, label the namespace yourself and install with the hook turned off:

   ```bash
   kubectl label --overwrite ns istio-system pod-security.kubernetes.io/enforce=privileged
   ```

   ```yaml
   ENABLE_PRIVILEGED_PSS: false
   ```

   The agents start and repair the nodes. Then remove Istio as described in [Uninstall](../installation.md#uninstall).
4. To repair a node without installing Istio, remove the `istio-cni` entry from the `plugins` list of the CNI configuration in `/etc/cni/net.d`, and delete `/var/run/istio-cni/istio-cni-kubeconfig`. A node debug pod uses the host network, so it starts on such a node:

   ```bash
   kubectl debug node/<node> -it --image=<image>
   chroot /host
   grep -l istio-cni /etc/cni/net.d/*
   ```

## Prevention

Remove Istio as described in [Uninstall](../installation.md#uninstall).

The chart adds its own namespace, `istio-system`, to `cni.excludeNamespaces`. The plugin checks this list before it calls the API, so the hook pod starts on such a node, the installation reaches the DaemonSet, and the new agents repair the nodes. A list you set in `cni.excludeNamespaces` replaces the default `kube-system`, so keep it there:

```yaml
cni:
  excludeNamespaces:
    - kube-system
```

The agents read the list when they start. The pod template of the DaemonSet carries a checksum of the `istio-cni-config` ConfigMap, so the agents restart automatically when the configuration changes and the new list reaches the nodes on the next upgrade.

The list protects a node only if the agent that left the plugin there already had `istio-system` in its list. On a node left by an agent without it, the hook pod still fails, even when the new installation has the list. Install with the hook turned off, as described in [Installation hangs on the pre-install hook](../troubleshooting.md#installation-hangs-on-the-pre-install-hook), and the new agents repair the node.

In short, `cni.excludeNamespaces` keeps the installation from deadlocking on the `istio-patch-pss` hook. It does not protect a node whose agent was killed while its DaemonSet still existed, and it protects nothing while no agent runs on the node: pods outside the list keep failing until an agent runs there again.

## Last resort: AMBIENT_DISABLE_SAFE_UPGRADE

`cni.env.AMBIENT_DISABLE_SAFE_UPGRADE: "true"` makes the agent remove the plugin on every shutdown, whatever its DaemonSet looks like:

```yaml
cni:
  env:
    AMBIENT_DISABLE_SAFE_UPGRADE: "true"
```

Use it only to get out of a node that already refuses pods, or to keep there the tooling that removes the agent pods before the DaemonSet. It is not a setting to install with:

* the flag is undocumented upstream and marked in its source as something that will be removed in a future Istio release;
* new pods of an enrolled namespace run outside the mesh for the seconds until the agent enrolls them, which is a hole in the mesh rather than a pause;
* the host rules that keep kubelet probes out of the mesh are taken down with it.

Turn it on only together with an update order that rolls `ztunnel` after the CNI agents. Otherwise a new pod can be enrolled by a restarted agent before any `ztunnel` on the node knows about it, and start without traffic. A `helm upgrade` applies the two DaemonSets together and orders nothing; the order is held only by a tool that reads sync waves, such as Argo CD, and was not verified there.

Do not reach for `istioOwnedCNIConfig: true` instead. It does not make the agent clean up on an abnormal stop; it widens the branch that leaves the plugin behind, so an agent that fails for any reason now leaves the plugin where a default install would have removed it.
