# injects tweak templates into subchart packages
# to allow custom image overrides in the parent chart
# zzzz prefix in name is used to ensure the tweak template is loaded last
# even after istio zzz_profile.yaml is processed
set -euo pipefail
CHARTS_DIR=./helm-templates/qubership-istio/charts
for chart in cni istiod ztunnel; do
TGZ=$(ls ${CHARTS_DIR}/${chart}-*.tgz)
tar -xzf "${TGZ}" -C "${CHARTS_DIR}"
cp tweak/zzzz_tweak.yaml "${CHARTS_DIR}/${chart}/templates/"
if [ "${chart}" = "istiod" ]; then
  TPL_DIR="${CHARTS_DIR}/${chart}/templates"
  {
    echo '{{- define "qubership.istiod-clusterrole-upstream" -}}'
    cat "${TPL_DIR}/clusterrole.yaml"
    echo '{{- end -}}'
  } > "${TPL_DIR}/_clusterrole-upstream.tpl"
  rm "${TPL_DIR}/clusterrole.yaml"

  cp tweak/istiod-clusterrole.yaml "${TPL_DIR}/clusterrole.yaml"
fi
tar -czf "${TGZ}" -C "${CHARTS_DIR}" "${chart}"
rm -rf "${CHARTS_DIR}/${chart}"
done
