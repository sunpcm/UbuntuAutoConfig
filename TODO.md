# DevOpsToolkit TODO

> 更新日期：2026-08-01
>
> 原则：这里只保留尚未完成、可验证的工作；已完成阶段的详细记录移入
> [`archive/progress/`](archive/progress/)。

## 当前基线

- 唯一受支持实现是 `ansible/`，唯一受支持入口是 `bin/` 与 `install.sh`。
- 原根目录兼容 Playbook、`wsl-dev/`、`ubuntu-server/` tracked 资产已归档；
  `tests/verify-ansible.sh` 会阻止它们重新出现在活跃路径。
- Ubuntu 22.04 / 24.04 已通过首次执行、第二次 `changed=0`、受控 uv 镜像和系统故障注入验证。
- main 最近一次线上 Validate（`7232138`）通过；当前 latest Release 为 `v0.1.4`，但它早于
  main 上的 GitHub 下载重试、停滞检测、Cosign 镜像开关和内置 collections。
- 安装器测试已覆盖 SHA256 错误、缺少 checksum / Sigstore bundle、危险 tar、版本不匹配、
  Ubuntu 22.04 Ansible 版本过低等失败边界。

## P0：发布前阻塞项

- [ ] 从通过验收的 main 发布下一个不可变版本，确认 Validate/Release 全绿、三个资产齐全，并分别用 latest 与
      `--version` 安装命令验证 SHA256 + Sigstore 身份。

## P1：升级闭环

- [ ] 在真实 VM 记录一次升级与回滚：从 `v0.1.4` 升级到下一版本，确认旧版本目录保留、重复安装幂等，
      再原子切回旧版并验证命令可用。

## 已完成项

- [x] 统一 WSL2、Ubuntu、user-only 三种模式并归档重复实现。
- [x] 固定 Oh My Zsh、Linuxbrew、插件与 uv 产物版本/校验值。
- [x] 建立 ShellCheck、Ansible Lint、YAML Lint、Ruff、Actionlint、gitleaks 与 Ansible 2.12/2.18 CI。
- [x] 完成 22.04 / 24.04 SSH 22 → 2222、UFW、Docker、Nginx 与二次 `changed=0` 验证。
- [x] 修复 24.04 `ssh.socket` 端口切换并增加静态防锁死护栏。
- [x] 建立 SHA256 + Sigstore Release、不可变安装目录、升级/回滚机制和发布手册。
- [x] 为 uv 增加受控 HTTPS base URL，并在 22.04 / 24.04 验证固定 SHA256 产物与二次幂等。
- [x] 增加系统故障注入：无效 sshd 配置预重启失败、陈旧 UFW profile、冲突 Docker APT 源、部分账户状态
      中断恢复，最终均达到 `changed=0`。
- [x] 在 Ubuntu 22.04 真实服务器完成 root 本地向导与 macOS 控制端远程向导：验证目标用户密钥登录、
      显式 `NOPASSWD`、Shell/uv、Docker/Nginx/UFW/SSH，并且两条链路第二次执行均为 `changed=0`。
- [x] 远程 SSH 连通性验证改用 `wait_for_connection`，支持 `~/.ssh/config` alias / ProxyJump，并增加静态护栏。
- [x] 将固定版本 `ansible.posix` 与 `community.general` 打入已签名 Release，安装阶段不再依赖 Ansible Galaxy；
      保留旧 Release 的显式兼容回退，并覆盖离线安装、版本校验和失败不切换测试。
