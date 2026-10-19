{{/*
Deployment overlay for a gateway or waypoint, referenced by its Gateway
through infrastructure.parametersRef, the way qubership-core-mesh-config sets
the resources of its proxies. Istio sets the Envoy workers to the CPU limit,
rounded up.
Arguments: dict "name" "namespace" "cpuLimit" "memoryLimit".
*/}}
{{- define "fixtures.proxyOptions" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}-options
  namespace: {{ .namespace }}
data:
  deployment: |
    spec:
      template:
        spec:
          containers:
          - name: istio-proxy
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
              limits:
                cpu: {{ .cpuLimit | quote }}
                memory: {{ .memoryLimit | quote }}
{{- end -}}
