{{/*
  Return "true" when the Pod Security Standards hook runs, empty otherwise.

  The hook is skipped on the openshift platform whatever ENABLE_PRIVILEGED_PSS says.
  OpenShift admits the agents by SecurityContextConstraints, which the cni and ztunnel
  charts grant, so the namespace label decides nothing there. The hook Job runs as UID 1001,
  outside the UID range OpenShift assigns to the namespace, and would never be admitted.

  The upstream charts take the platform from global.platform or from their own platform
  value, so it counts here when it is set globally or on any of istiod, cni, and ztunnel.
*/}}
{{- define "qubership.patchPss.enabled" -}}
{{- $openshift := false -}}
{{- range $values := list .Values.global .Values.istiod .Values.cni .Values.ztunnel -}}
{{- if eq (dig "platform" "" ($values | default dict) | toString) "openshift" -}}
{{- $openshift = true -}}
{{- end -}}
{{- end -}}
{{- if and .Values.ENABLE_PRIVILEGED_PSS (not $openshift) -}}true{{- end -}}
{{- end -}}
