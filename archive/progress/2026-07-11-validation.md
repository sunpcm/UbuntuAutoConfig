# 2026-07-11 统一实现验证记录

本文保存已完成阶段的验证证据。它不是当前任务列表；后续工作以仓库根目录
[`TODO.md`](../../TODO.md) 为准。

## 统一实现与质量门禁

- `ansible/` 已成为唯一受支持实现，重复的 WSL2 / Ubuntu Server Ansible 树已归档。
- CI 已启用 ShellCheck、Ansible Lint、YAML Lint、Ruff、Actionlint 和 secrets scan。
- uv 改为固定版本、按架构固定 SHA256 的产物下载，不再执行 `curl | sh`。
- UFW 规则通过 DevOpsToolkit application profile 声明式收敛，不改写管理员手工规则。

## Multipass 22.04 / 24.04

测试环境为 Multipass 1.16.3、Apple Silicon `aarch64`，使用严格命名的一次性实例。

- Ubuntu 22.04：首次 `changed=23 failed=0`；第二次 `changed=0 failed=0`。
- Ubuntu 24.04：首次 `changed=25 failed=0`；第二次 `changed=0 failed=0`。
- 两个版本均验证用户创建、SSH 密钥登录、SSH 22 → 2222、UFW 防锁死、Docker、Nginx。
- 22.04 走传统 `ssh.service`；24.04 走 `ssh.socket` override。

24.04 测试曾发现：Ubuntu 22.10+ 的 OpenSSH 监听端口由 `ssh.socket` 决定，只修改
`sshd_config` 的 `Port` 不生效；叠加 UFW 只放行新端口会锁死主机。当前
`ssh_security` 会检测 socket 激活，写入 `ssh.socket.d` override，并在切换连接前验证端口。

测试同时修正了 UFW 断言：`ufw status` 只显示 application profile 名称，因此端口验证应使用
`ufw app info DevOpsToolkit`。

## 发布与安装器

- 首个可用 Release 为 `v0.1.2`；`v0.1.3`、`v0.1.4` 后续补齐入口和 Ubuntu 22.04 修复。
- Release 必须由 `.github/workflows/release.yml` 在 tag push 后创建；网页预建同名 Release 会导致
  `gh release create` 冲突并产生空 Release。
- 安装器已覆盖 `bash -c "$(curl ...)"` 入口、Ubuntu 22.04 apt Ansible 2.10 的 pip fallback、
  GitHub 下载重试和停滞检测。

## 已知网络边界

- 完整系统测试默认不启用 uv 下载；`--with-uv` 依赖 guest 稳定访问 GitHub Release assets。
- 受限网络可覆盖 DevOpsToolkit Release 与 Cosign 下载目录，但安装器本身仍应从固定 commit 获取并审查。
