{{/*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/}}
{{- define "custom.docker.registry" -}}{{- end -}}

{{/*
  Stub definition for the registry the kubectl image is pulled from, used by the
  Pod Security Standards hook and the node tuning init container. Returns empty
  string so that the shipped registry is used instead. The real implementation is
  expected to be provided by a higher-level parent chart that overrides these
  definitions.
*/}}
{{- define "custom.kubectl.registry" -}}{{- end -}}

{{/*
  Return the kubectl image shared by the Pod Security Standards hook and the node
  tuning init container. Neither can run an Istio image: the ambient profile pulls
  distroless variants, which carry no shell.

  Composed from its parts, so redirecting the registry alone leaves the repository
  and the tag as shipped, and a chart upgrade still moves the version. The registry
  is global.kubectl.registry, then custom.kubectl.registry, then the shipped one. A
  digest replaces the tag, and global.kubectl.image replaces the whole reference.
*/}}
{{- define "qubership.kubectl.image" -}}
{{- $k := dig "kubectl" dict .Values.global -}}
{{- if $k.image -}}
{{- $k.image -}}
{{- else -}}
{{- $registry := $k.registry | default (include "custom.kubectl.registry" .) | default "ghcr.io" -}}
{{- $ref := printf "%s/%s" $registry $k.repository -}}
{{- if $k.digest -}}{{- printf "%s@%s" $ref $k.digest -}}{{- else -}}{{- printf "%s:%s" $ref $k.tag -}}{{- end -}}
{{- end -}}
{{- end -}}
