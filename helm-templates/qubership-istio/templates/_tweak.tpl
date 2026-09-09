{{- /*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/ -}}

{{- define "custom.docker.registry" -}}{{- end -}}

{{- /*
  Override point for the kubectl image, empty on purpose. Same contract as
  custom.docker.registry above, and it returns a whole reference: an installation
  may carry the image under a different name, not only in a different place.
*/ -}}
{{- define "custom.kubectl.image" -}}{{- end -}}

{{- /*
  The kubectl image, resolved once for both of its callers: the Pod Security
  Standards hook and the node tuning init container. Each needs a shell, which the
  Istio images do not carry.

  First non-empty wins: global.kubectl.image, then custom.kubectl.image, then the
  reference below. It reads .Values.global and nothing else, because the init
  container is injected into the cni and ztunnel subcharts, and a subchart sees only
  its own values plus global.

  The tag is a released one: a floating tag lets nodes drift onto different versions.
*/ -}}
{{- define "qubership.kubectl.image" -}}
{{- $set := dig "kubectl" "image" "" (.Values.global | default dict) -}}
{{- $set | default (include "custom.kubectl.image" .) | default "ghcr.io/netcracker/qubership-docker-kubectl:0.0.9" -}}
{{- end -}}
