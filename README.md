# DevOpsToolkit

基于 Ansible 的 Linux 环境配置工具，明确区分系统配置、root 配置和普通用户配置。

## 选择你的场景

| 场景 | 登录/执行身份 | 会修改系统 | 会创建用户 | 用户配置范围 | 入口 |
|---|---|---:|---:|---|---|
| WSL2 初始化 | WSL 内 root | 是 | 是 | root 最小配置 + 目标用户完整配置 | `bin/wsl-bootstrap` |
| Ubuntu 服务器初始化 | SSH root | 是 | 是 | root 最小配置 + 目标用户完整配置 | `bin/ubuntu-bootstrap` |
| 已有用户配置 | 普通用户密码或密钥 | 默认否 | 否 | 只修改当前用户 HOME | `bin/user-only` |

如果不确定该选哪个：

- 新装 WSL2，需要创建开发用户：选择 WSL2 初始化。
- 新买 Ubuntu VPS，需要初始化系统和创建运维用户：选择 Ubuntu 服务器初始化。
- 公司服务器已有账号，只想配置自己的 Shell 和开发工具：选择 user-only。

## 快速开始

### 推荐：Release 一行安装

新 Ubuntu/WSL 已经以 root 登录时：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)"
```

安装完成后会在交互终端自动启动向导。选择 `Ubuntu` → `当前服务器本地执行`，即可创建目标用户并配置系统；普通用户执行同一命令时只安装到 `~/.local`，且绝不提权。

安装器会同时验证 Release 的 SHA256 和 Sigstore 身份，要求产物来自本仓库的 Release workflow 与对应 tag；验证失败不会降级安装。首次运行会下载并缓存固定版本 Cosign。

生产环境建议固定版本：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)" -- --version v0.1.0
```

完整的安装位置、`--no-run`、升级、回滚和供应链边界见 [安装、升级与回滚](docs/INSTALLATION.md)。首个 Release 发布前，一行安装地址尚无可下载资产，请暂时使用下面的源码方式。

### 从源码运行（CI 与高级用户）

```bash
git clone https://github.com/sunpcm/DevOpsToolkit.git
cd DevOpsToolkit

# Ubuntu / WSL2
sudo apt update
sudo apt install -y ansible git

# 仅密码 SSH 登录需要
sudo apt install -y sshpass

# 安装项目需要的 Ansible collection
ansible-galaxy collection install -r ansible/requirements.yml
```

macOS 控制端可使用：

```bash
brew install ansible
# macOS 控制端推荐使用 SSH 私钥认证
ansible-galaxy collection install -r ansible/requirements.yml
```

### 使用交互式向导

```bash
./bin/devops-toolkit
```

向导会依次选择：

- WSL2、Ubuntu 或 user-only 模式。
- 密码或私钥认证。
- 目标用户，以及密码、公钥、两者或保留已有凭据。
- 批量选择 Shell、Git、uv、Node.js、Go、Linuxbrew、Docker、Nginx、UFW 等组件。
- Node.js 和 Go 的精确版本。

无需编辑 inventory 或变量文件。密码只用于内存中生成 SHA-512 哈希；inventory 和变量写入权限为 `0600` 的临时目录，执行结束自动删除。成功执行后只记住组件、Git 身份和工具版本等非敏感选择，高风险选项仍会逐次确认。

WSL2 模式需要：

```bash
sudo ./bin/devops-toolkit
```

如果已经以 root 登录一台全新 Ubuntu 服务器，也可以 clone 本项目后直接运行 `./bin/devops-toolkit`，选择 `Ubuntu` → `当前服务器本地执行`，无需创建 inventory。

### 手工配置（适合 CI 和长期自动化）

修改前先备份：

```bash
cp ansible/group_vars/all.yml "ansible/group_vars/all.yml.bak.$(date +%Y%m%d_%H%M%S)"
vim ansible/group_vars/all.yml
```

新建目标用户时，至少提供一种登录凭据：

```yaml
target_authorized_keys:
  - "ssh-ed25519 AAAA... your-device"

# 或使用 openssl passwd -6 生成的密码哈希
target_password_hash: "$6$..."
```

### 执行对应入口

WSL2：

```bash
sudo ./bin/wsl-bootstrap developer
```

Ubuntu 服务器：

```bash
cp ansible/inventories/ubuntu.ini.example ansible/inventories/ubuntu.ini
vim ansible/inventories/ubuntu.ini

# root 密钥登录
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer \
  --private-key ~/.ssh/id_ed25519

# root 密码登录则使用 --ask-pass
```

已有普通用户：

```bash
cp ansible/inventories/user-only.ini.example ansible/inventories/user-only.ini
vim ansible/inventories/user-only.ini

# 用户密钥登录
./bin/user-only ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519

# 用户密码登录则使用 --ask-pass
```

## 默认安装内容

- Zsh、Oh My Zsh 和常用插件
- Git 用户配置
- uv、NVM、Node.js、goenv/Go
- 系统托管的 Linuxbrew 和现代 CLI 工具
- WSL2 Windows 目录与剪贴板集成
- Ubuntu 可选 Docker、Nginx、UFW 和 SSH 加固

所有功能均由 [公共变量](ansible/group_vars/all.yml) 控制。Docker 和 Nginx 默认关闭；SSH 禁用 root/密码登录默认关闭。

## 安全边界

- user-only 拒绝 root，且要求登录用户、目标用户和 HOME 所有者一致。
- user-only 默认不使用 sudo；缺少 `curl`、`git`、`zsh` 时会退出。
- user-only 配置 Go 时还需要 `cc` 和 `make`；缺少时会提示管理员安装 `build-essential`。
- Oh My Zsh、插件、Linuxbrew 和语言工具使用集中版本配置，重复执行不会自动跟随上游分支。
- 设置 `user_only_allow_system_dependencies=true` 后，只允许通过 sudo 安装上述白名单依赖。
- 不在 inventory 中保存 SSH 密码或 sudo 密码。
- 默认开启 SSH 主机指纹校验。
- Release 同时执行 SHA256 与 Sigstore/Cosign 身份验证，任一失败都不会切换已安装版本。
- 用户 Shell 配置写入 `~/.config/devops-toolkit/shell.zsh`，仅在现有 `.zshrc` 中增加一个托管 source 区块。

## 文档

- [安装、升级与回滚](docs/INSTALLATION.md)
- [发布流程](docs/RELEASING.md)
- [发布供应链安全与 GitHub 加固](docs/SUPPLY_CHAIN_SECURITY.md)
- [三个场景完整使用指南](docs/GETTING_STARTED.md)
- [交互式向导说明](docs/INTERACTIVE.md)
- [配置、安全与故障排查](docs/CONFIGURATION.md)
- [Multipass 真实环境测试](docs/MULTIPASS_TESTING.md)
- [ACME 证书管理](AcmeConfig/README.md)
- [历史文档](archive/README.md)

## 验证代码

```bash
./tests/verify-ansible.sh
```

该检查覆盖新旧入口的 Bash 语法、全部 Playbook 的 Ansible 语法、安装器失败边界、Release 包内容、Sigstore 身份参数、Action 固定引用，以及全局提权、主机指纹和弃用模块检查。

Ubuntu 22.04/24.04 系统级验证使用严格命名的一次性实例，详见
[Multipass 真实环境测试](docs/MULTIPASS_TESTING.md)。不要在长期保留的 Multipass 实例上测试 SSH 端口切换。

## 兼容入口

以下入口暂时保留，但只作为兼容包装，不应再用于新文档或自动化：

- `wsl-dev/bootstrap.sh`
- `ubuntu-server/bootstrap.sh`
- 根目录 `playbook.yml`
- 根目录 `setup_wsl.yml`

旧 Ansible 实现已移入 `archive/legacy-implementations/`，仅用于历史追溯，不能执行或作为配置来源。兼容入口只转发到统一实现，不再读取旧变量。
