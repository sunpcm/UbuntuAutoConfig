#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat >"${TMP_DIR}/inventory.ini" <<'EOF'
[ubuntu_servers]
ubuntu-test ansible_host=192.0.2.10 ansible_user=root

[user_only]
user-test ansible_host=192.0.2.11 ansible_user=developer
EOF

export ANSIBLE_CONFIG="${ROOT_DIR}/ansible/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="${TMP_DIR}/local"
export ANSIBLE_REMOTE_TEMP="/tmp/devops-toolkit-ansible"

ansible-playbook --syntax-check -i 'localhost,' "${ROOT_DIR}/ansible/playbooks/wsl-bootstrap.yml"
ansible-playbook --syntax-check -i "${TMP_DIR}/inventory.ini" \
  "${ROOT_DIR}/ansible/playbooks/ubuntu-bootstrap.yml"
ansible-playbook --syntax-check -i "${TMP_DIR}/inventory.ini" \
  "${ROOT_DIR}/ansible/playbooks/user-only.yml"
ansible-playbook --syntax-check -i "${TMP_DIR}/inventory.ini" \
  "${ROOT_DIR}/ansible/playbooks/user-only-remove.yml"

bash -n \
  "${ROOT_DIR}/bin/wsl-bootstrap" \
  "${ROOT_DIR}/bin/ubuntu-bootstrap" \
  "${ROOT_DIR}/bin/user-only" \
  "${ROOT_DIR}/bin/user-only-remove" \
  "${ROOT_DIR}/install.sh" \
  "${ROOT_DIR}/scripts/build-release.sh" \
  "${ROOT_DIR}/tests/test-installer.sh" \
  "${ROOT_DIR}/tests/test-release.sh" \
  "${ROOT_DIR}/tests/verify-idempotence.sh" \
  "${ROOT_DIR}/tests/multipass-smoke.sh"

python3 -c 'import sys; from pathlib import Path; p=Path(sys.argv[1]); compile(p.read_text(), str(p), "exec")' \
  "${ROOT_DIR}/bin/devops-toolkit"
python3 -c 'import runpy, stat, sys; from pathlib import Path; m=runpy.run_path(sys.argv[1]); p=Path(sys.argv[2]); m["secure_write"](p, "{}\n"); assert stat.S_IMODE(p.stat().st_mode) == 0o600' \
  "${ROOT_DIR}/bin/devops-toolkit" "${TMP_DIR}/sensitive-vars.json"
python3 "${ROOT_DIR}/tests/test-wizard.py"
"${ROOT_DIR}/bin/devops-toolkit" --help >/dev/null
[[ "$("${ROOT_DIR}/bin/devops-toolkit" --version)" == "development" ]]
# 主推入口是 bash -c "$(curl ... install.sh)"，此时 BASH_SOURCE 为空；
# 确保 set -u 下仍能运行 main（--help 在任何安装动作前退出）。
bash -c "$(cat "${ROOT_DIR}/install.sh")" install-sh-entrypoint --help >/dev/null
"${ROOT_DIR}/tests/test-installer.sh"
"${ROOT_DIR}/tests/test-release.sh"

if [[ "${REQUIRE_QUALITY_TOOLS:-0}" == "1" ]] && ! command -v shellcheck >/dev/null 2>&1; then
  echo "错误：REQUIRE_QUALITY_TOOLS=1，但 shellcheck 不可用。" >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck \
    "${ROOT_DIR}/install.sh" \
    "${ROOT_DIR}/scripts/build-release.sh" \
    "${ROOT_DIR}/tests/test-installer.sh" \
    "${ROOT_DIR}/tests/test-release.sh"
fi

if grep -R -nE 'apt_key:|apt_repository:' "${ROOT_DIR}/ansible"; then
  echo "错误：统一实现中仍有已弃用的 APT 仓库模块。" >&2
  exit 1
fi

if ! grep -Fq 'download[.]docker[.]com/linux/ubuntu' \
  "${ROOT_DIR}/ansible/roles/docker/tasks/repository-cleanup.yml"; then
  echo "错误：Docker 角色没有收敛会与 deb822 Signed-By 冲突的旧 .list 源。" >&2
  exit 1
fi
if ! grep -Fq 'tasks_from: repository-cleanup' \
  "${ROOT_DIR}/ansible/playbooks/ubuntu-bootstrap.yml"; then
  echo "错误：Ubuntu bootstrap 没有在任何 apt 任务前清理冲突的旧 Docker 源。" >&2
  exit 1
fi

if grep -R -nE 'curl[^|]*\|[[:space:]]*(sh|bash)' "${ROOT_DIR}/ansible"; then
  echo "错误：Ansible 实现中仍在执行 curl pipe shell。" >&2
  exit 1
fi

if ! grep -Eq 'checksum:[[:space:]]+"sha256:' \
  "${ROOT_DIR}/ansible/roles/user_profile/tasks/main.yml"; then
  echo "错误：uv 下载没有强制 SHA256 校验。" >&2
  exit 1
fi

if ! grep -Fq 'DEVOPS_TOOLKIT_UV_RELEASE_BASE_URL' \
  "${ROOT_DIR}/ansible/group_vars/all.yml"; then
  echo "错误：uv 下载没有统一的受控镜像环境变量入口。" >&2
  exit 1
fi

if ! grep -Fq 'name: "{{ firewall_managed_profile_name }}"' \
  "${ROOT_DIR}/ansible/roles/firewall/tasks/main.yml"; then
  echo "错误：UFW 规则没有通过 DevOpsToolkit 托管 profile 收敛。" >&2
  exit 1
fi

firewall_tasks="${ROOT_DIR}/ansible/roles/firewall/tasks/main.yml"
firewall_detect_line="$(grep -n -m1 'Detect an existing DevOpsToolkit-managed allow rule' \
  "${firewall_tasks}" | cut -d: -f1)"
firewall_template_line="$(grep -n -m1 'Publish the DevOpsToolkit-owned UFW application profile' \
  "${firewall_tasks}" | cut -d: -f1)"
firewall_reconcile_line="$(grep -n -m1 'Reconcile an existing managed profile' \
  "${firewall_tasks}" | cut -d: -f1)"
firewall_allow_line="$(grep -n -m1 'Allow the managed application profile' \
  "${firewall_tasks}" | cut -d: -f1)"
if [[ -z "${firewall_detect_line}" || -z "${firewall_template_line}" || \
      -z "${firewall_reconcile_line}" || -z "${firewall_allow_line}" ]] || \
   ((firewall_detect_line >= firewall_template_line || \
      firewall_template_line >= firewall_reconcile_line || \
      firewall_reconcile_line >= firewall_allow_line)); then
  echo "错误：UFW 必须先检测旧受管规则，再发布并收敛 profile，最后才允许新 profile。" >&2
  exit 1
fi
if ! grep -Fq 'when: firewall_managed_allow_rule_exists | bool' "${firewall_tasks}" || \
   ! grep -Fq 'when: not (firewall_managed_allow_rule_exists | bool)' "${firewall_tasks}"; then
  echo "错误：UFW 旧受管规则必须原地 app update，不能重复 allow 多端口 profile。" >&2
  exit 1
fi

# 锁定 24.04 改端口修复：Ubuntu 22.10+（含 24.04）的 OpenSSH 监听端口由 ssh.socket 决定，
# 只改 sshd_config 的 Port 无效。若下列任一环节缺失，socket 激活主机改端口不会生效，叠加
# UFW 只放行新端口会把主机锁死。
ssh_security_role="${ROOT_DIR}/ansible/roles/ssh_security"
if ! grep -Eq 'ListenStream=.*ssh_port' \
  "${ssh_security_role}/templates/ssh.socket-override.conf.j2" 2>/dev/null; then
  echo "错误：ssh_security 未通过 ssh.socket 的 ListenStream 绑定托管端口；socket 激活的 Ubuntu 改 SSH 端口会失效并可能锁死主机。" >&2
  exit 1
fi
if ! grep -Fq 'ssh.socket-override.conf.j2' \
  "${ssh_security_role}/tasks/main.yml" 2>/dev/null; then
  echo "错误：ssh_security 的任务未写入 ssh.socket 端口覆盖文件。" >&2
  exit 1
fi
if ! grep -Eq 'name:[[:space:]]*ssh\.socket' \
  "${ssh_security_role}/handlers/main.yml" 2>/dev/null; then
  echo "错误：ssh_security 的 handler 未重启 ssh.socket，端口变更不会生效。" >&2
  exit 1
fi
if ! grep -Fq 'ansible.builtin.wait_for_connection:' \
  "${ssh_security_role}/tasks/main.yml" 2>/dev/null || \
   grep -Fq 'ansible.builtin.wait_for:' \
  "${ssh_security_role}/tasks/main.yml" 2>/dev/null; then
  echo "错误：SSH 端口切换必须通过 wait_for_connection 验证，避免 SSH alias 或 ProxyJump 被当作 DNS 主机名。" >&2
  exit 1
fi

if grep -R -nE 'version:[[:space:]]*(master|main)$' \
  "${ROOT_DIR}/ansible/roles"; then
  echo "错误：统一实现中仍有跟随上游分支的 Git 安装。" >&2
  exit 1
fi

if ! grep -Eq '^ohmyzsh_version:[[:space:]]+[0-9a-f]{40}$' \
  "${ROOT_DIR}/ansible/group_vars/all.yml" || \
   ! grep -Eq '^linuxbrew_version:[[:space:]]+[0-9a-f]{40}$' \
  "${ROOT_DIR}/ansible/group_vars/all.yml"; then
  echo "错误：Oh My Zsh 或 Linuxbrew 没有固定到不可变提交。" >&2
  exit 1
fi

if grep -nE 'host_key_checking[[:space:]]*=[[:space:]]*False|become[[:space:]]*=[[:space:]]*True' \
  "${ROOT_DIR}/ansible/ansible.cfg"; then
  echo "错误：统一配置重新启用了不安全的全局设置。" >&2
  exit 1
fi

if grep -R -nE \
  --exclude-dir=.git \
  --exclude='verify-ansible.sh' \
  --exclude='*.md' \
  '(ssh-(rsa|ed25519)|ecdsa-sha2-[^[:space:]]+|sk-[^[:space:]]+)[[:space:]]+AAAA[A-Za-z0-9+/]{80,}' \
  "${ROOT_DIR}"; then
  echo "错误：仓库中发现疑似真实 SSH 公钥；请改用占位符或环境专用加密变量。" >&2
  exit 1
fi

legacy_active_paths=(
  playbook.yml
  setup_wsl.yml
  host.ini.examples
  .zshrc.server
  ubuntu-server/ansible.cfg
  ubuntu-server/bootstrap.sh
  ubuntu-server/host.ini.example
  ubuntu-server/update.sh
  ubuntu-server/ServerMaintainRules
  wsl-dev/Brewfile
  wsl-dev/bootstrap.sh
  wsl-dev/uninstall.sh
  wsl-dev/update.sh
  ubuntu-server/ansible
  wsl-dev/ansible
)
for legacy_path in "${legacy_active_paths[@]}"; do
  if [[ -e "${ROOT_DIR}/${legacy_path}" ]]; then
    echo "错误：已归档的旧入口或资产重新出现在活跃路径：${legacy_path}" >&2
    exit 1
  fi
done

echo "统一 Ansible 入口静态验证通过。"
