# 发布供应链安全

DevOpsToolkit 的 Release 使用两层校验：

1. SHA256 检查下载是否完整，并阻止同版本内容静默变化。
2. Sigstore/Cosign 验证产物确实由本仓库的 Release workflow 在对应 tag 上通过 GitHub OIDC 签名。

Release 包含三个固定名称资产：

- `devops-toolkit.tar.gz`
- `devops-toolkit.tar.gz.sha256`
- `devops-toolkit.tar.gz.sigstore.json`

## 自动签名链路

`.github/workflows/release.yml` 只在 `v*` tag 上运行，并获得最小的 `contents: write` 与 `id-token: write` 权限。流程会：

1. 在无发布权限的 job 中验证源码。
2. 验证通过后，在全新 runner 上重新 checkout 同一 tag；构建 job 不安装 PyPI 或 Ansible Galaxy 依赖。
3. 下载固定版本 Cosign，使用仓库内固定的 SHA256 校验二进制。
4. 通过 GitHub Actions OIDC 获取短期身份，不使用长期签名私钥或 GitHub Secret。
5. 将证书、签名和透明日志证明写入 Sigstore bundle。
6. 在上传 Release 前立即验证签名身份。

安装器也会下载固定版本 Cosign，并用内置的平台 SHA256 校验。验证条件不是“存在一个合法签名”即可，而是同时要求：

- OIDC issuer 为 `https://token.actions.githubusercontent.com`。
- 仓库为 `sunpcm/DevOpsToolkit`。
- workflow 为 `.github/workflows/release.yml`。
- workflow ref 与包内版本对应的 `refs/tags/v*` 完全一致。
- 触发事件为 `push`。

任何条件不匹配都会在发布版本目录和切换 `current` 之前失败。

## 必须手工完成的 GitHub 设置

代码无法替你修改以下账号和仓库控制面。首次发布前应逐项完成。

### 1. 保护 GitHub 账号

- 开启双因素认证，优先使用 Passkey 或硬件安全密钥。
- 下载并离线保存恢复代码。
- 删除不再使用的 Personal Access Token、SSH key、OAuth App 和 GitHub App 授权。
- 日常操作优先使用细粒度、短有效期 Token，避免 classic PAT。

### 2. 创建 `release` Environment

进入仓库：

`Settings` → `Environments` → `New environment` → 输入 `release`

建议设置：

- Required reviewers：至少一名可信维护者。
- Prevent self-review：有第二名维护者时开启；单人仓库开启后会无法自行发布。
- Deployment branches and tags：只允许受保护的 `v*` tags。

Release workflow 已引用该 Environment。Environment 不需要配置 Cosign 私钥或 Secret。

必须在推送首个 `v*` tag 前完成这一步，否则发布 job 可能等待审批或因 Environment 策略不完整而无法发布。

### 3. 保护 `main`

在 `Settings` → `Rules` → `Rulesets` 新建分支规则，目标为默认分支：

- Require a pull request before merging。
- 至少 1 个 approval，并开启 Dismiss stale approvals。
- Require status checks，选择 Validate workflow 的两个 Ansible 矩阵任务。
- Require conversation resolution。
- Block force pushes 和 deletions。
- 建议 Require signed commits 与 linear history。
- 不允许常规维护者绕过规则；保留受控的紧急恢复账号。

如果仓库只有一名维护者，强制他人 approval 会阻塞日常开发。可以先保留 required checks、禁止 force push，并尽快增加第二名可信 reviewer。

### 4. 保护 Release tags

新建 tag ruleset，目标模式为 `v*`：

- 限制创建权限到仓库管理员或发布角色。
- 禁止更新和删除已经推送的 tag。
- 如果仓库设置中提供 immutable releases，建议开启。

发布后不要复用版本号。需要修复时创建新版本，例如 `v0.1.1`。

### 5. 收紧 Actions

进入 `Settings` → `Actions` → `General`：

- Workflow permissions 默认设为 Read repository contents。
- 不需要时关闭 Allow GitHub Actions to create and approve pull requests。
- 只允许 GitHub 官方和经过审核的 Actions。

本项目引用的 GitHub Actions 已固定到完整 commit SHA，避免上游移动 tag 后改变执行代码。

## 手工验证 Release

以下流程需要 GitHub CLI 和 Cosign。先确认命令可用；Cosign 应从 [Sigstore 官方 Release](https://github.com/sigstore/cosign/releases)安装并核对官方 checksum：

```bash
gh --version
cosign version
```

下载同一版本的三个资产：

```bash
VERSION=v0.1.4
gh release download "${VERSION}" \
  --repo sunpcm/DevOpsToolkit \
  --pattern 'devops-toolkit.tar.gz*' \
  --dir "/tmp/devops-toolkit-${VERSION}"
cd "/tmp/devops-toolkit-${VERSION}"
```

先检查 SHA256：

```bash
sha256sum --check devops-toolkit.tar.gz.sha256
```

macOS 使用：

```bash
shasum -a 256 --check devops-toolkit.tar.gz.sha256
```

再验证精确的 GitHub Actions 身份：

```bash
cosign verify-blob \
  --bundle devops-toolkit.tar.gz.sigstore.json \
  --certificate-identity \
    "https://github.com/sunpcm/DevOpsToolkit/.github/workflows/release.yml@refs/tags/${VERSION}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository sunpcm/DevOpsToolkit \
  --certificate-github-workflow-ref "refs/tags/${VERSION}" \
  --certificate-github-workflow-trigger push \
  devops-toolkit.tar.gz
```

只有两项验证都通过时才应手工解包或安装。

## 发布前检查

推送 tag 前执行：

```bash
./tests/verify-ansible.sh
git status --short
git log -1 --show-signature
```

确认工作区为空、测试通过，并核对 tag 指向：

```bash
VERSION=v0.1.5  # 示例；必须换成尚未使用的新版本
git tag -s "${VERSION}" -m "DevOpsToolkit ${VERSION}"
git show --show-signature "${VERSION}"
git push origin "${VERSION}"
```

`git tag -s` 需要提前配置 GPG 或 SSH signing key。不要在签名验证失败时改用未签名 tag 绕过规则。

## 仍然存在的边界

- Sigstore 证明“哪个 workflow 在哪个 tag 上构建了文件”，不证明源码没有恶意逻辑。
- 如果攻击者同时取得 `main`、tag、Environment 审批和 Actions 配置权限，仍可能发布带合法签名的恶意新版本。
- 安装器本身来自可变的 `main`。高安全环境应先固定并审查安装器提交：

```bash
INSTALLER_COMMIT="替换为已审查的完整提交 SHA"
curl -fsSLo /tmp/devops-toolkit-install.sh \
  "https://raw.githubusercontent.com/sunpcm/DevOpsToolkit/${INSTALLER_COMMIT}/install.sh"
less /tmp/devops-toolkit-install.sh
/bin/bash /tmp/devops-toolkit-install.sh --version v0.1.4
```

- Cosign 信任根和透明日志验证需要网络。网络受限时安装器会安全失败，不会降级为只检查 SHA256。
