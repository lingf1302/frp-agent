# FRP 代理跨平台打包与一键安装

该流程把 `frpc` 编译为 Windows、Linux、macOS 的 amd64/arm64 包。安装器自动识别系统和 CPU，校验 SHA-256，验证配置，然后注册为开机自启服务。

## 发布公网安装包

目标 GitHub 仓库需为公网仓库。在当前提交创建 `agent-v` 开头的 tag：

```bash
git tag agent-v0.71.0-1
git push origin agent-v0.71.0-1
```

`.github/workflows/agent-release.yml` 会创建 GitHub Release，也可在 Actions 手动运行并输入上述格式的 tag。Release 包含六个平台归档、`checksums.txt`、`install.sh` 和 `install.ps1`。

在 Linux、macOS 或 WSL 本地构建：

```bash
PUBLIC_BASE_URL=https://downloads.example.com/frp-agent make agent-packages
```

将 `dist/agent/` 全部文件原样上传到该 HTTPS 地址。

## 客户端配置

首次安装必须提供有效的 `frpc.toml`。配置通常包含认证令牌，不应放入公开 Release。可通过受保护的 HTTPS 配置接口下发，或先安全地写入目标机器。

```toml
serverAddr = "frps.example.com"
serverPort = 7000
auth.method = "token"
auth.token = "replace-with-a-secret"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
```

配置 URL 可用短时签名 URL，但 URL 可能进入 shell 历史或代理日志。生产环境应限制有效期、使用次数和来源。

## Linux 离线安装包

Linux 的 `frp-agent_linux_amd64.tar.gz` 和 `frp-agent_linux_arm64.tar.gz` 是离线包，内含 `frpc`、`install.sh` 与 `frpc.toml.example`，无需联网下载代理程序。

将匹配 CPU 架构的压缩包复制到目标 Linux 机器后执行：

```bash
mkdir frp-agent && tar -xzf frp-agent_linux_amd64.tar.gz -C frp-agent
cd frp-agent
sudo ./install.sh --config /secure/path/frpc.toml
```

也可在安装时生成基础配置、注册 systemd 服务并立即启动：

```bash
sudo ./install.sh --server-addr frps.example.com --server-port 7000 --token 'your-secret'
```

首次不带参数执行会将模板写入 `/etc/frp-agent/frpc.toml`，注册服务但不启动。填写配置后启动：

```bash
sudo systemctl enable --now frp-agent.service
```

## 一键安装

把示例中的仓库和 tag 换成实际发布地址。

Linux 或 macOS：

```bash
curl -fsSL https://github.com/OWNER/REPO/releases/download/agent-v0.71.0-1/install.sh \
  | sudo sh -s -- --config-url 'https://config.example.com/clients/node-001.toml?signature=...'
```

本地配置文件方式：

```bash
curl -fsSL https://github.com/OWNER/REPO/releases/download/agent-v0.71.0-1/install.sh -o /tmp/install-frp-agent.sh
sudo sh /tmp/install-frp-agent.sh --config /secure/path/frpc.toml
```

Windows 管理员 PowerShell：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://github.com/OWNER/REPO/releases/download/agent-v0.71.0-1/install.ps1'))) `
  -ConfigUrl 'https://config.example.com/clients/node-001.toml?signature=...'
```

或者传本地文件：

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://github.com/OWNER/REPO/releases/download/agent-v0.71.0-1/install.ps1'))) `
  -ConfigFile 'C:\secure\frpc.toml'
```

## Windows MSI 安装包

Windows MSI 安装器会安装到 `C:\Program Files\frp-agent`，首次创建 `frpc.toml` 配置模板并注册 `frp-agent` 服务；升级时不会覆盖已经修改的配置文件。服务在配置有效前保持手动启动，避免空模板导致反复启动失败。

管理员 PowerShell 静默安装：

```powershell
msiexec /i frp-agent_windows_amd64.msi /qn /norestart
```

MSI 会由 `agent-release` 工作流的 Windows Runner 自动生成，并随 GitHub Release 上传，名称为 `frp-agent_windows_amd64.msi` 与 `frp-agent_windows_arm64.msi`。当前本地 Windows 环境如未安装 WiX，可直接使用 ZIP 与 `install.ps1`，或将源码推送并通过 Release 获取 MSI。

一条命令生成配置、校验配置、设置开机自启并启动服务：

```powershell
& "$env:ProgramFiles\frp-agent\configure.ps1" -ServerAddr 'frps.example.com' -ServerPort 7000 -Token 'your-secret' -Start
Get-Service frp-agent
```

重复运行会升级二进制并保留已有配置；只有传入配置参数才替换配置。每次安装都会执行 `frpc verify`。

## 服务管理

Linux 使用 systemd：`systemctl status frp-agent`、`journalctl -u frp-agent -f`。

macOS 使用 launchd：`sudo launchctl print system/io.frp.agent`，日志为 `/var/log/frp-agent.log`。

Windows 使用 SCM：`Get-Service frp-agent`、`Restart-Service frp-agent`，日志为 `%ProgramFiles%\frp-agent\frpc.log`。

安装位置为 `/usr/local/lib/frp-agent` 与 `/etc/frp-agent`（Linux/macOS），或 `%ProgramFiles%\frp-agent`（Windows）。三类服务均启用失败重启和开机启动。

发布后应在六种目标环境至少验证安装、开机重启、断网恢复、无效配置和重复升级。公网地址可先检查：

```bash
curl -fLO https://github.com/OWNER/REPO/releases/download/agent-v0.71.0-1/checksums.txt
```
