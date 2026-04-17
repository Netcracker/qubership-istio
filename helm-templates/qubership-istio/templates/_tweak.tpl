{{- /*
  Stub definitions for the custom image templates used by subchart tweak files.
  These return empty strings so that standalone helm template / helm lint passes
  without errors. The real implementations are expected to be provided by a
  higher-level parent chart that overrides these definitions at deploy time.
*/ -}}

{{- define "custom.cni.image" -}}{{- end -}}

{{- define "custom.istiod.image" -}}{{- end -}}

{{- define "custom.ztunnel.image" -}}{{- end -}}
