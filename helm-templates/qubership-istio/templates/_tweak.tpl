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
