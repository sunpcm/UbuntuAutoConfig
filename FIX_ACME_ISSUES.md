# ACME.sh 安装问题修复说明

## 问题描述

您在运行 `acme-init.sh` 时遇到了以下问题：
1. `sh: 4: source: not found` - shell 兼容性问题
2. `sh: 0: cannot open /tmp/tmp.Urj84YEdZN: Permission denied` - 临时文件权限问题
3. 最终 acme.sh 安装失败

## 修复内容

已对脚本进行以下修复：

### 1. Shell 兼容性修复
- 将所有 `sudo -u "$ACME_USER" -H sh -c` 改为 `sudo -u "$ACME_USER" -H bash -c`
- 将 `source` 命令改为 `. `（点命令），提高兼容性
- 添加条件检查：`if [[ -f $ACME_HOME/.profile ]]; then . $ACME_HOME/.profile; fi`

### 2. 临时文件权限修复
- 不直接使用系统临时文件
- 将安装脚本复制到 acme 用户主目录
- 设置正确的所有者和权限

### 3. 安装验证
- 添加安装后验证步骤
- 检查 acme.sh 文件是否存在
- 失败时显示详细错误信息

## 使用方法

1. **清理之前的安装**：
   ```bash
   sudo bash acme-cleanup.sh
   ```

2. **重新运行初始化**：
   ```bash
   sudo bash acme-init.sh ylspcm@gmail.com
   ```

3. **验证安装**：
   ```bash
   sudo acme-list
   ```

## 主要修改文件

- `acme-init.sh` - 主安装脚本（已修复）
- `acme-cleanup.sh` - 新增清理脚本

## 注意事项

- 确保系统有 bash shell
- 确保网络连接正常
- 如果仍有问题，请检查 `/var/lib/acme/config/install.log` 日志文件
