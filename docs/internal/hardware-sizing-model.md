# Istio Ambient Mesh Hardware Sizing Model

Units: memory is in Mi, CPU in vCPU throughout. The coefficients of Envoy, ztunnel and istiod are calibrated on Istio 1.30.4, see [12. Calibration](#12-calibration); the CNI figures follow the CNI providers' guidance.

## 1. Input Parameters

The model is sized from what is declared: the profile, the nodes, what runs outside the environments and what one environment contains. Each input is counted in advance, from the deployment descriptors of an environment or from a running environment of the same release (see [1.3](#13-counting-the-inputs)); traffic comes from the profile, and everything else is derived from these through the calibrated coefficients, so one cluster is sized in one pass, without measuring each environment.

It gives two results: the HWE of Istio itself, cluster-wide (ztunnel, istiod, CNI), and the HWE of the proxies of one environment (its gateways and its waypoint), which go into the resource profile of `qubership-core-mesh-config`.

### 1.1 Declared inputs

Cluster:
- profile: `prod` or `dev`, the resource profile of `qubership-core-mesh-config` and the traffic class of section 1.2
- nodeCount: worker nodes
- envs: environments in the cluster; each one is a namespace with its own `qubership-core-mesh-config`, so its own public, private and egress gateways and its own waypoint
- platformServices: Services of the cluster not counted in envs, in the mesh or not: istiod discovers every namespace, so they enter its memory, ztunnel's and, without the flag, every gateway. With `meshConfig.discoverySelectors` set, only the namespaces it selects count
- platformPods: pods of the cluster not counted in envs, on the same terms
- platformServicePorts, optional: ports of those Services together. Without it the model gives them the portsPerService of the environment
- filterGatewayClusters: whether istiod runs with `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true`. A gateway whose EnvoyFilter names a cluster cannot use it yet (see section 5)
- egressGateway: whether the environments have an egress gateway; `false` with `SKIP_EGRESS_GATEWAY_CREATION: true`

One environment; where environments differ, the largest one:
- servicesPerEnv: Services of the namespace
- servicePortsPerEnv: ports of all those Services together; they give the Envoy clusters of the waypoint and, with the flag off, of every gateway in the cluster. Either counted, or given as portsPerService
- portsPerService: average ports per Service of the environment, in place of servicePortsPerEnv when the ports are not counted
- podsPerEnv: pods at peak, every replica and the HPA's maximum included: they are the endpoints of its Services and the workloads ztunnel and istiod keep
- configObjectsPerEnv: Istio and Gateway API objects of the namespace: routes, AuthorizationPolicies, DestinationRules, ServiceEntries, EnvoyFilters
- referencedServices[public], referencedServices[private], referencedServices[egress]: distinct Services the routes attached to each gateway point at. With the flag their ports give the gateway's Envoy clusters, so the gateways differ: egress, with only its fallback route, references one Service, and egress < private < public
- referencedEndpoints[gateway], optional: endpoints of those Services at peak. Without it the model gives them the average number of pods per Service of the environment

### 1.2 Profile values

| Value | prod | dev | Meaning |
|---|---|---|---|
| proxyReplicas | 2 | 1 | replicas of each gateway and waypoint (`REPLICAS` of the profile) |
| proxyHpaMaxReplicas | 5 | 5 | `HPA_MAX_REPLICAS` of the profile |
| trafficReserveMi | 128 | 32 | memory per proxy pod for its connections and requests in flight, see [4.3](#43-traffic) |
| connectionsPerPod | 20 | 5 | open connections of an application pod |
| rpsPerPod | 25 | 1 | peak requests per second of an application pod |
| mbpsPerPod | 12.5 | 0.5 | peak traffic of an application pod, request and response bodies together |
| newConnectionShare | 0.1 | 0.1 | share of requests that open a new connection; keep-alive carries the rest |
| l7TrafficRatio | 0.3 | 0.3 | share of the traffic that goes through waypoints |
| gatewayTrafficShare | public 0.2, private 0.1, egress 0.01 | the same | share of an environment's requests and traffic through each of its gateways |

### 1.3 Counting the inputs

From a running environment of the same release, `NS` its namespace; the same numbers follow from its deployment descriptors: one Service per microservice with its ports, its replicas and HPA maximum, its routes.

```
# servicesPerEnv, servicePortsPerEnv
kubectl get svc -n $NS -o json | jq '.items | length, ([.[].spec.ports | length] | add)'

# podsPerEnv: the HPA maximum where there is one, replicas otherwise
kubectl get deploy,statefulset,hpa -n $NS -o json | jq '
  ([.items[] | select(.kind == "HorizontalPodAutoscaler") | {(.spec.scaleTargetRef.name): .spec.maxReplicas}] | add // {}) as $hpa
  | [.items[] | select(.kind != "HorizontalPodAutoscaler") | $hpa[.metadata.name] // .spec.replicas // 1] | add'

# configObjectsPerEnv
kubectl get httproutes,grpcroutes,authorizationpolicies,destinationrules,serviceentries,envoyfilters,peerauthentications -n $NS -o name | wc -l

# referencedServices of each gateway: routes from any namespace attached to it
for GW in public-gateway private-gateway egress-gateway; do
  kubectl get httproutes,grpcroutes -A -o json | jq --arg ns $NS --arg gw $GW '
    [.items[] | .metadata.namespace as $rns
     | select(any(.spec.parentRefs[]; .name == $gw and (.namespace // $rns) == $ns))
     | .spec.rules[]?.backendRefs[]? | select((.kind // "Service") == "Service")
     | "\(.namespace // $rns)/\(.name)"] | unique | length'
done

# platformServices, platformPods: everything in the cluster outside the environment namespaces
# (with discoverySelectors, only the namespaces it selects)
ENVS="env-1 env-2"
for R in svc pods; do
  kubectl get $R -A -o json | jq --arg envs "$ENVS" '
    ($envs | split(" ")) as $e | [.items[] | select(.metadata.namespace | IN($e[]) | not)] | length'
done

# platformServicePorts
kubectl get svc -A -o json | jq --arg envs "$ENVS" '
  ($envs | split(" ")) as $e | [.items[] | select(.metadata.namespace | IN($e[]) | not) | .spec.ports | length] | add'
```

---

## 2. Derived Values

### Cluster
```
appPods               = envs * podsPerEnv
podsInCluster         = appPods + platformPods
servicesInCluster     = envs * servicesPerEnv + platformServices
portsPerService       = servicePortsPerEnv / servicesPerEnv     when the ports are counted
platformServicePorts  = portsPerService * platformServices      unless declared
servicePortsInCluster = envs * servicePortsPerEnv + platformServicePorts
endpointsInCluster    = podsInCluster
configObjectCount     = envs * configObjectsPerEnv
```
- podsInCluster and servicesInCluster count every pod and Service in every namespace, in the mesh or not: ztunnel and istiod keep a workload for each pod, and a gateway without the flag sees every Service and every endpoint
- Every pod is an endpoint of one Service
- Environments of different size: the sums over them in place of `envs *`

### Traffic
```
totalRps                = rpsPerPod * appPods
totalThroughputGbps     = mbpsPerPod * appPods / 1000
newConnectionsPerSecond = newConnectionShare * totalRps
connectionsPerNode      = connectionsPerPod * appPods / nodeCount
```

### Traffic per node
```
rpsPerNode            = 2 * totalRps / nodeCount
newConnectionsPerNode = 2 * newConnectionsPerSecond / nodeCount
throughputPerNodeGbps = 2 * totalThroughputGbps / nodeCount
```
- Each request crosses two ztunnels, the one of the client's node and the one of the server's node, hence the 2
- Traffic is spread evenly over the nodes

### Proxies of an environment
```
referencedEndpoints[gateway] = referencedServices[gateway] * podsPerEnv / servicesPerEnv   unless declared
servicePortsPerEnv           = portsPerService * servicesPerEnv                            unless declared
gatewaysPerEnv               = egressGateway ? 3 : 2
gatewayRps[gateway]          = gatewayTrafficShare[gateway] * totalRps / envs
gatewayGbps[gateway]         = gatewayTrafficShare[gateway] * totalThroughputGbps / envs
connectedProxies             = nodeCount + envs * (gatewaysPerEnv + 1) * proxyReplicas
```

---

## 3. ztunnel Sizing (L4 Data Plane)

### CPU per node
```
ztunnelCpuPerNode = 0.06 * rpsPerNode / 1000
                  + 0.2  * throughputPerNodeGbps
                  + 0.45 * newConnectionsPerNode / 1000
                  + 0.04 * connectionsPerNode / 1000
```
- Measured on EKS with Istio 1.30.4, fortio between two nodes, one side of the connection each: 0.048–0.053 vCPU per 1000 requests per second, 0.13–0.20 per Gbps (HBONE, mTLS), 0.32 (server) to 0.43 (client) per 1000 new connections a second, about 0.04 per 1000 open connections at one request a second each beyond the requests themselves. The costs add up; they are not a maximum of each other
- Replaces `MAX(connectionsPerNode / 2000, throughputPerNodeGbps * 0.8)`: an open connection costs about a twelfth of that and a Gbps of the cluster's traffic half, while requests and new connections, which it left out, are what ztunnel spends most on with small messages
- The chart's ztunnel CPU limit, 400m, was reached at about 1.6 Gbps between two nodes (throttled 22%); with small requests it covers about 6,000 requests a second crossing the node

---

### Memory per node
```
ztunnelUsedPerNodeMi = 64
                     + 0.008 * podsInCluster
                     + 0.004 * servicesInCluster
                     + 0.03 * connectionsPerNode
ztunnelMemPerNodeMi  = roundUp(ztunnelUsedPerNodeMi * 1.5, 32)
```
- 64 Mi base: an idle ztunnel with no pods of its own measured 2–3 Mi on kind. On a real EKS cluster with 13–19 pods per node and 83 workloads, ztunnel held 26–38 Mi, of which under 1 Mi is the cluster-size part below; the rest is the pods of its node (certificates, captured sockets) and the allocator. 64 Mi keeps about twice the highest node, a full node of pods included
- 0.008 Mi (8 KiB) per pod and 0.004 Mi per Service of the whole cluster: istiod sends every ztunnel every workload and Service, on every node, whether the node runs them or not. Pods outside the mesh cost the same as pods in it. Measured 7.5–8.0 KiB per pod and 3.5–3.6 KiB per Service on kind with fake pods. A WorkloadEntry, which carries less metadata than a pod, costs less: under 1 KiB on EKS; the model takes the cost of a pod
- 0.03 Mi per connection: both ends together, 12–14 KiB on the client side and 10 KiB on the server side, measured 0.023 Mi
- 1.5 → peak of the busiest node over the measured average. ztunnel is a DaemonSet with one limit for every node, while connectionsPerNode is the average: connections are not spread evenly, and nodes running gateways, databases or brokers hold more of them, so the limit covers the busiest node rather than the average one; it also covers bursts of new connections above the steady state

---

### Totals
```
ztunnelCpuTotal = ztunnelCpuPerNode * nodeCount  
ztunnelMemTotalMi = ztunnelMemPerNodeMi * nodeCount  
```
- ztunnel runs once per node (DaemonSet model)

---

## 4. Envoy Proxy Memory (common to gateways and waypoints)

Gateways and waypoints are the same Envoy, and the resource profiles of `qubership-core-mesh-config` set one memory value per proxy pod: the chart uses it as both request and limit. This section gives the memory of one pod; sections 5 and 6 say what goes into it for each kind of proxy.

### 4.1 Envoy clusters

istiod turns every port of every Service a proxy can see into an Envoy cluster, plus subsets from DestinationRules. The memory of an idle Envoy follows the number of these clusters and of the endpoints in them, not the size of the config: a cluster takes about 1.5 kB of CDS and about 90 KiB of memory, which goes to the objects Envoy builds for it: load balancer, stats; each endpoint in it about 18 KiB more.

```
gatewayClusters  = 1.2 * portsInScope + 12
waypointClusters = 1.6 * servicePortsPerEnv + 12
```
- 1.2 Envoy clusters per Service port on a gateway: istiod builds one cluster per port, `outbound|<port>||<host>`, and one more per port for each DestinationRule subset; the 0.2 covers the subsets. On a running cluster, `cluster_manager.active_clusters` of a gateway less 12, divided by the ports of the Services it sees, gives the real ratio: 0.9 on a real EKS cluster with 81 Services, 122 ports and one DestinationRule without subsets
- 1.6 Envoy clusters per Service port on a waypoint, which builds more than one per port: 1.45 on the same EKS cluster
- 12 → static clusters every proxy has (xDS, SDS, stats, passthrough, blackhole, HBONE)

### 4.2 Idle memory

```
hosts     = endpointsInScope * (clusters - 12) / servicesInScope
idleMemMi = base + 0.092 * clusters + 0.018 * hosts
```
- An endpoint sits in every cluster of its Service, one per port and per subset: a gateway holds 1.2 hosts per endpoint and port of its Service, a waypoint 1.6
- 0.092 Mi (94 KiB) per Envoy cluster, pod working set, Istio 1.30. Measured on kind with Istio 1.30.4: 0.088 Mi per cluster on a gateway pod that received its config at start, 1 worker. A pod that grew into the same config can hold less, but a restart brings it back to the higher value, so the model follows the restarted pod. On a real EKS cluster a gateway restarted at each step added 106 Mi per 1000 Services of one port with two ambient endpoints each (WorkloadEntries), against 128 Mi in the model; at 2082 Services (2124 clusters, 4102 endpoints) the gateways held 218–258 Mi against 319 Mi in the model
- Envoy does not give memory back when its config shrinks: on EKS, gateways that had held 2000 more Services stayed at 110 Mi after those were deleted, against 35 Mi before. Size for the largest config a gateway will have held, not the current one
- base = 50 Mi for a gateway; 29–32 Mi measured at idle on kind
- base = 75 Mi for a waypoint: an idle waypoint holds more than its clusters account for, and that part varies between clusters, so the base is set high; 33–34 Mi measured on kind
- Includes pilot-agent, which runs in the same `istio-proxy` container
- 0.018 Mi (18 KiB) per endpoint of every cluster, measured 17–19 KiB on the gateway and the waypoint with ambient endpoints, which carry HBONE addresses. On EKS a WorkloadEntry endpoint cost about 9 KiB and a plain one about 5 KiB; a WorkloadEntry carries fewer labels and less metadata than a pod, so the coefficient follows the fake pods on kind. At 3 endpoints per Service, endpoints add 60% to a cluster. Without `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` a gateway holds the endpoints of every Service in the cluster
- The per-cluster cost grows with the number of Envoy worker threads, each of which builds its own load balancer and host set for every cluster. Istio sets the number of workers to the CPU limit of the proxy, rounded up: 1 for the gateways and 2 for the waypoint in the current profiles. Measured: about 84 KiB plus 5 KiB per worker, so 88 KiB with 1 worker, 95 with 2 and 103 with 4; 0.092 Mi covers up to 2 workers, and a profile with a higher CPU limit adds 0.005 Mi per cluster for each worker above 2

### 4.3 Traffic

Envoy holds buffers for open connections and for requests in flight, up to `per_connection_buffer_limit_bytes` per connection (1 MiB in Envoy by default). The profile reserves a fixed amount for them per pod:

```
trafficMemMi = trafficReserveMi
             = 0.07 * connections + 0.04 * requestsInFlight   what the reserve covers
```
- 0.07 Mi (70 KiB) per open keep-alive connection, measured 65–74 KiB on the gateway and the waypoint. Most of it is not Envoy's heap (16 KiB on the gateway) but socket buffers, which the kernel charges to the pod
- 0.04 Mi per request in flight with bodies of a few KiB, measured 23–37 KiB. Large bodies are held while in flight: per 100 KiB of body, about 0.3 Mi on a gateway and 0.65 Mi on a waypoint, which buffers more
- trafficReserveMi: 128 Mi per pod in prod covers about 1,800 idle connections or 1,100 with a request in flight each; 32 Mi in dev about 450 or 290

### 4.4 Limit per pod

```
proxyLimitMi = roundUp(idleMemMi * 1.4 + trafficMemMi, 32)
```
- 1.4 → peak of the idle part over the steady state: the first config load peaks above the steady state, by 5–9% with clusters alone and by up to 39% with thousands of endpoints (measured 1.26–1.39 at 20 endpoints per Service); the per-cluster cost also varies with subsets
- The chart sets request = limit, so this memory is reserved on the node for every replica

### 4.5 Reserved memory

```
proxyReservedMi     = proxyLimitMi * proxyReplicas
proxyReservedMaxMi  = proxyLimitMi * proxyHpaMaxReplicas
```

---

## 5. Gateway Sizing

`qubership-core-mesh-config` creates three gateways in each environment: `public-gateway`, `private-gateway`, `egress-gateway`. Each is a Gateway API `Gateway`, and istiod runs an Envoy deployment `<name>-istio` for it. Public and private accept routes from all namespaces; egress accepts only routes from its own namespace, and is not created with `SKIP_EGRESS_GATEWAY_CREATION: true`.

### Services in scope

```
servicesInScope  = filterGatewayClusters ? referencedServices[gateway]                   : servicesInCluster
portsInScope     = filterGatewayClusters ? referencedServices[gateway] * portsPerService : servicePortsInCluster
endpointsInScope = filterGatewayClusters ? referencedEndpoints[gateway]                  : endpointsInCluster
```
- Without the flag (the istiod default) a gateway gets the clusters of all Services in all namespaces, whether its routes use them or not. Its memory grows with the cluster, not with what it serves
- With the flag, only Services the gateway references, with all their ports. Egress with only its fallback route references one Service
- An EnvoyFilter that names a cluster directly (`envoy_grpc.cluster_name: outbound|...`) of a Service no route of the gateway points at rules the flag out until a release carries the fix of [istio/istio#62067](https://github.com/istio/istio/issues/62067): in Istio 1.30.4 the `envoyfilter.istio.io/referenced-services` annotation keeps the cluster only until the next route change. Size such gateways without the flag: see [Gateway cluster filtering](../public/installation.md#gateway-cluster-filtering)

### Memory

```
gatewayClusters = 1.2 * portsInScope + 12
gatewayHosts    = 1.2 * portsPerService * endpointsInScope
gatewayIdleMi   = 50 + 0.092 * gatewayClusters + 0.018 * gatewayHosts
gatewayLimitMi  = roundUp(gatewayIdleMi * 1.4 + trafficMemMi, 32)
```

Per gateway; the sum over the gateways of one environment is the total of its namespace, see [9.2](#92-proxies-of-one-environment):

```
gatewayMemPerEnvMi = Σ gatewayLimitMi[gateway] * proxyReplicas
```
- Without the flag every gateway of every environment holds every Service and endpoint of the cluster: the gateways of each environment grow with all the environments together

### How far a fixed limit goes without the flag

| Limit | Services in the cluster at which idle memory reaches the limit, 1 port per Service, 1 / 2 endpoints | the same, 2 ports per Service | Services in the cluster this model allows: prod, 2 endpoints, 128 Mi reserve, 1 / 2 ports per Service |
|---|---|---|---|
| 200Mi | 1,128 / 969 | 564 / 485 | none; 522 / 261 with dev, 1 endpoint, 32 Mi reserve |
| 250Mi | 1,507 / 1,295 | 753 / 647 | 235 / 117 |
| 475Mi | 3,211 / 2,760 | 1,606 / 1,380 | 1,281 / 640 |
| 512Mi | 3,492 / 3,001 | 1,746 / 1,500 | 1,453 / 727 |

### CPU
```
gatewayCpu[gateway] = 0.25 * gatewayRps[gateway] / 1000 + 0.35 * gatewayGbps[gateway]
gatewayCpuPerEnv    = Σ gatewayCpu[gateway]
```
- Measured on EKS with Istio 1.30.4, a gateway with CPU limit 2 (two Envoy workers) and fortio from another node: 0.23 vCPU per 1000 requests per second and 0.26 per Gbps, R² 0.999; rounded up, the same as for waypoints
- All replicas together: the CPU limit of the profile times the replicas, at the HPA's target utilization, has to cover it. A gateway with a 250m limit handles about 1,000 small requests a second per replica

---

## 6. Waypoint Proxy Sizing (L7)

One waypoint per environment, bound to the Services of its namespace by `istio.io/use-waypoint`. A waypoint gets only the Services bound to it, so its configuration follows the size of its namespace, not of the cluster. `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` does not change it.

### L7 traffic of an environment
```
l7ThroughputGbps = totalThroughputGbps * l7TrafficRatio / envs
l7Rps            = totalRps * l7TrafficRatio / envs
```
- Only a fraction of traffic is processed at L7  
- Typical baseline: 20–40%

---

### CPU
```
waypointCpuPerEnv = 0.25 * l7Rps / 1000 + 0.35 * l7ThroughputGbps
```
- Measured on EKS with Istio 1.30.4, a waypoint with CPU limit 2 (two Envoy workers): 0.18 vCPU per 1000 requests per second and 0.32 per Gbps, R² 0.993
- Replaces `l7ThroughputGbps * 3`, which put the whole cost on bytes. With 1 KiB each way a Gbps is about 60,000 requests a second, about 15 vCPU by this formula and five times what the old one gave; with 100 KiB bodies a Gbps costs well under 1 vCPU

---

### Memory

```
waypointClusters   = 1.6 * servicePortsPerEnv + 12
waypointHosts      = 1.6 * servicePortsPerEnv * podsPerEnv / servicesPerEnv
waypointIdleMi     = 75 + 0.092 * waypointClusters + 0.018 * waypointHosts
waypointLimitMi    = roundUp(waypointIdleMi * 1.4 + trafficMemMi, 32)

waypointMemPerEnvMi = waypointLimitMi * proxyReplicas
```
- waypointMemPerEnvMi is the waypoint's part of the total of its namespace, see [9.2](#92-proxies-of-one-environment)
- Replaces `300 + l7ThroughputGbps * 1000 * 0.2`. That formula gave one value for all waypoints together and tied memory to Gbps, while the memory of each waypoint follows the Service ports of its namespace
- The profile has one `WAYPOINT_MEMORY_LIMIT` for every environment

---

## 7. Control Plane Sizing (istiod)

### CPU
```
istiodCpuTotal = 0.5
```
- Pod churn costs istiod 4–12 CPU milliseconds per replaced pod (EKS, real pods, rollout restarts at 10 to 90 a minute; 10–14 ms on kind with 50 ztunnels connected): 90 restarts a minute, 440 pods, take under 0.01 cores. Churn therefore does not enter the formula
- 0.5 vCPU covers full pushes to every proxy after an istiod restart or a mesh-wide config change; idle istiod uses 0.002 cores, and a restart with every proxy reconnecting takes 1–2 CPU seconds
- Replaces `(totalPods / 1500) * churnFactor`, orders of magnitude above istiod's actual use

---

### Memory
```
connectedProxies = nodeCount + gateway pods + waypoint pods
istiodUsedMi     = 50
                 + 0.07 * servicesInCluster
                 + 0.05 * podsInCluster
                 + 0.05 * configObjectCount
                 + 1 * connectedProxies
istiodMemTotalMi = max(512, roundUp(istiodUsedMi * 2, 32))
```
- 50 Mi base, measured 41–47 Mi
- 0.07 Mi per Service and 0.05 Mi per pod, working set: measured 57–67 KiB and 44–47 KiB. Replaces 1.5 Mi per pod, about 30 times too high. On a real EKS cluster, 64 KiB per Service with two WorkloadEntries (R² 0.996); the formula gave 71 Mi for an istiod that held 59 Mi
- 0.05 Mi per config object: an upper bound. 1000 HTTPRoutes changed istiod by less than its caches vary, under 50 KiB each
- 1 Mi per connected proxy: ztunnels (one per node), gateways and waypoints. A ztunnel connection measured 0.65–1.07 Mi of heap at 4000 pods, a waypoint under 1 Mi; both below the noise of the measurement, so this is an upper bound too
- 2 → peak of the Go heap over the measured working set. The coefficients are the working set at rest, and istiod is a Go program: with `GOGC=100` its heap grows to twice the live data before a collection, so peaks up to twice the measured value are its normal course, most of all during a full push after a restart, when every proxy reconnects. istiod sets `GOMEMLIMIT` to 90% of its memory limit (`automemlimit`), so a tight limit does not fail at once but makes it collect more and more often, spending CPU at the moment of the push
- Replicas do not share the memory: the HPA scales istiod on CPU, and every replica holds the state of the whole cluster, so the limit is per replica
- 512 Mi at least, for small clusters; the upstream chart requests 2048 Mi, sized for a cluster of about 10,000 Services, pods and config objects by this formula

---

## 8. CNI Sizing Recommendation

Final Recommendation (Based on General Consensus and Benchmarks)

### CPU
```
cniCpuTotal = 0.4 
```
- (value by default) Negligible. Typically, the CNI doesn't consume much CPU directly unless network policies are complex or there’s a significant amount of pod-to-pod traffic with encryption.

### Memory
```
cniMemTotalMi =  nodeCount * 100
```
- ~100 Mi per node. This accounts for network management, routing, and metadata tracking that the CNI handles.

These figures are based on typical Kubernetes and Istio ambient mesh deployments where the network policies aren't overly complex and where the traffic is balanced. In most Istio deployments, the CNI's role is minimal compared to the load generated by the proxy (like ztunnel) and control plane (istiod), unless there's a heavy reliance on network policies.

---

**Note:**
According to Kubernetes documentation and CNI provider scaling guides, CNI can handle around 500 pods per vCPU under moderate load. This is based on Kubernetes and CNI providers like Calico, Cilium, and Flannel, where CPU utilization scales linearly with the number of pods. However, this calculation isn't used in your case due to the specific assumptions for Istio Ambient Mesh.

## 9. Results

### 9.1 Istio, cluster-wide
```
istioCpu   = ztunnelCpuTotal + istiodCpuTotal + cniCpuTotal
istioMemMi = ztunnelMemTotalMi + istiodMemTotalMi + cniMemTotalMi
```
Loads at peak: CPU at peak traffic, memory with the peak factors of sections 3 and 7; the limits of each component should cover them with the safety margin of section 13. istiod grows with the proxies of every environment through connectedProxies.

### 9.2 Proxies of one environment

The gateways and the waypoint of an environment give two things: the values of its `qubership-core-mesh-config` resource profile, a limit per pod for each proxy, and from them the total of the namespace and of all the environments of the cluster, for the capacity of the nodes. The examples of section 14 show the profile values only; the totals are the profile values times the replicas.

Resource profile:

| Profile key | Formula |
|---|---|
| `PUBLIC_GW_MEMORY_LIMIT` | `gatewayLimitMi[public-gateway]` |
| `PRIVATE_GW_MEMORY_LIMIT` | `gatewayLimitMi[private-gateway]` |
| `EGRESS_GW_MEMORY_LIMIT` | `gatewayLimitMi[egress-gateway]` |
| `WAYPOINT_MEMORY_LIMIT` | `waypointLimitMi` |

Total of the namespace:

```
envProxyMemMi    = gatewayMemPerEnvMi + waypointMemPerEnvMi
envProxyMemMaxMi = envProxyMemMi * proxyHpaMaxReplicas / proxyReplicas
envProxyCpu      = gatewayCpuPerEnv + waypointCpuPerEnv
```
- envProxyMemMi is reserved at `proxyReplicas` (the chart sets request = limit), envProxyMemMaxMi when the HPA reaches its maximum
- envProxyCpu is the load of the environment's proxies at peak: the CPU limits of the profile times the replicas, at the HPA's target utilization, have to cover each proxy's share
- The result is given per gateway and for the waypoint, as each has its own key in the profile

All the environments of the cluster together, for the capacity of the nodes:

```
clusterProxyMemMi = envs * envProxyMemMi
```
- Without the flag envs counts twice: every gateway holds the Services and endpoints of all the environments, so each gateway's limit grows with envs, and there are envs sets of gateways. Gateway memory of a shared cluster grows with the square of envs; with the flag it grows with envs only

---

## 10. Interpretation Guidelines

### When ztunnel dominates
- High request rate with small messages, and short-lived connections
- High throughput (Gbps)
- Moderate pod count
- Example: production traffic-heavy systems  

---

### When istiod dominates
- High pod count, in memory
- Many config objects

---

### When waypoints dominate
- High percentage of L7 traffic
- Many waypoint namespaces, or namespaces with many Service ports
- Heavy use of:
  - routing rules
  - auth policies
  - observability  

---

### When gateways dominate
- Many Services in the cluster, in any namespace, and `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` off
- Shared dev clusters with many environments: every environment's Services land in every gateway

---

## 11. Key Assumptions Summary

| Component | Scaling Driver | Rule of Thumb |
|----------|--------------|--------------|
| ztunnel CPU | Requests, bytes, connections per node | 0.06/1000 rps + 0.2/Gbps + 0.45/1000 new conn/s + 0.04/1000 open conns |
| ztunnel Memory | Cluster size + connections | (64 Mi + 0.008 Mi/pod + 0.004 Mi/Service of the cluster + 0.03 Mi/conn) * 1.5 |
| Envoy clusters | Service ports in scope | gateway 1.2 per Service port + 12, waypoint 1.6 per Service port + 12 |
| Envoy idle memory | Envoy clusters + endpoints | base + 0.092 Mi per cluster + 0.018 Mi per host, 1.2 hosts per endpoint and port on a gateway (gateway base 50, waypoint base 75) |
| Envoy per-cluster cost | Worker threads (CPU limit, rounded up) | 0.092 Mi at the current profiles: 1 worker per gateway, 2 per waypoint |
| Envoy traffic | Connections + requests in flight | 0.07 Mi/conn + 0.04 Mi/request in flight, or trafficReserve |
| Envoy pod limit | Idle memory + traffic | idle * 1.4 + traffic, rounded up to 32 Mi |
| gateway scope | `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` | off: all Services in the cluster, on: referenced Services; three gateways per environment |
| waypoint scope | Environment | Service ports of its namespace; one waypoint per environment |
| waypoint, gateway CPU | Requests + bytes | 0.25/1000 rps + 0.35/Gbps |
| istiod CPU | Fixed | 0.5 vCPU |
| istiod Memory | Services + pods + config + proxies | (50 Mi + 0.07/Service + 0.05/pod + 0.05/config object + 1/proxy) * 2, at least 512 Mi |

---

## 12. Calibration

The memory coefficients of Envoy, ztunnel and istiod are taken on Istio 1.30.4 with the CPU limits of the current profiles, on kind, in two runs that agreed within 10%; the ranges above are those of the two runs. A real EKS cluster then checked them: a snapshot of what it runs and a series of 2000 added Services. The CPU coefficients were measured on that cluster: fortio through a gateway, a waypoint and ztunnel, and rollout restarts for istiod. The gateway coefficients held, with the model 20–30% above what the gateways used at 2000 Services, and the istiod cost per Service matched; the ztunnel base was lowered from 150 to 64 Mi.

---

## 13. Notes

- This is a **baseline model**, not a guarantee  
- Real-world variance depends on:
  - protocol mix (HTTP vs gRPC vs TCP)
  - TLS settings
  - telemetry volume
- Always validate with load testing
- Recommended safety margin: **+30–50%** on top of every result of the model. The factors 1.5 of ztunnel, 2 of istiod and 1.4 of gateways and waypoints are not a margin but the peak of each component over its steady state, see sections 3, 4.4 and 7
- Inputs left uncounted fall back to averages of the environment: without servicePortsPerEnv the ports are portsPerService times the Services, without platformServicePorts the platform Services get the same portsPerService, and without referencedEndpoints a referenced Service gets the average pods per Service. Counted values replace them where the averages differ, for example a gateway that routes to the Services with the most replicas
- The flag cannot be used yet where a gateway's EnvoyFilter names a cluster of a Service no route points at: the annotation-referenced cluster is lost on route changes in Istio 1.30.4 ([istio/istio#62067](https://github.com/istio/istio/issues/62067), fixed upstream, in no release yet). The flag is istiod-wide, so all gateways are then sized without it

## 14. Istio Ambient Mesh Examples - Prod and Dev Profiles

> **All figures below are results of the model without the safety margin.** They include the peak factors (1.5 ztunnel, 2 istiod, 1.4 gateways and waypoints), but not the +30–50% of section 13: that margin is not built into the resource profile and is added on top when the limits are set.

### 1. Prod Profile

#### Declared inputs
- **profile** = prod
- **nodeCount** = 10
- **envs** = 1
- **platformServices** = 300, **platformPods** = 300
- **filterGatewayClusters**: both cases below; **egressGateway** = true
- **servicesPerEnv** = 400, **portsPerService** = 2
- **podsPerEnv** = 800 (2 replicas per microservice)
- **configObjectsPerEnv** = 1600
- **referencedServices** = public 240, private 160, egress 1

#### Derived Values
appPods = **800**, podsInCluster = endpointsInCluster = 800 + 300 = **1100**, servicesInCluster = 400 + 300 = **700**  
configObjectCount = 1 * 1600 = **1600**  
totalRps = 25 * 800 = **20000**, totalThroughputGbps = 12.5 * 800 / 1000 = **10**, newConnectionsPerSecond = **2000**  
connectionsPerNode = 20 * 800 / 10 = **1600**  
rpsPerNode = **4000**, newConnectionsPerNode = **400**, throughputPerNodeGbps = **2**  
referencedEndpoints = public 480, private 320, egress 2  
servicePortsPerEnv = 2 * 400 = **800**, servicePortsInCluster = 800 + 2 * 300 = **1400**, connectedProxies = 10 + 1 * 4 * 2 = **18**

#### Istio, cluster-wide

| Component | CPU | Memory |
|---|---|---|
| ztunnel | 0.06 * 4 + 0.2 * 2 + 0.45 * 0.4 + 0.04 * 1.6 ≈ 0.88 per node, **8.8 vCPU** | 64 + 0.008 * 1100 + 0.004 * 700 + 0.03 * 1600 ≈ 124 Mi used, roundUp(124 * 1.5) = 192 Mi per node, **1920 Mi** |
| istiod | **0.5 vCPU** | 50 + 0.07 * 700 + 0.05 * 1100 + 0.05 * 1600 + 18 = 252 Mi used, max(512, roundUp(252 * 2)) = **512 Mi** |
| CNI | **0.4 vCPU** | 100 * 10 = **1000 Mi** |
| **Istio total** | **9.7 vCPU** | **3432 Mi** |

#### Proxies of the environment

| Proxy | Services in scope | Envoy clusters | Hosts | Idle | Limit per pod |
|---|---|---|---|---|---|
| gateway, flag off | 700, 1400 ports | 1.2 * 1400 + 12 = 1692 | 1.2 * 2 * 1100 = 2640 | 50 + 0.092 * 1692 + 0.018 * 2640 = 253 Mi | roundUp(253 * 1.4 + 128) = **512 Mi** |
| public, flag on | 240, 480 ports | 588 | 1152 | 125 Mi | **320 Mi** |
| private, flag on | 160, 320 ports | 396 | 768 | 100 Mi | **288 Mi** |
| egress, flag on | 1, 2 ports | 14 | 5 | 51 Mi | **224 Mi** |
| waypoint | 800 ports | 1.6 * 800 + 12 = 1292 | 1.6 * 800 * 800 / 400 = 2560 | 75 + 0.092 * 1292 + 0.018 * 2560 = 240 Mi | roundUp(240 * 1.4 + 128) = **480 Mi** |

| Proxy | Limit per pod, flag off | Limit per pod, flag on | CPU at peak |
|---|---|---|---|
| public-gateway | 512 Mi | 320 Mi | 0.25 * 4 + 0.35 * 2 = 1.7 vCPU |
| private-gateway | 512 Mi | 288 Mi | 0.25 * 2 + 0.35 * 1 = 0.85 vCPU |
| egress-gateway | 512 Mi | 224 Mi | 0.25 * 0.2 + 0.35 * 0.1 ≈ 0.09 vCPU |
| waypoint | 480 Mi | 480 Mi | 0.25 * 6 + 0.35 * 3 = 2.55 vCPU |
| **environment** | | | **5.2 vCPU** |

- Public and private run at about 85% of their prod CPU limits (1 and 500m) per replica, above the HPA's 75% target, so the HPA adds replicas under this load

For reference: in a cluster with 1,713 Services the private and egress gateways were OOMKilled at startup with this profile's 250Mi. Without the flag the model gives 768Mi per gateway pod for that cluster at 1.5 ports and 2 endpoints per Service, 704Mi at 1 endpoint.

---

### 2. Dev Profile

#### Declared inputs
- **profile** = dev
- **nodeCount** = 10
- **envs** = 10
- **platformServices** = 300, **platformPods** = 300
- **filterGatewayClusters**: both cases below; **egressGateway** = true
- **servicesPerEnv** = 300, **portsPerService** = 2
- **podsPerEnv** = 300 (1 replica per microservice)
- **configObjectsPerEnv** = 1200
- **referencedServices** = public 180, private 120, egress 1

#### Derived Values
appPods = 10 * 300 = **3000**, podsInCluster = endpointsInCluster = 3000 + 300 = **3300**, servicesInCluster = 3000 + 300 = **3300**  
configObjectCount = 10 * 1200 = **12000**  
totalRps = 1 * 3000 = **3000**, totalThroughputGbps = 0.5 * 3000 / 1000 = **1.5**, newConnectionsPerSecond = **300**  
connectionsPerNode = 5 * 3000 / 10 = **1500**  
rpsPerNode = **600**, newConnectionsPerNode = **60**, throughputPerNodeGbps = **0.3**  
referencedEndpoints = public 180, private 120, egress 1, in each environment  
servicePortsPerEnv = 2 * 300 = **600**, servicePortsInCluster = 10 * 600 + 2 * 300 = **6600**, connectedProxies = 10 + 10 * 4 * 1 = **50**

#### Istio, cluster-wide

| Component | CPU | Memory |
|---|---|---|
| ztunnel | 0.06 * 0.6 + 0.2 * 0.3 + 0.45 * 0.06 + 0.04 * 1.5 ≈ 0.18 per node, **1.8 vCPU** | 64 + 0.008 * 3300 + 0.004 * 3300 + 0.03 * 1500 ≈ 149 Mi used, roundUp(149 * 1.5) = 224 Mi per node, **2240 Mi** |
| istiod | **0.5 vCPU** | 50 + 0.07 * 3300 + 0.05 * 3300 + 0.05 * 12000 + 50 = 1096 Mi used, roundUp(1096 * 2) = **2208 Mi** |
| CNI | **0.4 vCPU** | 100 * 10 = **1000 Mi** |
| **Istio total** | **2.7 vCPU** | **5448 Mi** |

#### Proxies of one environment

| Proxy | Services in scope | Envoy clusters | Hosts | Idle | Limit per pod |
|---|---|---|---|---|---|
| gateway, flag off | 3300, 6600 ports | 1.2 * 6600 + 12 = 7932 | 1.2 * 2 * 3300 = 7920 | 50 + 0.092 * 7932 + 0.018 * 7920 = 922 Mi | roundUp(922 * 1.4 + 32) = **1344 Mi** |
| public, flag on | 180, 360 ports | 444 | 432 | 99 Mi | **192 Mi** |
| private, flag on | 120, 240 ports | 300 | 288 | 83 Mi | **160 Mi** |
| egress, flag on | 1, 2 ports | 14 | 2 | 51 Mi | **128 Mi** |
| waypoint | 600 ports | 1.6 * 600 + 12 = 972 | 1.6 * 600 * 300 / 300 = 960 | 75 + 0.092 * 972 + 0.018 * 960 = 182 Mi | roundUp(182 * 1.4 + 32) = **288 Mi** |

| Proxy | Limit per pod, flag off | Limit per pod, flag on | CPU at peak |
|---|---|---|---|
| public-gateway | 1344 Mi | 192 Mi | 0.25 * 0.06 + 0.35 * 0.03 ≈ 0.026 vCPU |
| private-gateway | 1344 Mi | 160 Mi | ≈ 0.013 vCPU |
| egress-gateway | 1344 Mi | 128 Mi | ≈ 0.001 vCPU |
| waypoint | 288 Mi | 288 Mi | 0.25 * 0.09 + 0.35 * 0.045 ≈ 0.038 vCPU |
| **environment** | | | **0.08 vCPU** |

The dev profiles set 200Mi per gateway. Without the flag idle memory reaches it at about 560 Services in the cluster with 2 ports and one endpoint each, so a shared dev cluster with several environments outgrows it first: the gateways of every environment hold all 3300 Services of the cluster.

---

### Resource profile values from these examples

**Without the safety margin of section 13**: the values of the model as they are; the +30–50% is added on top of them when the profile is set.

| Profile key | Prod, flag off | Prod, flag on | Dev, flag off | Dev, flag on |
|---|---|---|---|---|
| `PUBLIC_GW_MEMORY_LIMIT` | 512Mi | 320Mi | 1344Mi | 192Mi |
| `PRIVATE_GW_MEMORY_LIMIT` | 512Mi | 288Mi | 1344Mi | 160Mi |
| `EGRESS_GW_MEMORY_LIMIT` | 512Mi | 224Mi | 1344Mi | 128Mi |
| `WAYPOINT_MEMORY_LIMIT` | 480Mi | 480Mi | 288Mi | 288Mi |

If the gateways carry an EnvoyFilter that names a cluster (section 5), the "flag on" columns wait for a release with the fix of istio/istio#62067: use the "flag off" columns until then.
