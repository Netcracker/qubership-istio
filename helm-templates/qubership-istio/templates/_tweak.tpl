{{- /*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/ -}}

{{- define "custom.docker.registry" -}}{{- end -}}

{{- /*
  Registry override point for the patch-pss image, empty on purpose.

  Same contract as custom.docker.registry above: a parent chart that knows
  where this installation's images actually live redefines it. Used only when
  patchPss.image.registry is empty, so an explicitly configured registry always
  wins over whatever the parent computes.
*/ -}}
{{- define "custom.patchPss.registry" -}}{{- end -}}

{{- /*
  Image reference for the patch-pss hook, assembled from its parts.

  Kept in one place because the digest case has to win over the tag in every
  caller, and because a private-registry installation redirects the registry
  alone - the repository and the tag stay as shipped.

  Registry precedence: patchPss.image.registry, then whatever a parent chart
  returns from custom.patchPss.registry, then none at all - which leaves the
  repository unqualified for the container runtime to resolve.
*/ -}}
{{- define "qubership-istio.patchPss.image" -}}
{{- $image := .Values.patchPss.image -}}
{{- $registry := $image.registry | default (include "custom.patchPss.registry" .) -}}
{{- $ref := $image.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $image.repository -}}
{{- end -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $ref $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref $image.tag -}}
{{- end -}}
{{- end -}}
