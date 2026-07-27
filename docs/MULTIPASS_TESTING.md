# Multipass 真实环境测试

`tests/multipass-smoke.sh` 用一次性 Ubuntu 22.04 和 24.04 实例验证统一 Ansible 实现。

## 为什么必须使用临时实例

Multipass 的 `exec`、`mount` 和常规停止操作依赖虚拟机中的 SSH 22 端口。测试会将 SSH 切换到
`MANAGED_SSH_PORT`（默认 2222），因此切换后 Multipass 可能把仍可通过 2222 正常访问的实例显示为
`Starting` 或不可达。

脚本因此拒绝在非 `*-test-*` 实例上执行端口切换。端口切换后的验证改用目标用户 SSH，清理时只允许
删除脚本生成的严格命名实例，并先强制停止这些临时实例。

## Ubuntu 24.04 的 SSH 端口由 ssh.socket 决定

Ubuntu 22.10 及以后（含 24.04 LTS）默认用 systemd socket 激活 OpenSSH：监听端口由 `ssh.socket`
的 `ListenStream=` 决定，`sshd_config` 里的 `Port` 会被忽略。因此 `ssh_security` 角色会检测 socket
激活，并写入 `/etc/systemd/system/ssh.socket.d/99-devops-toolkit.conf` 来收敛端口；22.04 等传统
`ssh.service` 系统不受影响。

若这一步缺失，24.04 上改端口不会生效，叠加 UFW 只放行新端口，会把主机锁死——这正是本测试覆盖
24.04 的原因。切端口后请始终用目标用户 SSH 到 `MANAGED_SSH_PORT` 验证，`multipass exec` 依赖 22 端口，
切换后会超时属预期。UFW 通过托管应用 profile 收敛，`ufw status` 只显示 profile 名，断言端口请用
`ufw app info DevOpsToolkit`。

## 运行

宿主机需要已经具备 Multipass、Ansible、SSH、Python 3，以及仓库声明的 Ansible collections。
脚本不会安装这些宿主机依赖。

```bash
./tests/multipass-smoke.sh run
```

默认行为：

- 创建 `devops-toolkit-2204-test-*` 和 `devops-toolkit-2404-test-*`；
- 验证实例版本、Apple Silicon 架构、联网和宿主项目标记文件传输；
- 生成一次性 SSH 密钥并配置 root bootstrap 入口；
- 创建 `devops_test`，将 SSH 从 22 切到 2222，并验证 UFW 未锁死连接；
- 安装并检查 Docker 和 Nginx；
- 第二次执行必须满足 `changed=0`、`unreachable=0`、`failed=0`；
- 全部成功后自动清理临时实例；失败时保留实例、测试密钥和日志，并输出清理命令。

保留成功现场：

```bash
./tests/multipass-smoke.sh run --keep
```

额外验证 uv 固定产物下载、SHA256 校验和安装：

```bash
./tests/multipass-smoke.sh run --with-uv
```

验证受控 uv 镜像入口：

```bash
DEVOPS_TOOLKIT_UV_RELEASE_BASE_URL="https://可信镜像.example/astral-sh/uv/releases/download/0.9.18" \
  ./tests/multipass-smoke.sh run --with-uv
```

镜像目录必须包含仓库当前 `uv_artifacts` 对应的文件；下载后仍执行固定 SHA256 校验。

如果 Mac 使用仅监听本机的代理，且 Multipass VM 受到 Fake-IP DNS 影响，可以先通过临时 TCP 转发
向 VM 暴露一个无认证的 HTTP 代理，再执行：

```bash
MULTIPASS_TEST_PROXY="http://192.168.252.1:7898" \
  ./tests/multipass-smoke.sh run --with-uv
```

该变量只会在一次性 VM 中写入测试用 `/etc/environment` 和 apt 配置，不会修改宿主机代理配置。代理
只能使用不含凭据的 `http://host:port`；测试结束后实例会被删除。

在一次性实例中额外执行系统故障注入：

```bash
./tests/multipass-smoke.sh run --with-faults
```

该模式验证无效 sshd 配置在重启前失败、陈旧 UFW profile 在启用默认拒绝前原地收敛、旧 Docker `.list`
源在任何 apt 操作前移除，以及账户创建完成后发生受控中断时，完整重跑和第二次执行仍能达到
`changed=0`。故障模式不会在非 `*-test-*` 实例上切换 SSH 端口；不要把这组测试手工复制到长期服务器。

`--with-uv` 依赖 VM 能稳定访问 GitHub Release assets；默认系统级测试不启用它，避免下载波动掩盖
SSH、UFW、Docker、Nginx 和幂等性结果。`--with-faults` 本身不启用 uv。

只读检查未切换 SSH 端口的实例：

```bash
./tests/multipass-smoke.sh check devops-toolkit-2204 devops-toolkit-2404
```

安全清理脚本生成的临时实例：

```bash
multipass list
./tests/multipass-smoke.sh cleanup \
  devops-toolkit-2204-test-YYYYMMDDhhmmss-PID \
  devops-toolkit-2404-test-YYYYMMDDhhmmss-PID
```

`cleanup` 会拒绝任何不符合临时命名规则的实例。

## CI 评估

当前不把完整 Multipass 测试接入 GitHub-hosted runner：它依赖 macOS 虚拟化、长时间系统包下载和 SSH
端口切换，执行时间与网络稳定性均不适合作为每次提交的阻塞门禁。现有 CI 继续承担语法、lint、secret
scan 和轻量单元验证。

如后续配置专用 Apple Silicon self-hosted runner，可新增手动或定期工作流，仅运行临时实例模式，并设置：

- 独占 runner，避免多个虚拟化任务争抢资源；
- workflow/job 超时和并发锁；
- `always()` 清理步骤，只匹配本次 run id 对应的临时实例；
- GitHub 与 Docker 下载失败的有限重试；
- 保留失败日志，但不上传一次性私钥。
