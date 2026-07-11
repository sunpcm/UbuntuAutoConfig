# 发布流程

本文是发布操作手册。发布产物的安全模型（SHA256 + Sigstore 双重校验、GitHub 加固）见
[发布供应链安全](SUPPLY_CHAIN_SECURITY.md)。

## 一条铁律

**绝不要在 GitHub 网页上手动创建 Release。** `release.yml` 工作流由推送 `v*` tag 触发，
它会**自己创建 Release 并上传资产**（`devops-toolkit.tar.gz` 及其 `.sha256`、`.sigstore.json`）。

如果你先手动建了同名 Release，工作流最后一步 `gh release create` 会因
`a release with the same tag name already exists` 失败——**前面的构建和签名都成功，但资产不会上传**，
于是 Release 是空的，`install.sh` 下载不到产物，装不了。

## 发布前检查

```bash
git fetch origin
git switch main && git pull --ff-only
./tests/verify-ansible.sh          # release.yml 的门禁就是它
git status --short                 # 应为空
```

`release.yml` 只依赖 `verify-ansible.sh`，**不依赖 env-check 的 quality 作业**。所以 main 的 Validate
徽章红着（例如 ansible-lint 历史欠债）也能发布，但推荐先让它绿。

## 发布步骤

只做两件事：打 tag、推 tag。

```bash
# 版本号遵循 vMAJOR.MINOR.PATCH
git tag -a v0.1.2 origin/main -m "DevOpsToolkit v0.1.2"
git push origin v0.1.2
```

推荐用签名 tag（需先配置 GPG/SSH signing key）：

```bash
git tag -s v0.1.2 origin/main -m "DevOpsToolkit v0.1.2"
```

推送后工作流会：`verify-ansible.sh` → 构建固定名产物 → Cosign 用 GitHub OIDC 签名 →
自校验 Sigstore 身份与打包版本 → 创建 Release 并上传三个资产。

## 发布后验证

```bash
gh run watch $(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')
gh release view v0.1.2 --json assets -q '.assets[].name'
```

必须看到三个资产：

```
devops-toolkit.tar.gz
devops-toolkit.tar.gz.sha256
devops-toolkit.tar.gz.sigstore.json
```

再模拟安装器的 latest 下载确认可达：

```bash
curl -fsSL -o /dev/null -w "%{http_code}\n" \
  https://github.com/sunpcm/DevOpsToolkit/releases/latest/download/devops-toolkit.tar.gz
```

## 失败后的恢复

若 Release 工作流失败或产物缺失（例如误建过同名 Release）：

```bash
# 删掉坏 Release 及其 tag（本地 + 远端）
gh release delete v0.1.2 --yes --cleanup-tag
git fetch --prune --prune-tags origin
git tag -d v0.1.2 2>/dev/null

# 修好原因后，从 main 重新打 tag 并只推 tag（依旧不要手动建 Release）
git tag -a v0.1.2 origin/main -m "DevOpsToolkit v0.1.2"
git push origin v0.1.2
```

## 安装（发布成功后）

服务器初始化「建用户 + 配置系统」**必须以 root 运行**（普通用户是 `--user` 模式，不会建用户也不提权）：

```bash
sudo /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/main/install.sh)"
# 固定版本：追加 -- --version v0.1.2
```

安装器会同时校验 SHA256 与 Sigstore 身份，任一失败都不会降级安装。
