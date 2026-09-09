{{- /*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/ -}}

{{- define "custom.docker.registry" -}}{{- end -}}

{{- /*
  Image override point for the kubectl helpers, empty on purpose.

  Same contract as custom.docker.registry above, and here it returns a whole
  reference rather than a registry: an installation may carry the image under a
  different name, not only in a different place. Consulted only when
  global.kubectl.image is empty, so an explicitly configured image always wins.
*/ -}}
{{- define "custom.kubectl.image" -}}{{- end -}}

{{- /*
  The kubectl image, resolved once for both of its callers.

  Those callers are the Pod Security Standards patch hook and the node tuning
  init container. They run the same image for the same reason - each needs a
  shell, and the Istio images do not carry one - so the reference lives in one
  place and an installation redirects it once instead of twice.

  Order, first non-empty wins: global.kubectl.image, then whatever
  custom.kubectl.image returns, then the reference shipped with this chart.

  It reads .Values.global and nothing else. The node tuning init container is
  injected into the cni and ztunnel subcharts, and a subchart sees its own values
  plus global, so a setting anywhere else would be invisible from there.

  The shipped tag is a released one on purpose. A floating tag with
  imagePullPolicy: IfNotPresent leaves a node on whatever it happened to pull
  first, and different nodes then run different versions.
*/ -}}
{{- define "qubership-istio.kubectl.image" -}}
{{- $set := dig "kubectl" "image" "" (.Values.global | default dict) -}}
{{- $set | default (include "custom.kubectl.image" .) | default "ghcr.io/netcracker/qubership-docker-kubectl:0.0.9" -}}
{{- end -}}
