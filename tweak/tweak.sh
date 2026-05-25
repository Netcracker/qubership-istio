# injects tweak templates into subchart packages
# to allow custom image overrides in the parent chart
# zzzz prefix in name is used to ensure the tweak template is loaded last
# even after istio zzz_profile.yaml is processed
CHARTS_DIR=./helm-templates/qubership-istio/charts
for chart in cni istiod ztunnel; do
TGZ=$(ls ${CHARTS_DIR}/${chart}-*.tgz)
tar -xzf "${TGZ}" -C "${CHARTS_DIR}"
cp tweak/zzzz_tweak.yaml "${CHARTS_DIR}/${chart}/templates/"
tar -czf "${TGZ}" -C "${CHARTS_DIR}" "${chart}"
rm -rf "${CHARTS_DIR}/${chart}"
done