# DevOpsToolkit TODO

> 更新日期：2026-07-11
>
> 原则：按优先级推进；完成一项后补充验证证据，再进入下一项。

## P0：收敛遗留实现

- [x] 明确 `ansible/` 为唯一实现，盘点并归档 `ubuntu-server/ansible/` 与 `wsl-dev/ansible/` 的重复角色和变量。
- [x] 将旧入口收敛为只转发到统一入口的兼容包装，并增加明确的弃用提示。
- [x] 从旧配置中移除个人 SSH 公钥、默认免密 sudo、开发端口和默认启用服务等高风险示例值。
- [x] 增加仓库检查，阻止内联真实 SSH 公钥再次提交。

## P1：安全与质量门禁

- [x] 将 uv 安装改为固定版本产物下载并校验 SHA256，移除 `curl | sh`。
- [x] 在 CI 中强制运行 ShellCheck、Ansible Lint、YAML Lint、Ruff、Actionlint 和 secrets scan。
- [x] 让 UFW 规则具备声明式收敛能力：只清理 DevOpsToolkit 托管且已从配置删除的规则，不影响人工规则。

## P1：Multipass 真实环境测试

> 2026-07-11 进展：已验证 Multipass 1.16.3、Apple Silicon `aarch64`、22.04/24.04 启动与联网，
> 并在 22.04 验证项目目录挂载、SSH 22→2222 切换和 UFW 防锁死。完整双版本幂等测试仍受
> VM 内 GitHub uv 产物下载长时间无响应阻塞；现已将 uv 调整为 `--with-uv` 扩展测试，核心双版本
> 测试仍需重跑后才能计为完成。
>
> 2026-07-11 24.04 复测发现并修复两个问题：
> 1. **产品缺陷（已修）**：Ubuntu 22.10+（含 24.04）OpenSSH 由 `ssh.socket` 决定监听端口，
>    旧实现只改 `sshd_config` 的 `Port`，改端口在 24.04 上不生效；叠加 UFW 只放行新端口，会把
>    主机锁死。`ssh_security` 现在检测 socket 激活并写 `ssh.socket.d` override 收敛端口。已在
>    24.04 直接登录 2222 验证：主机只监听 2222、未锁死。
> 2. **测试缺陷（已修）**：`verify_result` 用 `ufw status | grep 2222/tcp` 判定，而 UFW 通过托管
>    应用 profile 收敛，`ufw status` 只显示 profile 名，会误判失败；改用 `ufw app info` 断言端口。
>
> 另观察到 `download.docker.com` 在本机 Multipass 网络下约 1/3 概率 `Connection reset`；Docker
> key 下载重试已从 3 提升到 5、加 `timeout`。24.04 socket 修复后端到端绿灯：首次
> `changed=25 failed=0`，第二次 `changed=0 failed=0`（幂等），`verify_result` 全通过。

- [x] 安装并验证 Multipass，确认 Apple Silicon 上虚拟机可正常启动、联网和挂载项目目录。
- [x] 新增 Ubuntu 22.04 与 24.04 测试脚本，覆盖首次执行和第二次幂等执行（目标 `changed=0`）。
      —— 两版本均端到端绿灯：24.04 首次 `changed=25`、22.04 首次 `changed=23`，第二次均 `changed=0`。
      验证了 socket 分支：24.04 走 ssh.socket、22.04 走传统 ssh.service（socket 任务/handler 均正确跳过）。
- [x] 覆盖用户创建、SSH 密钥登录、SSH 端口切换、UFW 防锁死、Docker 和 Nginx 服务状态。
      —— 22.04 与 24.04 均端到端验证通过。
- [x] 测试脚本默认使用临时实例名，并提供安全的检查、保留现场和清理命令。
- [x] 评估将无破坏性的 Multipass 冒烟测试接入 CI；完整系统测试保留为定期或手动工作流。

## P2：发布与维护

- [ ] 建立固定版本与校验和的升级流程，并记录升级验证结果。
- [ ] 在真实 VM 验证完成后删除兼容实现，更新 README、配置文档和 Release 包内容。
- [ ] 补充故障注入测试：SSH 配置无效、UFW 规则冲突、下载校验失败和重复执行中断恢复。
