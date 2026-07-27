# 三个场景完整使用指南

本文按实际使用场景给出完整流程。单机首次初始化推荐先按[安装文档](INSTALLATION.md)安装统一命令，再运行 `devops-toolkit`；以下手工命令均从仓库根目录执行，适合 CI 和长期自动化。

## 开始之前

### 控制端要求

- `ansible-core >= 2.12`
- Git
- SSH 客户端（远程场景）
- 能访问 GitHub 和软件源

安装项目依赖：

```bash
ansible-galaxy collection install -r ansible/requirements.yml
./tests/verify-ansible.sh
```

### 推荐：交互式执行

不希望手工维护 inventory 和变量文件时，直接运行：

```bash
./bin/devops-toolkit
```

WSL2 模式使用：

```bash
sudo ./bin/devops-toolkit
```

向导会生成临时 inventory 和 extra vars，然后调用本文后续介绍的同一套 Playbook。临时文件权限为 `0600`，正常结束、失败或 Ctrl+C 后都会清理。详细说明见 [交互式向导](INTERACTIVE.md)。

下面的手工流程仍适用于 CI、批量部署和需要版本控制的环境。

### 配置目标用户凭据

WSL2 和 Ubuntu 初始化会创建目标用户。如果用户尚不存在，必须配置 SSH 公钥或密码哈希。

公钥方式：

```yaml
# ansible/group_vars/all.yml
target_authorized_keys:
  - "ssh-ed25519 AAAAC3... workstation"
```

密码方式：

```bash
# 交互输入密码，只输出哈希
openssl passwd -6
```

将输出写入加密变量文件：

```bash
ansible-vault create ansible/secrets.yml
```

```yaml
target_password_hash: "$6$..."
```

执行时追加：

```bash
--ask-vault-pass -e @ansible/secrets.yml
```

不要把明文密码或密码哈希写入 inventory。

## 场景一：初始化 WSL2

### 适用条件

- Windows 上已经安装 WSL2 Ubuntu。
- 当前可以进入 WSL root，或者当前用户拥有 sudo。
- 需要创建或配置一个普通开发用户。
- Docker 功能依赖 Windows Docker Desktop 已启动并启用 WSL Integration。

### 执行步骤

在 WSL2 内安装依赖：

```bash
sudo apt update
sudo apt install -y ansible python3-pip git
ansible-playbook --version
# Ubuntu 22.04 的 apt ansible 为 2.10；仅在版本低于 2.12 时执行
sudo python3 -m pip install 'ansible-core>=2.12,<2.19'
ansible-galaxy collection install -r ansible/requirements.yml
```

编辑公共配置：

```bash
cp ansible/group_vars/all.yml "ansible/group_vars/all.yml.bak.$(date +%Y%m%d_%H%M%S)"
vim ansible/group_vars/all.yml
```

运行：

```bash
sudo ./bin/wsl-bootstrap developer
```

如果使用 Vault：

```bash
sudo ./bin/wsl-bootstrap developer \
  --ask-vault-pass -e @ansible/secrets.yml
```

### 会发生什么

- 安装基础系统依赖并设置时区和 Locale。
- 创建或更新 `developer` 用户。
- 为 root 写入最小运维 Shell 配置。
- 为目标用户配置 Zsh、Git、uv、NVM、Node、Go 和 CLI 工具。
- 获取真实 Windows 用户名，创建存在的 Desktop、Documents、Downloads 链接。
- 启用 Docker 集成检查时，确认 Docker Desktop 可访问。

### 验证

```bash
su - developer
whoami
printf '%s\n' "$HOME"
zsh --version
git config --global --list
node --version
uv --version
docker version
```

目标用户应为 `developer`，HOME 应是 passwd 数据库中的真实目录，而不是 `/root`。

如果目标用户只有密钥、没有可用密码，执行 sudo 时可能无法通过密码验证。需要 sudo 的场景应配置账户密码，或在充分理解风险后设置 `target_passwordless_sudo: true`。

## 场景二：初始化 Ubuntu 服务器

### 适用条件

- 目标是 Ubuntu 服务器。
- 可以通过 root 密码或密钥登录。
- 需要安装系统组件并创建普通用户。

### 配置 inventory

```bash
cp ansible/inventories/ubuntu.ini.example ansible/inventories/ubuntu.ini
vim ansible/inventories/ubuntu.ini
```

示例：

```ini
[ubuntu_servers]
prod-1 ansible_host=203.0.113.10 ansible_user=root ansible_port=22

[ubuntu_servers:vars]
ansible_python_interpreter=/usr/bin/python3
```

首次连接先人工核对主机指纹：

```bash
ssh root@203.0.113.10
```

不要为了省事关闭 `host_key_checking`。

### 执行

密钥登录：

```bash
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer \
  --private-key ~/.ssh/id_ed25519
```

密码登录：

```bash
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer \
  --ask-pass
```

使用 Vault：

```bash
./bin/ubuntu-bootstrap ansible/inventories/ubuntu.ini developer \
  --private-key ~/.ssh/id_ed25519 \
  --ask-vault-pass -e @ansible/secrets.yml
```

### SSH 加固注意事项

默认不会禁用 root 登录或密码认证。当前 `ubuntu-bootstrap` 后续仍要求 root SSH，因此不要在需要继续维护的机器上设置 `disable_root_login: true`。

确认 root 已经可以使用密钥连接，并测试目标用户密钥后，可以仅禁用 SSH 密码认证：

```yaml
disable_root_login: false
disable_password_auth: true
target_authorized_keys:
  - "ssh-ed25519 AAAAC3... workstation"
```

Playbook 会先配置 UFW、写入 OpenSSH drop-in、执行 `sshd -t`，然后才重启 SSH。即便如此，也必须：

1. 保持当前 root 会话不关闭。
2. 在另一个终端测试目标用户的新连接。
3. 确认密钥、端口和 sudo 符合预期后，再退出当前会话。

### 验证

```bash
ssh -p 22 developer@203.0.113.10
id
sudo -l
systemctl status ssh --no-pager
sudo ufw status verbose
```

如果启用了 Docker：

```bash
docker version
docker compose version
```

加入 Docker 组后需要重新登录才能生效。Docker 组近似 root 权限，不应授予不可信用户。

## 场景三：只配置当前用户

### 适用条件

- 服务器已经创建好普通用户。
- 用户可以通过密码或密钥登录。
- 不允许创建用户、修改 SSH、UFW、服务、root HOME 或其他用户 HOME。

### 配置 inventory

```bash
cp ansible/inventories/user-only.ini.example ansible/inventories/user-only.ini
vim ansible/inventories/user-only.ini
```

示例：

```ini
[user_only]
work-1 ansible_host=203.0.113.20 ansible_user=alice ansible_port=22

[user_only:vars]
ansible_python_interpreter=/usr/bin/python3
```

### 执行

密钥登录：

```bash
./bin/user-only ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519
```

密码登录：

```bash
./bin/user-only ansible/inventories/user-only.ini --ask-pass
```

严格模式要求目标已有 `curl`、`git`、`zsh`。如果缺少依赖，推荐让管理员执行：

```bash
sudo apt update
sudo apt install -y curl git zsh
```

如果该用户明确拥有 sudo 权限，也可以允许 Playbook 只安装这三个白名单包：

```bash
./bin/user-only ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519 \
  --ask-become-pass \
  -e user_only_allow_system_dependencies=true
```

这是 user-only 唯一允许的系统级例外。

### user-only 的保护机制

- 拒绝以 root 执行。
- 拒绝把 `target_user` 指向另一个用户。
- 通过 passwd 数据库解析真实 HOME。
- 要求 SSH 登录用户、实际用户和 HOME 一致。
- 用户角色所有写入均指向当前 HOME。
- 不安装共享 Linuxbrew；goenv 和 Go 安装在当前用户 HOME 内。

### 删除托管配置

```bash
./bin/user-only-remove ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519
```

该命令只删除：

- `.zshrc` 中的 DevOpsToolkit source 区块。
- `~/.config/devops-toolkit/`。

它不会删除用户原有 `.zshrc`、Oh My Zsh、NVM、Node、uv 或 Go，避免误删安装前就存在的数据。

## 更新与重复执行

三个场景都通过重复执行同一命令更新。建议先预演：

```bash
# 将下面的入口和参数替换为实际场景
./bin/user-only ansible/inventories/user-only.ini \
  --private-key ~/.ssh/id_ed25519 \
  --check --diff
```

涉及 Git 仓库或外部安装器时，check mode 只能作为辅助判断，不能替代测试机验证。
