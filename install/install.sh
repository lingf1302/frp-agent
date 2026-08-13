#!/bin/sh
set -eu

DEFAULT_BASE_URL='@@PUBLIC_BASE_URL@@'
BASE_URL="${FRP_AGENT_BASE_URL:-$DEFAULT_BASE_URL}"
CONFIG_URL="${FRP_AGENT_CONFIG_URL:-}"
CONFIG_FILE=""
INSTALL_DIR="/usr/local/lib/frp-agent"
CONFIG_DIR="/etc/frp-agent"

usage() {
  echo "Usage: install.sh [--base-url URL] [--config-url HTTPS_URL | --config FILE]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --config-url) CONFIG_URL="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root (for example: curl ... | sudo sh)." >&2
  exit 1
fi
if [ "$BASE_URL" = 'https://github.com/OWNER/REPO/releases/latest/download' ]; then
  echo "Set --base-url to the public release download URL." >&2
  exit 1
fi
case "$BASE_URL" in https://*) ;; *) echo "The package base URL must use HTTPS." >&2; exit 1 ;; esac

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "Unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "Unsupported CPU architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ -n "$CONFIG_URL" ]; then
  case "$CONFIG_URL" in https://*) ;; *) echo "The configuration URL must use HTTPS." >&2; exit 1 ;; esac
fi
if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file not found: $CONFIG_FILE" >&2
  exit 1
fi
if [ -z "$CONFIG_URL" ] && [ -z "$CONFIG_FILE" ] && [ ! -f "$CONFIG_DIR/frpc.toml" ]; then
  echo "First install requires --config FILE or --config-url HTTPS_URL." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
asset="frp-agent_${os}_${arch}.tar.gz"

download() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output"
  else
    echo "curl or wget is required." >&2
    exit 1
  fi
}

download "${BASE_URL}/${asset}" "${tmp_dir}/${asset}"
download "${BASE_URL}/checksums.txt" "${tmp_dir}/checksums.txt"
expected="$(awk -v file="$asset" '$2 == file || $2 == "*" file { print $1 }' "${tmp_dir}/checksums.txt")"
[ -n "$expected" ] || { echo "No checksum found for ${asset}." >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${tmp_dir}/${asset}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${tmp_dir}/${asset}" | awk '{print $1}')"
fi
[ "$actual" = "$expected" ] || { echo "Checksum verification failed for ${asset}." >&2; exit 1; }

mkdir -p "${tmp_dir}/package"
tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}/package"
"${tmp_dir}/package/frpc" --version >/dev/null

candidate_config="$CONFIG_DIR/frpc.toml"
if [ -n "$CONFIG_URL" ]; then
  download "$CONFIG_URL" "${tmp_dir}/frpc.toml"
  candidate_config="${tmp_dir}/frpc.toml"
elif [ -n "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "${tmp_dir}/frpc.toml"
  candidate_config="${tmp_dir}/frpc.toml"
fi
"${tmp_dir}/package/frpc" verify -c "$candidate_config"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
if [ "$os" = linux ] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop frp-agent.service >/dev/null 2>&1 || true
elif [ "$os" = darwin ]; then
  launchctl bootout system/io.frp.agent >/dev/null 2>&1 || true
fi
install -m 0755 "${tmp_dir}/package/frpc" "$INSTALL_DIR/frpc"

if [ -n "$CONFIG_URL" ] || [ -n "$CONFIG_FILE" ]; then
  install -m 0600 "${tmp_dir}/frpc.toml" "$CONFIG_DIR/frpc.toml"
fi

if [ "$os" = linux ]; then
  command -v systemctl >/dev/null 2>&1 || { echo "systemd is required on Linux." >&2; exit 1; }
  cat > /etc/systemd/system/frp-agent.service <<EOF
[Unit]
Description=FRP managed client agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml
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
  systemctl enable --now frp-agent.service
  systemctl --no-pager --full status frp-agent.service || true
else
  cat > /Library/LaunchDaemons/io.frp.agent.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.frp.agent</string>
  <key>ProgramArguments</key><array><string>${INSTALL_DIR}/frpc</string><string>-c</string><string>${CONFIG_DIR}/frpc.toml</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/frp-agent.log</string>
  <key>StandardErrorPath</key><string>/var/log/frp-agent.log</string>
</dict></plist>
EOF
  chmod 0644 /Library/LaunchDaemons/io.frp.agent.plist
  chown root:wheel /Library/LaunchDaemons/io.frp.agent.plist
  launchctl bootstrap system /Library/LaunchDaemons/io.frp.agent.plist
  launchctl enable system/io.frp.agent
  launchctl kickstart -k system/io.frp.agent
fi

echo "frp-agent installed and started (${os}/${arch})."
