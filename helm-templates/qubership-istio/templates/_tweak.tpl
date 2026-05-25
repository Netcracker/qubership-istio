{{- /*
  Stub definition for custom docker registry used by subchart tweak files.
  Returns empty string so that standalone helm template / helm lint passes
  without errors. The real implementation is expected to be provided by a
  higher-level parent chart that overrides these definitions.
*/ -}}

{{- define "custom.docker.registry" -}}{{- end -}}