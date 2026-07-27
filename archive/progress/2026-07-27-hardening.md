# 2026-07-27 发布前加固与真实环境验证

本文记录从活跃 TODO 移出的已完成工作。当前剩余项以仓库根目录
[`TODO.md`](../../TODO.md) 为准。

## Multipass 验证

测试环境为 macOS Apple Silicon、Multipass 1.16.3、ansible-core 2.21.1；目标为一次性 Ubuntu 22.04.5
和 24.04.4 ARM64 实例。

- 两个版本均完成首次 bootstrap、SSH 22 → 2222、Docker、Nginx、UFW 和目标用户验证。
- 两个版本第二次执行均为 `changed=0`、`unreachable=0`、`failed=0`。
- uv 通过受控 `DEVOPS_TOOLKIT_UV_RELEASE_BASE_URL` 下载，并继续校验仓库固定 SHA256；修复了归档目录名
  解析和精确版本输出导致的重复安装。
- 故障注入覆盖无效 sshd 配置、陈旧 UFW application profile、冲突 Docker `.list` 源和账户创建后的受控
  中断；恢复后再次执行仍为 `changed=0`。
- 24.04 继续验证 `ssh.socket` override；22.04 继续验证传统 `ssh.service`。

测试结束后所有临时实例和宿主临时代理均已清理。

## 真实 Ubuntu 22.04 暴露的问题

在一台已有 Docker/UFW 历史配置的 22.04 测试服务器上，干净 VM 没有覆盖到的迁移边界被实际触发：

1. UFW 0.36.1 的多端口 application rule 在 IPv4/IPv6 半迁移状态下，重复 `allow` 或删除会报错，且其
   “已回滚”提示不可靠。角色现在先检测已有受管 allow rule，存在时只执行 `ufw app update` 原地收敛；
   新规则才执行 `allow`。管理员已有手工规则保持不变。
2. 旧 `/etc/apt/sources.list.d/docker.list` 使用 `docker.gpg`，与受管 deb822 `docker.sources` 的
   `docker.asc` 产生 `Signed-By` 冲突。迁移任务现在作为 Ubuntu play 的 pre-task，在任何 apt 操作前只删除
   指向 Docker 官方 Ubuntu 源的旧 `.list` 行，并在 Docker 角色内再次防御。
3. 新建“仅密钥 + NOPASSWD”用户后若后续任务失败，重跑时账户已存在，旧向导会默认关闭并删除受管
   NOPASSWD。bootstrap 向导现在每次显式询问该高权限选项，始终默认关闭且不记忆。

## 真实 Ubuntu 22.04 完整验收

在包含上述修复的候选包上完成了两条完整链路：

- 服务器内以 sudo/root 启动本地向导，配置 `Shell + Git + uv + Docker + Nginx + UFW + SSH`；首次完整
  执行为 `changed=21`，目标用户通过密钥登录、`sudo -n`、Docker 组、uv、服务和 UFW 检查，第二次执行
  为 `changed=0`、`unreachable=0`、`failed=0`。
- 从 macOS 控制端使用 SSH config alias 连接远程 root，创建另一个仅密钥用户并配置相同组件；从中断点恢复
  后完整执行为 `changed=14`，目标用户登录与权限检查通过，第二次执行为 `changed=0`、
  `unreachable=0`、`failed=0`。
- 远程链路发现 delegated `wait_for` 会把 SSH alias 当作 DNS 名称，虽然 Ansible 已能连接，端口验证仍会
  误超时。角色现先切换 `ansible_port`，再使用连接插件级 `wait_for_connection`，因此同时兼容普通主机名、
  SSH alias 与 ProxyJump；静态验证会阻止退回裸 TCP `wait_for`。

## 其他维护修复

- Ansible facts 改用 `ansible_facts[...]`，消除新版本 Ansible 的变量注入弃用警告，同时保持 2.12 下限。
- SSH 新端口使用 `wait_for_connection` 做端到端验证，尊重 inventory 和 OpenSSH 连接配置。
- Release tar 使用 `--no-xattrs`，避免 macOS 扩展属性进入 Linux 解包输出。
- Multipass 测试改用文件传输，不再因 `multipass mount` 隐式依赖 Snap Store。

## 新发现的剩余网络边界

当前安装器仍在目标主机运行 `ansible-galaxy collection install`。受限网络下即使 GitHub Release、Cosign
和 uv 都有受控镜像，Galaxy 仍可能长时间阻塞，是发布前应消除的最后一个主要下载单点。推荐把固定版本
collections 在 Release workflow 中打入最终签名 tarball。
