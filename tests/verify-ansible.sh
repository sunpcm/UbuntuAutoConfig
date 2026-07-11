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
  "${ROOT_DIR}/wsl-dev/bootstrap.sh" \
  "${ROOT_DIR}/ubuntu-server/bootstrap.sh"

python3 -c 'import sys; from pathlib import Path; p=Path(sys.argv[1]); compile(p.read_text(), str(p), "exec")' \
  "${ROOT_DIR}/bin/devops-toolkit"
python3 -c 'import runpy, stat, sys; from pathlib import Path; m=runpy.run_path(sys.argv[1]); p=Path(sys.argv[2]); m["secure_write"](p, "{}\n"); assert stat.S_IMODE(p.stat().st_mode) == 0o600' \
  "${ROOT_DIR}/bin/devops-toolkit" "${TMP_DIR}/sensitive-vars.json"
python3 "${ROOT_DIR}/tests/test-wizard.py"
"${ROOT_DIR}/bin/devops-toolkit" --help >/dev/null
[[ "$("${ROOT_DIR}/bin/devops-toolkit" --version)" == "development" ]]
"${ROOT_DIR}/tests/test-installer.sh"
"${ROOT_DIR}/tests/test-release.sh"

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

if [[ -d "${ROOT_DIR}/ubuntu-server/ansible" || -d "${ROOT_DIR}/wsl-dev/ansible" ]]; then
  echo "错误：弃用的 Ansible 实现重新出现在原路径；当前只允许根目录 ansible/ 作为受支持实现。" >&2
  exit 1
fi

if grep -n 'SCRIPT_DIR.*/ansible/group_vars' \
  "${ROOT_DIR}/ubuntu-server/bootstrap.sh" \
  "${ROOT_DIR}/wsl-dev/bootstrap.sh"; then
  echo "错误：兼容入口不能读取已归档的旧变量。" >&2
  exit 1
fi

echo "统一 Ansible 入口静态验证通过。"
