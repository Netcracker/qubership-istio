{{/*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/}}
{{- define "custom.docker.registry" -}}{{- end -}}

{{/*
  Stub definition for the kubectl image used by the Pod Security Standards hook
  and the node tuning init container. Returns empty string so that the shipped
  default is used instead. The real implementation is expected to be provided by
  a higher-level parent chart that overrides these definitions.
*/}}
{{- define "custom.kubectl.image" -}}{{- end -}}

{{/*
  Return the kubectl image shared by the PSS hook and the node tuning init
  container. Neither can run an Istio image: the ambient profile pulls distroless
  variants, which carry no shell.

  First non-empty wins: global.kubectl.image, custom.kubectl.image, the pinned
  default. The setting lives under global because the init container renders
  inside the cni and ztunnel subcharts, which see nothing else.
*/}}
{{- define "qubership.kubectl.image" -}}
{{- $set := dig "kubectl" "image" "" .Values.global -}}
{{- $set | default (include "custom.kubectl.image" .) | default "ghcr.io/netcracker/qubership-docker-kubectl:0.0.9" -}}
{{- end -}}