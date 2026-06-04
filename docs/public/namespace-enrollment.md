<!-- TOC -->
- [Namespace Enrollment into Istio Ambient Mesh](#namespace-enrollment-into-istio-ambient-mesh)
  - [Creating New Namespace](#creating-new-namespace)
  - [Existing Namespace Enrollment](#existing-namespace-enrollment)
<!-- /TOC -->

# Namespace Enrollment into Istio Ambient Mesh

## Creating New Namespace

When creating new namespace that should be enrolled into Istio Ambient Mesh, specify the following labels on the namespace:

* `istio.io/dataplane-mode`: `ambient`
* `istio.io/use-waypoint`: `waypoint`

## Existing Namespace Enrollment

In order to enroll existing namespace into Istio Ambient Mesh follow the steps below:

1. Add these two labels to namespace:
   * `istio.io/dataplane-mode`: `ambient`
   * `istio.io/use-waypoint`: `waypoint`
2. Restart all workloads in namespace.
