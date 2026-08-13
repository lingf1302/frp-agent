#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="frp-agent"
INSTALL_DIR="/usr/local/lib/frp-agent"
CONFIG_DIR="/etc/frp-agent"
CONFIG_FILE="${CONFIG_DIR}/frpc.toml"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG=""
SERVER_ADDR=""
SERVER_PORT="7000"
AUTH_TOKEN=""
REPLACE_CONFIG=false

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]
  --config FILE          Use an existing frpc.toml file.
  --server-addr ADDRESS  Generate configuration for frps.
  --server-port PORT     frps port (default: 7000).
  --token TOKEN          Token for generated configuration.
  --replace-config       Replace an existing configuration.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) SOURCE_CONFIG="$2"; shift 2 ;;
    --server-addr) SERVER_ADDR="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --token) AUTH_TOKEN="$2"; shift 2 ;;
    --replace-config) REPLACE_CONFIG=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $(id -u) -eq 0 ]] || { echo "Run this installer as root." >&2; exit 1; }
[[ $(uname -s) == "Linux" ]] || { echo "This offline installer supports Linux only." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required." >&2; exit 1; }
[[ -x "${PACKAGE_DIR}/frpc" ]] || { echo "frpc is missing." >&2; exit 1; }
[[ -f "${PACKAGE_DIR}/frpc.toml.example" ]] || { echo "Configuration template is missing." >&2; exit 1; }
[[ -z "${SOURCE_CONFIG}" || -f "${SOURCE_CONFIG}" ]] || { echo "Configuration file not found: ${SOURCE_CONFIG}" >&2; exit 1; }
[[ -z "${SOURCE_CONFIG}" || -z "${SERVER_ADDR}" ]] || { echo "Use --config or --server-addr, not both." >&2; exit 2; }
[[ -z "${AUTH_TOKEN}" || -n "${SERVER_ADDR}" ]] || { echo "--server-addr is required with --token." >&2; exit 2; }
[[ "${SERVER_PORT}" =~ ^[0-9]{1,5}$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || { echo "Invalid --server-port." >&2; exit 2; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT HUP INT TERM
candidate_config=""
if [[ -n "${SOURCE_CONFIG}" ]]; then
  candidate_config="${tmp_dir}/frpc.toml"
  cp "${SOURCE_CONFIG}" "${candidate_config}"
elif [[ -n "${SERVER_ADDR}" ]]; then
  candidate_config="${tmp_dir}/frpc.toml"
  {
    printf 'serverAddr = "%s"\n' "${SERVER_ADDR}"
    printf 'serverPort = %s\n' "${SERVER_PORT}"
    if [[ -n "${AUTH_TOKEN}" ]]; then
      printf 'auth.method = "token"\n'
      printf 'auth.token = "%s"\n' "${AUTH_TOKEN}"
    fi
  } >"${candidate_config}"
fi
if [[ -n "${candidate_config}" ]]; then
  "${PACKAGE_DIR}/frpc" verify -c "${candidate_config}"
fi

mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
was_enabled=false
if systemctl is-enabled --quiet "${SERVICE_NAME}.service"; then
  was_enabled=true
fi
systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
install -m 0755 "${PACKAGE_DIR}/frpc" "${INSTALL_DIR}/frpc"
if [[ -n "${candidate_config}" ]]; then
  if [[ -f "${CONFIG_FILE}" && "${REPLACE_CONFIG}" != true ]]; then
    echo "Existing config preserved; use --replace-config to replace it."
  else
    install -m 0600 "${candidate_config}" "${CONFIG_FILE}"
  fi
elif [[ ! -f "${CONFIG_FILE}" ]]; then
  install -m 0600 "${PACKAGE_DIR}/frpc.toml.example" "${CONFIG_FILE}"
  echo "Created configuration template: ${CONFIG_FILE}"
fi

cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=FRP managed client agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_FILE}
Restart=always
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if [[ -n "${candidate_config}" || "${was_enabled}" == true ]]; then
  "${INSTALL_DIR}/frpc" verify -c "${CONFIG_FILE}"
  systemctl enable --now "${SERVICE_NAME}.service"
  echo "frp-agent is installed, enabled, and running."
else
  echo "frp-agent service is installed but not started. Edit ${CONFIG_FILE}, then run:"
  echo "  sudo systemctl enable --now ${SERVICE_NAME}.service"
fi
