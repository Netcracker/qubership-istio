{{/*
  The init container that raises the node's inotify limits before the @CHART@ agent
  starts. Injected into the DaemonSet by daemonset.yaml, which passes the image, the
  pull policy and the two targets in a dict.
*/}}
{{- define "qubership.@CHART@-node-inotify" -}}
name: node-inotify-tuning
image: {{ .image }}
{{- with .pullPolicy }}
imagePullPolicy: {{ . }}
{{- end }}
command:
- /bin/sh
- -c
- |
  # Raise a limit only when it is below the target, so a node tuned higher is left alone.
  for pair in max_user_instances:{{ .instances }} max_user_watches:{{ .watches }}; do
    file=/host-inotify/${pair%%:*}
    want=${pair##*:}
    cur=$(cat "$file")
    if [ "$cur" -lt "$want" ]; then
      echo "$want" > "$file"
      echo "$file: $cur -> $want"
    else
      echo "$file: $cur, kept"
    fi
  done
  # Never fail the pod: istio-cni-node rolls without surge, so a failing init container would
  # leave the node with no CNI at all.
  exit 0
securityContext:
  # Root is the only privilege needed: the sysctl files are root:root 0644.
  runAsUser: 0
  privileged: false
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
volumeMounts:
- name: node-inotify
  mountPath: /host-inotify
{{- end -}}
