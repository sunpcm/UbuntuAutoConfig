# 配置、安全与故障排查

## 修改配置

当前统一实现只使用：

```text
ansible/group_vars/all.yml
```

旧 Ansible 实现位于 `archive/legacy-implementations/`，仅用于历史追溯，不能执行或作为配置来源。

修改前备份：

```bash
cp ansible/group_vars/all.yml "ansible/group_vars/all.yml.bak.$(date +%Y%m%d_%H%M%S)"
vim ansible/group_vars/all.yml
```

## 常用变量

### 账户和认证

| 变量 | 默认值 | 说明 |
|---|---|---|
| `target_user` | 空 | WSL/Ubuntu 入口通过命令行传入；user-only 自动使用登录用户 |
| `target_password_hash` | 空 | 新用户密码哈希，不接受明文密码 |
| `target_authorized_keys` | `[]` | 新用户 SSH 公钥列表 |
| `target_passwordless_sudo` | `false` | 是否授予目标用户 `NOPASSWD:ALL` |

新用户至少需要密码哈希或 SSH 公钥。已有用户不会被强制重置密码。

目标用户会加入 `sudo` 组。如果新用户只配置了 SSH 密钥而没有可用密码，交互式 sudo 无法输入账户密码；此时应根据安全策略设置账户密码，或显式启用 `target_passwordless_sudo`。`NOPASSWD:ALL` 权限很高，不应默认开启。

### 用户环境

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `configure_shell` | `true` | Zsh、Oh My Zsh 和插件 |
| `configure_git` | `true` | Git 全局配置 |
| `configure_uv` | `true` | uv |
| `configure_node` | `true` | NVM 和 Node.js |
| `configure_go` | `true` | 在目标用户 HOME 内安装固定版本的 goenv 和 Go |
| `configure_homebrew_environment` | `true` | 在 Shell 中加载已有 Linuxbrew |
| `configure_wsl_integration` | `true` | WSL Windows 互操作配置 |
| `enable_wsl_docker_integration` | `true` | 检查 Docker Desktop 可用性 |

Git 身份默认留空，不会写入虚假姓名或邮箱：

```yaml
git_user_name: "Your Name"
git_user_email: "you@example.com"
git_editor: nvim
```

工具版本均集中配置并按实际版本校验：

```yaml
uv_version: "0.9.18"
nvm_version: bab86d5de571015b63fd8fc30b47bbe072a1290e
node_version: "24.11.1"
goenv_version: "3.1.4"
go_version: "1.22.1"
```

交互式向导启用 Node.js 或 Go 时会询问精确版本，并通过 extra vars 覆盖本次执行；手工 Playbook 和 CI 仍以这里的公共变量为准。系统 Python 不由工具切换，项目 Python 应使用 uv 管理。

Oh My Zsh、插件和 Linuxbrew 固定到不可变 Git commit。升级时应修改对应 revision，先在测试机运行两次幂等验证，再推广到正式机器。不要把 revision 改回 `main`、`master` 或开启自动更新，否则不同时间部署的机器可能得到不同结果。

### 系统组件

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `install_linuxbrew` | `true` | root 场景安装系统托管 Linuxbrew |
| `install_docker` | `false` | Ubuntu 安装 Docker CE |
| `install_nginx` | `false` | Ubuntu 安装并启动 Nginx |
| `enable_firewall` | `true` | Ubuntu 启用 UFW |
| `configure_ssh` | `true` | 管理 OpenSSH drop-in |
| `ssh_port` | `22` | SSH 监听端口及 UFW 放行端口 |
| `disable_root_login` | `false` | 禁止 SSH root 登录 |
| `disable_password_auth` | `false` | 禁止 SSH 密码认证 |

防火墙默认只放行 SSH。启用 Nginx 不会自动开放 80/443，需要显式添加：

```yaml
firewall_allowed_ports:
  - { port: "{{ ssh_port }}", proto: tcp, comment: SSH }
  - { port: "80", proto: tcp, comment: HTTP }
  - { port: "443", proto: tcp, comment: HTTPS }
```

## 使用 Vault 保存敏感变量

```bash
ansible-vault create ansible/secrets.yml
```

示例：

```yaml
target_password_hash: "$6$..."
```

执行时：

```bash
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer \
  --private-key ~/.ssh/id_ed25519 \
  --ask-vault-pass -e @ansible/secrets.yml
```

不要提交以下内容：

- SSH 私钥
- 明文密码
- Vault 密码文件
- 包含真实密码的 inventory

SSH 公钥可以提交，但更推荐放在环境专用变量文件中。

## 权限模型

### WSL2 和 Ubuntu

- 系统角色明确使用 `become: true`。
- root profile 只写 `/root/.config/devops-toolkit` 和 root Shell source 区块。
- user profile 切换为目标用户后，只写 passwd 数据库返回的目标 HOME。
- Linuxbrew 使用独立 `linuxbrew` 系统账号管理共享目录。

### user-only

- Playbook 全局 `become: false`。
- 只有显式开启依赖安装例外时，单个 apt 任务提权。
- 不允许把 user-only 当作 root 或任意用户配置器使用。
- goenv 及其 Go 版本安装在当前用户的 `~/.local/share/devops-toolkit/goenv`，不再依赖共享 Linuxbrew。旧实现产生的 `~/.goenv` 不会被自动删除。

## 功能开关的关闭语义

关闭功能时，只自动删除能够确定由 DevOpsToolkit 独占管理的内容：

- `configure_shell=false`：删除 `.zshrc` 中的托管 source 区块和托管 `shell.zsh`。
- `configure_wsl_integration=false`：删除托管 WSL source 区块和 `wsl.sh`。
- `target_passwordless_sudo=false`：删除 `90-devops-toolkit-<user>` sudoers 文件。

出于数据安全考虑，不会自动删除 `.oh-my-zsh`、`.nvm`、`.goenv`、uv、Docker、Nginx、Linuxbrew 或用户自己的 Git 配置。安装类开关表示“是否安装或继续管理”，不表示卸载。卸载系统软件和用户工具应单独执行并先备份数据。

## SSH 变更安全流程

修改 SSH 前备份配置：

```bash
ssh root@SERVER 'cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"'
```

Playbook 使用 `/etc/ssh/sshd_config.d/99-devops-toolkit.conf`，并执行：

```bash
/usr/sbin/sshd -t
```

如果要删除管理配置，先验证主配置和其他 drop-in 能维持正确登录方式：

```bash
sudo /usr/sbin/sshd -t
sudo ls -la /etc/ssh/sshd_config.d/
```

确认无误后才删除文件并重启 SSH。删除会改变远程登录行为，必须保持备用控制台或现有会话。

## 故障排查

### 提示找不到 Ansible collection

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### 新用户没有登录方式

错误原因：用户不存在，同时 `target_password_hash` 和 `target_authorized_keys` 都为空。

处理：配置其中一种凭据，或先由管理员创建该用户。

### user-only 提示缺少 cc、make、curl、git 或 zsh

推荐让管理员安装：

```bash
sudo apt update
sudo apt install -y build-essential curl git zsh
```

不要为了绕过检查而启用全局 sudo。

### user-only 拒绝 HOME

检查远端账户数据库和当前环境：

```bash
whoami
printf '%s\n' "$HOME"
getent passwd "$(whoami)"
```

三者必须对应同一个普通用户及真实 HOME。通过 `sudo su`、错误的 SSH 用户或手工覆盖 HOME 都会被拒绝。

### 修改 SSH 后无法新建连接

不要关闭原会话。执行：

```bash
sudo /usr/sbin/sshd -t
sudo systemctl status ssh --no-pager
sudo ss -lntp
sudo ufw status verbose
```

检查 inventory 的端口、`ssh_port`、UFW 规则和目标用户公钥是否一致。

### WSL Docker 检查失败

确认：

1. Windows Docker Desktop 已启动。
2. Docker Desktop 已为该 WSL 发行版启用 Integration。
3. 目标用户运行 `docker version` 成功。

如果不需要 Docker 检查：

```yaml
enable_wsl_docker_integration: false
```

## 开发验证

```bash
./tests/verify-ansible.sh
git diff --check
```

静态检查通过不代表系统级运行一定安全。SSH、UFW、用户创建和 Docker 安装必须先在临时 VM 验证首次执行与第二次幂等执行。

在测试目标上真实执行两次并要求第二次 `changed=0`：

```bash
./tests/verify-idempotence.sh -- \
  ./bin/user-only ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519
```

该命令会真实修改目标机，不要直接拿生产服务器作为首次验证环境。
