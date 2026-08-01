# 安装、升级与回滚

推荐通过 GitHub Release 安装固定构建产物。安装器会校验 SHA256、Sigstore 签名身份、包内路径与版本，再切换统一命令 `devops-toolkit`。

## 快速安装

新 Ubuntu 或 WSL 已经以 root 登录时：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)"
```

root 模式会在 Ubuntu/WSL 上通过 apt 补齐白名单依赖，然后安装到：

- 版本：`/opt/devops-toolkit/releases/<version>`
- 当前版本：`/opt/devops-toolkit/current`
- 命令：`/usr/local/bin/devops-toolkit`

在交互终端执行上述命令时，安装完成后会直接启动向导。新服务器选择 `Ubuntu` → `当前服务器本地执行`。

普通用户执行同一命令时不会使用 sudo，安装位置为：

- 版本：`~/.local/share/devops-toolkit/releases/<version>`
- 当前版本：`~/.local/share/devops-toolkit/current`
- 命令：`~/.local/bin/devops-toolkit`

如果 `~/.local/bin` 不在 PATH：

```bash
printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.profile"
export PATH="$HOME/.local/bin:$PATH"
```

普通用户安装绝不提权。缺少 Python、Ansible、Git、curl 或 OpenSSL 时，安装器会停止，并给出需要管理员安装的依赖。
系统模式要求 `ansible-core >= 2.12`；Ubuntu 22.04 的 apt 版本只有 2.10，安装器会安装
`python3-pip`，再固定到兼容范围 `ansible-core>=2.12,<2.19` 并复核版本。Ubuntu 24.04
若触发系统 pip 保护，则只在该受控 bootstrap 步骤使用 `--break-system-packages`。

## 安装器验证顺序

安装器不会下载完成后立即解压到正式目录，而是按以下顺序处理：

1. 下载压缩包、SHA256 文件和 Sigstore bundle。
2. 验证压缩包 SHA256。
3. 在权限为 `0700` 的临时目录中检查 tar 路径并解包。
4. 核对包内 `VERSION` 与请求的版本。
5. 下载或复用固定版本 Cosign，并用安装器内置 SHA256 校验 Cosign 本身。
6. 验证 Release 的 OIDC issuer、仓库、workflow、tag ref 和触发事件。
7. 校验并启用签名包内的固定版本 Ansible collections；全部成功后才原子切换 `current`。历史 Release
   不含内置 collections 时才显式回退到 Ansible Galaxy 兼容安装。

任何一步失败，当前已安装版本都不会切换。Cosign 验证需要访问 Sigstore 信任根和透明日志服务；受限网络应显式放行，不要通过删除验证逻辑绕过。

## 固定版本和安装选项

生产环境推荐固定版本：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --version v0.1.4
```

也可以通过环境变量指定：

```bash
DEVOPS_TOOLKIT_VERSION=v0.1.4 \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)"
```

只安装、不启动向导：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --no-run
```

显式选择安装范围：

```bash
# root 也安装到自己的 ~/.local；不修改 /opt 和 /usr/local/bin
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --user

# 必须以 root 执行
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --system
```

`curl | bash` 的标准输入是管道，不会自动启动交互向导；因此文档统一使用 `bash -c "$(curl ...)"`。CI 中建议追加 `--no-run`。

## 升级

重新执行安装命令即可升级到 latest。安装器会保留旧版本目录；重复安装相同版本会复用已验证文件，并确保
该版本的 Ansible collections 已就绪。

升级到指定版本：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --version v0.2.0 --no-run
devops-toolkit --version
```

同一版本号对应的 Release 资产被替换时，安装器会因 SHA256 变化而拒绝覆盖。这是有意的：发布后的版本应视为不可变。

安装器会缓存经过内置 SHA256 校验的 Cosign 二进制，升级时重新核对后复用：

- root：`/opt/devops-toolkit/tools/`
- 普通用户：`~/.local/share/devops-toolkit/tools/`

## 手工回滚

先确认旧版本可执行，再原子替换 `current`。root 安装示例：

```bash
test -x /opt/devops-toolkit/releases/v0.1.4/bin/devops-toolkit
python3 - <<'PY'
import os
from pathlib import Path

base = Path("/opt/devops-toolkit")
temporary = base / ".current.rollback"
temporary.unlink(missing_ok=True)
temporary.symlink_to("releases/v0.1.4")
os.replace(temporary, base / "current")
PY
devops-toolkit --version
```

普通用户把 `base` 改为 `Path.home() / ".local/share/devops-toolkit"`。回滚只切换链接，不删除任何版本。

## 从源码运行

CI、批量配置或需要审查 inventory 时仍推荐 clone：

```bash
git clone https://github.com/sunpcm/DevOpsToolkit.git
cd DevOpsToolkit
ansible-galaxy collection install -r ansible/requirements.yml
./bin/devops-toolkit
```

源码入口的 `devops-toolkit --version` 显示 `development`；Release 安装显示对应 tag。

## 安全边界

- 临时下载目录权限为 `0700`，资产文件为 `0600`。
- 系统安装的 `current` 与 launcher 符号链接会保持普通用户可遍历；即使安装器由 `sudo` 在 macOS 执行，
  非 root 用户也能解析 Release 根目录并读取正确版本。
- 安装器拒绝绝对路径、`..`、额外顶层目录、符号链接和设备文件，避免 tar 路径穿越。
- SHA256 用于完整性检查；Sigstore 进一步要求产物来自本仓库、指定 Release workflow 和对应 tag。
- Sigstore 验证失败时不会降级为只检查 SHA256。
- `raw.githubusercontent.com/.../main/install.sh` 本身仍是可变的 root 执行代码。高安全环境应先下载、审查并固定安装器提交，再执行固定 Release。
- 首次 SSH 连接仍会正常校验主机指纹，安装方式不会关闭该保护。

完整信任模型和 GitHub 手工加固清单见[发布供应链安全](SUPPLY_CHAIN_SECURITY.md)。

## 签名验证故障排查

### Release 缺少 `.sigstore.json`

通常表示该版本发布不完整或早于签名机制。不要手工伪造空 bundle，也不要改成只验证 SHA256；应重新发布新版本。

### Cosign SHA256 校验失败

不要执行已下载的 Cosign。先确认系统与架构：

```bash
uname -s
uname -m
```

然后检查网络代理是否返回了登录页、错误页或被替换的下载内容。安装器当前只支持 Linux/macOS 的 AMD64 与 ARM64。

### Sigstore 身份验证失败

这表示签名不存在、签名不绑定当前压缩包，或者证书身份不是本仓库的 Release workflow 和对应 tag。该错误不能通过重算 SHA256 修复，应检查 GitHub Actions 的 Release 运行记录和三个 Release 资产是否来自同一次发布。

### 网络或证书错误

确认系统时间、CA 证书和 HTTPS 代理正确：

```bash
date -u
curl -I https://github.com
curl -I https://tuf-repo-cdn.sigstore.dev
```

网络恢复后重新运行安装器即可；失败过程不会删除旧版本。

### 内置 collections 与旧版本兼容

从 `v0.1.5` 起，Release tarball 内置并签名覆盖固定版本的 `ansible.posix` 与
`community.general`。安装器会核对包内 manifest 和版本标记，安装阶段不再访问 Ansible Galaxy；
这消除了 GitHub 可达但 Galaxy 不可达时的安装单点。

`v0.1.4` 及更早的历史 Release 没有内置标记。新版安装器会明确提示兼容模式，并继续通过
`ansible-galaxy collection install` 安装固定依赖；下载失败时仍不会切换 `current`。从源码运行不包含
Release 产物内的 collections，仍应先显式完成：

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### GitHub Release 或 Cosign 下载过慢

安装器对远程下载启用有限重试和传输停滞检测。网络受限时可以分别覆盖本项目 Release 资产
与固定版本 Cosign 的下载目录；下载内容仍会经过 SHA256 和 Sigstore 身份验证：

```bash
curl -fsSL -o /tmp/devops-toolkit-install.sh \
  https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh

sudo env \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="https://可信镜像.example/DevOpsToolkit/releases/download/v0.1.4" \
  DEVOPS_TOOLKIT_COSIGN_BASE="https://可信镜像.example/sigstore/cosign/releases/download/v3.1.1" \
  bash /tmp/devops-toolkit-install.sh --version v0.1.4
```

`DEVOPS_TOOLKIT_DOWNLOAD_BASE` 必须直接包含三个固定名资产；`DEVOPS_TOOLKIT_COSIGN_BASE`
必须直接包含当前平台的 `cosign-<os>-<arch>`。镜像只能改善可达性，不能跳过校验。

不要从未经审查的镜像直接执行 `install.sh`：Release 资产和 Cosign 有内置校验，安装器脚本本身没有
独立签名。高安全环境应按供应链文档固定安装器 commit、先审查再执行。
