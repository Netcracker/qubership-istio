{{/*
  Return "true" when the Pod Security Standards hook runs, empty otherwise.

  The hook is skipped on the openshift platform whatever ENABLE_PRIVILEGED_PSS says.
  OpenShift admits the agents by SecurityContextConstraints, which the cni and ztunnel
  charts grant, so the namespace label decides nothing there. The hook Job runs as UID 1001,
  outside the UID range OpenShift assigns to the namespace, and would never be admitted.
*/}}
{{- define "qubership.patchPss.enabled" -}}
{{- $platform := dig "platform" "" (.Values.global | default dict) | default "" -}}
{{- if and .Values.ENABLE_PRIVILEGED_PSS (ne $platform "openshift") -}}true{{- end -}}
{{- end -}}
