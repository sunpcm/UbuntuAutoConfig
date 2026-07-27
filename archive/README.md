# 历史文档

本目录保存统一重构前的 WSL2、Ubuntu Server 文档、Ansible 实现与兼容入口，仅用于追溯旧版本行为。

这些文档描述的是已经弃用的目录内 Playbook、变量和入口脚本，不能作为当前版本的操作指南。

`legacy-implementations/` 是不受支持的历史快照：个人配置与高风险默认值已经清除。
2026-07-27 起，原根目录 `playbook.yml` / `setup_wsl.yml`、`wsl-dev/`、`ubuntu-server/`
中的兼容入口和旧资产也已移入本目录。不要直接执行这些脚本或 Playbook；相对路径、变量和依赖只反映
历史状态。当前唯一受支持的实现是仓库根目录的 `ansible/`，入口只在 `bin/`。

目录说明：

- `compatibility-shims/`：原根目录兼容 Playbook 与 inventory 示例。
- `legacy-implementations/`：重构前的重复 Ansible 实现。
- `ubuntu-server/`、`wsl-dev/`：旧文档、脚本和环境资产。
- `progress/`：已完成阶段的验证记录，从活跃 TODO 中移出的历史说明。

最近验证记录：

- [2026-07-27 发布前加固与真实环境验证](progress/2026-07-27-hardening.md)
- [2026-07-11 统一实现验证](progress/2026-07-11-validation.md)

当前文档：

- [项目入口](../README.md)
- [三个场景完整使用指南](../docs/GETTING_STARTED.md)
- [配置与安全说明](../docs/CONFIGURATION.md)
