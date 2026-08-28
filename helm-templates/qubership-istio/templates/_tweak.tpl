{{- /*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/ -}}

{{- define "custom.docker.registry" -}}{{- end -}}

{{- /*
  Image reference for the patch-pss hook, assembled from its parts.

  Kept in one place because the digest case has to win over the tag in every
  caller, and because a private-registry installation redirects
  patchPss.image.registry alone - the repository and the tag stay as shipped.
*/ -}}
{{- define "qubership-istio.patchPss.image" -}}
{{- $image := .Values.patchPss.image -}}
{{- $ref := $image.repository -}}
{{- if $image.registry -}}
{{- $ref = printf "%s/%s" $image.registry $image.repository -}}
{{- end -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $ref $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref $image.tag -}}
{{- end -}}
{{- end -}}
