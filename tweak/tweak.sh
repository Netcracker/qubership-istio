# injects tweak templates into subchart packages
# to allow custom image overrides in the parent chart
# zzzz prefix in name is used to ensure the tweak template is loaded last
# even after istio zzz_profile.yaml is processed
set -euo pipefail
CHARTS_DIR=./helm-templates/qubership-istio/charts

# 1. Unpack all subcharts.
for chart in cni istiod ztunnel; do
  tar -xzf "$(ls ${CHARTS_DIR}/${chart}-*.tgz)" -C "${CHARTS_DIR}"
done

# 2. Apply tweaks.
# Common: inject the image-override template into every subchart.
for chart in cni istiod ztunnel; do
  cp tweak/zzzz_tweak.yaml "${CHARTS_DIR}/${chart}/templates/"
done

# istiod: subtract the broad webhook rules (wrap upstream ClusterRole as a partial,
# swap in our transform) and add the narrowed istiod-webhook-rbac.yaml.
TPL_DIR="${CHARTS_DIR}/istiod/templates"
{
  echo '{{- define "qubership.istiod-clusterrole-upstream" -}}'
  cat "${TPL_DIR}/clusterrole.yaml"
  echo '{{- end -}}'
} > "${TPL_DIR}/_clusterrole-upstream.tpl"
rm "${TPL_DIR}/clusterrole.yaml"
cp tweak/istiod-clusterrole.yaml "${TPL_DIR}/clusterrole.yaml"
cp tweak/istiod-webhook-rbac.yaml "${TPL_DIR}/"

# 3. Repack all subcharts.
for chart in cni istiod ztunnel; do
  tar -czf "$(ls ${CHARTS_DIR}/${chart}-*.tgz)" -C "${CHARTS_DIR}" "${chart}"
  rm -rf "${CHARTS_DIR}/${chart}"
done
