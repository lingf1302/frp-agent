#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist/agent}"
VERSION="${VERSION:-$(sed -n 's/^var version = "\([^"]*\)"/\1/p' "${ROOT_DIR}/pkg/util/version/version.go")}" 
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://github.com/OWNER/REPO/releases/latest/download}"
LDFLAGS="-s -w"

cd "${ROOT_DIR}"

if [[ -z "${VERSION}" ]]; then
  echo "Unable to determine the frp version" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
DIST_DIR="$(cd "${DIST_DIR}" && pwd)"
rm -f "${DIST_DIR}"/frp-agent_*.zip "${DIST_DIR}"/frp-agent_*.tar.gz \
  "${DIST_DIR}/checksums.txt" "${DIST_DIR}/install.sh" "${DIST_DIR}/install.ps1"

targets=(
  "linux amd64"
  "linux arm64"
  "darwin amd64"
  "darwin arm64"
  "windows amd64"
  "windows arm64"
)

for target in "${targets[@]}"; do
  read -r os arch <<<"${target}"
  package_name="frp-agent_${os}_${arch}"
  stage="$(mktemp -d "${FRP_AGENT_TMPDIR:-${TMPDIR:-/tmp}}/frp-agent.XXXXXX")"

  binary="frpc"
  [[ "${os}" == "windows" ]] && binary="frpc.exe"
  echo "Building ${package_name}"
  CGO_ENABLED=0 GOOS="${os}" GOARCH="${arch}" go build -trimpath -ldflags "${LDFLAGS}" -tags "frpc,noweb" -o "${stage}/${binary}" ./cmd/frpc

  if [[ "${os}" == "windows" ]]; then
    CGO_ENABLED=0 GOOS="${os}" GOARCH="${arch}" go build -trimpath -ldflags "${LDFLAGS}" -o "${stage}/frpc-service.exe" ./cmd/frpc-service
  fi

  cp "${ROOT_DIR}/LICENSE" "${stage}/LICENSE"
  printf '%s\n' "${VERSION}" >"${stage}/VERSION"

  if [[ "${os}" == "linux" ]]; then
    cp "${ROOT_DIR}/install/linux-offline-install.sh" "${stage}/install.sh"
    cp "${ROOT_DIR}/install/frpc.toml.example" "${stage}/frpc.toml.example"
    chmod 0755 "${stage}/install.sh"
  fi

  if [[ "${os}" == "windows" ]]; then
    (cd "${stage}" && zip -q -9 -r "${DIST_DIR}/${package_name}.zip" .)
  else
    tar -C "${stage}" -czf "${DIST_DIR}/${package_name}.tar.gz" .
  fi
  rm -rf "${stage}"
done

sed "s|@@PUBLIC_BASE_URL@@|${PUBLIC_BASE_URL}|g" "${ROOT_DIR}/install/install.sh" >"${DIST_DIR}/install.sh"
sed "s|@@PUBLIC_BASE_URL@@|${PUBLIC_BASE_URL}|g" "${ROOT_DIR}/install/install.ps1" >"${DIST_DIR}/install.ps1"
chmod +x "${DIST_DIR}/install.sh"

(
  cd "${DIST_DIR}"
  sha256sum frp-agent_* >checksums.txt
)

echo "Agent ${VERSION} packages written to ${DIST_DIR}"
