# 交互式向导

交互式向导适合单台机器首次初始化或临时配置。Release 安装后运行：

```bash
devops-toolkit
```

从源码运行：

```bash
./bin/devops-toolkit
```

它不会替代 Ansible Playbook，而是收集输入后调用现有的 WSL2、Ubuntu 或 user-only Playbook。因此权限边界、幂等逻辑和手工入口保持一致。

组件选择采用批量切换界面：输入一个或多个编号（例如 `2,4,6`）切换选中状态，输入 `a` 全选、`n` 全不选，按回车确认。该方式不依赖额外的 TUI 库，在 SSH、WSL 和精简服务器终端中都能稳定工作。

## 支持的选择

### WSL2

- 创建或更新普通用户。
- 明确选择“密码”“SSH 公钥”“两者”或“不修改已有凭据”；密码只在随后出现的隐藏输入框中输入。
- 选择 Shell、Git、uv、Node.js、Go、Linuxbrew 和 WSL 集成。
- 可检查 Docker Desktop WSL Integration。

必须在 WSL 内以 root 运行：

```bash
sudo ./bin/devops-toolkit
```

### Ubuntu

- 已经以 root 登录新服务器时，可选择“当前服务器本地执行”，无需再次配置 SSH inventory。
- 也可以从 macOS、WSL 或其他控制端通过 SSH 配置远程服务器。
- 输入服务器、当前 SSH 端口和 root 认证方式。
- 目标主机可以是可解析主机名/IP，也可以是 `~/.ssh/config` 中的 Host alias；端口切换后的验证使用
  Ansible SSH 连接配置，因此兼容 alias 与 ProxyJump。
- bootstrap 模式每次都会明确询问是否授予目标用户 `NOPASSWD:ALL`；该高权限选项始终默认关闭且不记忆。
  新建“只配置 SSH 公钥”用户时会额外提示常规 sudo 无密码可验证；失败后重跑仍须重新确认该选项，向导
  不会静默假设已有账户的 sudo 策略。
- 创建或更新普通用户。
- 公钥既可直接粘贴，也可输入 `.pub` 文件路径。
- 选择 Linuxbrew、Docker、Nginx、UFW 和 OpenSSH 管理。
- 启用 Nginx 和 UFW 时自动放行 80/443。
- 支持输入其他 TCP/UDP 放行端口。

当前 Ubuntu Playbook 仍要求 root SSH 登录，因此远程模式开始前必须允许 root 公钥登录；若服务器已设置
`PermitRootLogin no`，应改用服务器本地执行模式，或在有备用控制台的前提下临时允许
`PermitRootLogin prohibit-password`。向导本身不会禁用 root 登录。使用密钥连接且给目标用户配置了公钥时，
可以选择禁用 SSH 密码认证。

新服务器本地初始化的推荐流程：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)"
```

安装阶段会验证 SHA256 和 Sigstore 发布身份；签名或网络验证失败时不会启动向导，也不会降级为未签名安装。详细故障排查见[安装、升级与回滚](INSTALLATION.md)。

需要审查最新源码、开发调试或不使用 Release 安装器时使用 clone。源码运行要求
`ansible-core >= 2.12`；Ubuntu 22.04 的 apt `ansible` 只有 2.10，应优先使用安装器自动补齐，
或手工安装兼容版本：

```bash
apt update
apt install -y git ansible python3-pip
git clone https://github.com/sunpcm/DevOpsToolkit.git
cd DevOpsToolkit
ansible-playbook --version
# 仅当版本低于 2.12 时执行
python3 -m pip install 'ansible-core>=2.12,<2.19'
ansible-galaxy collection install -r ansible/requirements.yml
./bin/devops-toolkit
```

选择 `Ubuntu` → `当前服务器本地执行`。首次初始化不会自动关闭 SSH 密码认证，应先从另一终端验证新用户密钥登录。

### user-only

- 使用普通用户密码或密钥登录。
- 只选择当前用户需要的开发环境。
- 默认不使用 sudo。
- 可显式允许 sudo 安装白名单基础依赖。

## 版本选择

启用 Node.js 或 Go 后，向导会显示项目当前固定版本，可直接回车采用，也可输入其他精确版本。选择结果会传给本次 Ansible 执行，并在成功后作为下次默认值。

Python 是 Ansible 和系统模块的基础依赖，向导不替换系统 Python，也不提供 Python 版本切换。项目级 Python 版本应在部署完成后使用 `uv` 和项目的 `.python-version` / `pyproject.toml` 管理，避免破坏 Ubuntu 的系统工具。

## 记住上次选择

Ansible 成功完成后，向导将非敏感选择保存到：

```text
~/.config/devops-toolkit/wizard-state.json
```

文件权限为 `0600`，目录权限为 `0700`。使用 `sudo` 启动时，状态属于原始操作用户，而不是错误地写入 `/root`。下次运行会恢复上次模式、目标用户名、组件开关、Git 身份以及 Node.js/Go 版本。

以下内容永不保存：密码或密码哈希、SSH 公钥和私钥、SSH/sudo 密码、目标主机与认证参数、防火墙端口、关闭密码认证的确认，以及 user-only 的 sudo 例外。高风险选择必须每次重新确认。

需要清空默认选择时，先保留备份再重新运行向导：

```bash
state="$HOME/.config/devops-toolkit/wizard-state.json"
test -f "$state" && mv "$state" "$state.bak.$(date +%Y%m%d%H%M%S)"
```

## 敏感信息处理

- SSH 私钥只输入文件路径，向导不会读取或复制私钥内容。
- SSH 密码由 Ansible 的 `--ask-pass` 直接询问。
- sudo 密码由 Ansible 的 `--ask-become-pass` 直接询问。
- 新用户本地密码使用隐藏输入，立即通过 `openssl passwd -6` 转为哈希。
- 临时 inventory 和变量文件位于系统临时目录，目录仅当前用户可访问，文件权限为 `0600`。
- 正常完成、执行失败或 Ctrl+C 后自动删除临时文件。
- 向导不会关闭 SSH 主机指纹校验，也不会自动接受未知指纹。

密码 SSH 认证通常要求控制端安装 `sshpass`；更推荐使用带密码保护的 SSH 私钥。

首次连接服务器前应人工确认指纹：

```bash
ssh root@SERVER
```

## 交互式与配置文件的取舍

交互式向导只保存便于重复执行的非敏感默认值，适合少量机器和人工操作；它不是 inventory、Vault 或声明式配置的替代品。

以下场景继续使用 inventory、Vault 和原始入口：

- CI/CD。
- 多台服务器批量部署。
- 需要代码审查的生产配置。
- 需要长期保存并重复使用相同配置。

原始入口保持不变：

```bash
sudo ./bin/wsl-bootstrap developer
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer
./bin/user-only ansible/inventories/user-only.ini
```
