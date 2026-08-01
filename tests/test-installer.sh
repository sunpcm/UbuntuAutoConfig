#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  if [[ -n "${DEVOPS_TOOLKIT_TEST_KEEP_TMP:-}" ]]; then
    echo "保留测试目录：${TMP_DIR}" >&2
  else
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "错误：$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

make_release() {
  local version="$1" output_dir="$2"
  local collection_mode="${3:-bundled}"
  local stage="${TMP_DIR}/stage-${version}"
  rm -rf "${stage}" "${output_dir}"
  mkdir -p "${stage}/devops-toolkit/bin" "${stage}/devops-toolkit/ansible"
  printf '%s\n' "${version}" >"${stage}/devops-toolkit/VERSION"
  cat >"${stage}/devops-toolkit/bin/devops-toolkit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_PATH}" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
  SCRIPT_PATH="$(readlink "${SCRIPT_PATH}")"
  [[ "${SCRIPT_PATH}" == /* ]] || SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done
ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
if [[ "${1:-}" == "--version" ]]; then
  cat "${ROOT}/VERSION"
  exit 0
fi
if [[ "${1:-}" == "--help" ]]; then
  echo "fixture help"
  exit 0
fi
if [[ -n "${DEVOPS_TOOLKIT_TEST_RUN_MARKER:-}" ]]; then
  : >"${DEVOPS_TOOLKIT_TEST_RUN_MARKER}"
fi
EOF
  chmod +x "${stage}/devops-toolkit/bin/devops-toolkit"
  cat >"${stage}/devops-toolkit/ansible/requirements.yml" <<'EOF'
---
collections: []
EOF
  if [[ "${collection_mode}" != "legacy" ]]; then
    mkdir -p \
      "${stage}/devops-toolkit/collections/ansible_collections/ansible/posix" \
      "${stage}/devops-toolkit/collections/ansible_collections/community/general"
    printf '%s\n' \
      '{"collection_info":{"namespace":"ansible","name":"posix","version":"1.5.4"}}' \
      >"${stage}/devops-toolkit/collections/ansible_collections/ansible/posix/MANIFEST.json"
    printf '%s\n' \
      '{"collection_info":{"namespace":"community","name":"general","version":"7.5.2"}}' \
      >"${stage}/devops-toolkit/collections/ansible_collections/community/general/MANIFEST.json"
    printf '%s\n' 'ansible.posix=1.5.4' 'community.general=7.5.2' \
      >"${stage}/devops-toolkit/collections/.bundled-collections"
    if [[ "${collection_mode}" == "invalid-bundle" ]]; then
      printf '%s\n' \
        '{"collection_info":{"namespace":"community","name":"general","version":"9.9.9"}}' \
        >"${stage}/devops-toolkit/collections/ansible_collections/community/general/MANIFEST.json"
    fi
  fi
  mkdir -p "${output_dir}"
  COPYFILE_DISABLE=1 tar -C "${stage}" -czf "${output_dir}/devops-toolkit.tar.gz" devops-toolkit
  printf '%s  devops-toolkit.tar.gz\n' \
    "$(sha256_file "${output_dir}/devops-toolkit.tar.gz")" \
    >"${output_dir}/devops-toolkit.tar.gz.sha256"
  printf '{"fixture":"%s"}\n' "${version}" \
    >"${output_dir}/devops-toolkit.tar.gz.sigstore.json"
}

make_unsafe_release() {
  local output_dir="$1"
  mkdir -p "${output_dir}"
  python3 - "${output_dir}/devops-toolkit.tar.gz" <<'PY'
import io
import tarfile
import sys

with tarfile.open(sys.argv[1], "w:gz") as archive:
    data = b"escape"
    member = tarfile.TarInfo("../escape")
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))
PY
  printf '%s  devops-toolkit.tar.gz\n' \
    "$(sha256_file "${output_dir}/devops-toolkit.tar.gz")" \
    >"${output_dir}/devops-toolkit.tar.gz.sha256"
}

MOCK_BIN="${TMP_DIR}/mock-bin"
mkdir -p "${MOCK_BIN}"
cat >"${MOCK_BIN}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo 'ansible-playbook [core 2.18.6]'
EOF
cat >"${MOCK_BIN}/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DEVOPS_TOOLKIT_TEST_GALAXY_LOG}"
[[ -z "${DEVOPS_TOOLKIT_TEST_GALAXY_FAIL:-}" ]]
EOF
chmod +x "${MOCK_BIN}/ansible-playbook" "${MOCK_BIN}/ansible-galaxy"

MOCK_COSIGN_DIR="${TMP_DIR}/mock-cosign"
mkdir -p "${MOCK_COSIGN_DIR}"
cat >"${TMP_DIR}/fake-cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DEVOPS_TOOLKIT_TEST_COSIGN_LOG}"
[[ -z "${DEVOPS_TOOLKIT_TEST_COSIGN_FAIL:-}" ]]
EOF
chmod +x "${TMP_DIR}/fake-cosign"
for asset in cosign-darwin-amd64 cosign-darwin-arm64 cosign-linux-amd64 cosign-linux-arm64; do
  cp "${TMP_DIR}/fake-cosign" "${MOCK_COSIGN_DIR}/${asset}"
done

export PATH="${MOCK_BIN}:${PATH}"
export HOME="${TMP_DIR}/home"
export DEVOPS_TOOLKIT_TEST_GALAXY_LOG="${TMP_DIR}/galaxy.log"
export DEVOPS_TOOLKIT_TEST_COSIGN_LOG="${TMP_DIR}/cosign.log"
: >"${DEVOPS_TOOLKIT_TEST_GALAXY_LOG}"
FAKE_COSIGN_SHA256="$(sha256_file "${TMP_DIR}/fake-cosign")"
INSTALLER="${TMP_DIR}/test-install.sh"
cat >"${INSTALLER}" <<EOF
#!/usr/bin/env bash
source "${ROOT_DIR}/install.sh"
cosign_download_base() { printf '%s\\n' 'file://${MOCK_COSIGN_DIR}'; }
cosign_expected_sha256() {
  printf '%s\\n' "\${DEVOPS_TOOLKIT_TEST_EXPECTED_COSIGN_SHA256:-${FAKE_COSIGN_SHA256}}"
}
main "\$@"
EOF
chmod +x "${INSTALLER}"
mkdir -p "${HOME}"

RELEASE_V1="${TMP_DIR}/release-v1"
RELEASE_V2="${TMP_DIR}/release-v2"
RELEASE_LEGACY="${TMP_DIR}/release-legacy"
RELEASE_INVALID_BUNDLE="${TMP_DIR}/release-invalid-bundle"
make_release v0.1.0 "${RELEASE_V1}"
make_release v0.2.0 "${RELEASE_V2}"
make_release v0.0.9 "${RELEASE_LEGACY}" legacy
make_release v0.3.0 "${RELEASE_INVALID_BUNDLE}" invalid-bundle

DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run --version v0.1.0
[[ "$("${HOME}/.local/bin/devops-toolkit" --version)" == "v0.1.0" ]] || fail "v0.1.0 安装失败"
grep -F -- '--certificate-identity https://github.com/sunpcm/DevOpsToolkit/.github/workflows/release.yml@refs/tags/v0.1.0' \
  "${DEVOPS_TOOLKIT_TEST_COSIGN_LOG}" >/dev/null || fail "Cosign 没有校验精确 workflow 身份"
grep -F -- '--certificate-github-workflow-ref refs/tags/v0.1.0' \
  "${DEVOPS_TOOLKIT_TEST_COSIGN_LOG}" >/dev/null || fail "Cosign 没有校验 tag ref"
"${HOME}/.local/bin/devops-toolkit" --help >/dev/null
python3 - "${HOME}" <<'PY'
import stat
import sys
from pathlib import Path

home = Path(sys.argv[1])
launcher = home / ".local/bin/devops-toolkit"
current = home / ".local/share/devops-toolkit/current"
release = home / ".local/share/devops-toolkit/releases/v0.1.0/bin/devops-toolkit"
assert launcher.is_symlink()
assert current.is_symlink()
assert stat.S_IMODE(launcher.lstat().st_mode) & 0o055 == 0o055
assert stat.S_IMODE(current.lstat().st_mode) & 0o055 == 0o055
assert stat.S_IMODE(release.stat().st_mode) == 0o755
assert stat.S_IMODE((release.parents[1] / ".release-sha256").stat().st_mode) == 0o600
assert stat.S_IMODE(release.parents[1].stat().st_mode) == 0o755
PY

# Reinstalling the same verified version must keep working without a duplicate release.
DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run --version v0.1.0
[[ "$(find "${HOME}/.local/share/devops-toolkit/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == "1" ]] || \
  fail "重复安装产生了重复版本目录"
[[ "$(wc -l <"${DEVOPS_TOOLKIT_TEST_GALAXY_LOG}" | tr -d ' ')" == "0" ]] || \
  fail "内置 collections 的安装或重复安装仍调用了 Galaxy"

# A tampered Cosign cache must be replaced from the pinned, verified source.
COSIGN_CACHE="$(find "${HOME}/.local/share/devops-toolkit/tools" -type f -name 'cosign-v3.1.1-*' -print -quit)"
[[ -n "${COSIGN_CACHE}" ]] || fail "没有创建 Cosign 缓存"
printf 'tampered\n' >"${COSIGN_CACHE}"
DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run --version v0.1.0
[[ "$(sha256_file "${COSIGN_CACHE}")" == "${FAKE_COSIGN_SHA256}" ]] || \
  fail "被篡改的 Cosign 缓存未被修复"

# Updating switches current while retaining the previous release.
DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V2}" \
  "${INSTALLER}" --user --no-run
[[ "$("${HOME}/.local/bin/devops-toolkit" --version)" == "v0.2.0" ]] || fail "升级切换失败"
[[ -d "${HOME}/.local/share/devops-toolkit/releases/v0.1.0" ]] || fail "旧版本未保留"

# A version mismatch must fail before switching current.
if DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V2}" \
  "${INSTALLER}" --user --no-run --version v0.1.0 >/dev/null 2>&1; then
  fail "版本不匹配未被拒绝"
fi
[[ "$("${HOME}/.local/bin/devops-toolkit" --version)" == "v0.2.0" ]] || fail "失败安装改变了 current"

# Bad and missing checksums must fail without changing current.
BAD_CHECKSUM="${TMP_DIR}/bad-checksum"
cp -R "${RELEASE_V2}" "${BAD_CHECKSUM}"
printf '%064d  devops-toolkit.tar.gz\n' 0 >"${BAD_CHECKSUM}/devops-toolkit.tar.gz.sha256"
if DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${BAD_CHECKSUM}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "错误 checksum 未被拒绝"
fi
MISSING_CHECKSUM="${TMP_DIR}/missing-checksum"
mkdir -p "${MISSING_CHECKSUM}"
cp "${RELEASE_V2}/devops-toolkit.tar.gz" "${MISSING_CHECKSUM}/"
if DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${MISSING_CHECKSUM}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "缺失 checksum 未被拒绝"
fi

# Unsafe archive entries must be rejected.
UNSAFE_RELEASE="${TMP_DIR}/unsafe-release"
make_unsafe_release "${UNSAFE_RELEASE}"
if DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${UNSAFE_RELEASE}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "危险 tar 路径未被拒绝"
fi
[[ ! -e "${TMP_DIR}/escape" ]] || fail "危险 tar 写出了目标目录"

# A missing bundle, bad Cosign bootstrap hash, or failed identity must stop before publication.
MISSING_BUNDLE="${TMP_DIR}/missing-bundle"
cp -R "${RELEASE_V1}" "${MISSING_BUNDLE}"
rm "${MISSING_BUNDLE}/devops-toolkit.tar.gz.sigstore.json"
if HOME="${TMP_DIR}/missing-bundle-home" \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${MISSING_BUNDLE}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "缺失 Sigstore bundle 未被拒绝"
fi

if HOME="${TMP_DIR}/bad-cosign-home" DEVOPS_TOOLKIT_TEST_EXPECTED_COSIGN_SHA256="$(printf '%064d' 0)" \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "错误 Cosign checksum 未被拒绝"
fi
[[ ! -e "${TMP_DIR}/bad-cosign-home/.local/share/devops-toolkit/current" ]] || \
  fail "Cosign 引导校验失败后切换了 current"

if HOME="${TMP_DIR}/bad-signature-home" DEVOPS_TOOLKIT_TEST_COSIGN_FAIL=1 \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run >/dev/null 2>&1; then
  fail "错误 Sigstore 身份未被拒绝"
fi
[[ ! -e "${TMP_DIR}/bad-signature-home/.local/share/devops-toolkit/current" ]] || \
  fail "Sigstore 验证失败后切换了 current"

# A bundled release must install even when Galaxy is unavailable.
OFFLINE_HOME="${TMP_DIR}/offline-home"
mkdir -p "${OFFLINE_HOME}"
HOME="${OFFLINE_HOME}" DEVOPS_TOOLKIT_TEST_GALAXY_FAIL=1 \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user --no-run --version v0.1.0 >/dev/null
[[ "$("${OFFLINE_HOME}/.local/bin/devops-toolkit" --version)" == "v0.1.0" ]] || \
  fail "Galaxy 不可用时未能安装内置 collections 的 Release"

# A bundle marker cannot hide a missing, extra, or wrong manifest version.
INVALID_BUNDLE_HOME="${TMP_DIR}/invalid-bundle-home"
mkdir -p "${INVALID_BUNDLE_HOME}"
if HOME="${INVALID_BUNDLE_HOME}" \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_INVALID_BUNDLE}" \
  "${INSTALLER}" --user --no-run --version v0.3.0 >/dev/null 2>&1; then
  fail "安装器接受了与标记不一致的 collection manifest"
fi
[[ ! -e "${INVALID_BUNDLE_HOME}/.local/share/devops-toolkit/current" ]] || \
  fail "内置 collection 校验失败后切换了 current"

# Legacy releases keep the runtime Galaxy compatibility path.
LEGACY_HOME="${TMP_DIR}/legacy-home"
mkdir -p "${LEGACY_HOME}"
galaxy_before="$(wc -l <"${DEVOPS_TOOLKIT_TEST_GALAXY_LOG}" | tr -d ' ')"
HOME="${LEGACY_HOME}" DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_LEGACY}" \
  "${INSTALLER}" --user --no-run --version v0.0.9 >/dev/null
galaxy_after="$(wc -l <"${DEVOPS_TOOLKIT_TEST_GALAXY_LOG}" | tr -d ' ')"
[[ "$((galaxy_after - galaxy_before))" == "1" ]] || \
  fail "旧版 Release 没有调用 Galaxy 兼容安装"

# A legacy collection failure must not publish or activate a partial version.
FAILED_HOME="${TMP_DIR}/failed-home"
mkdir -p "${FAILED_HOME}"
if HOME="${FAILED_HOME}" DEVOPS_TOOLKIT_TEST_GALAXY_FAIL=1 \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_LEGACY}" \
  "${INSTALLER}" --user --no-run --version v0.0.9 >/dev/null 2>&1; then
  fail "collection 安装失败未传递错误"
fi
[[ ! -e "${FAILED_HOME}/.local/share/devops-toolkit/current" ]] || fail "失败安装切换了 current"
[[ ! -e "${FAILED_HOME}/.local/share/devops-toolkit/releases/v0.0.9" ]] || fail "失败安装发布了不完整版本"

# Non-TTY execution installs but never starts the wizard.
NON_TTY_HOME="${TMP_DIR}/non-tty-home"
mkdir -p "${NON_TTY_HOME}"
NON_TTY_MARKER="${TMP_DIR}/non-tty-ran"
HOME="${NON_TTY_HOME}" DEVOPS_TOOLKIT_TEST_RUN_MARKER="${NON_TTY_MARKER}" \
  DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
  "${INSTALLER}" --user </dev/null
[[ ! -e "${NON_TTY_MARKER}" ]] || fail "非 TTY 错误启动了向导"

# A pseudo-terminal triggers the wizard after installation.
TTY_HOME="${TMP_DIR}/tty-home"
TTY_MARKER="${TMP_DIR}/tty-ran"
mkdir -p "${TTY_HOME}"
HOME="${TTY_HOME}" DEVOPS_TOOLKIT_TEST_RUN_MARKER="${TTY_MARKER}" \
DEVOPS_TOOLKIT_DOWNLOAD_BASE="file://${RELEASE_V1}" \
python3 - "${INSTALLER}" <<'PY'
import os
import pty
import sys

status = pty.spawn([sys.argv[1], "--user"])
raise SystemExit(os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status)
PY
[[ -e "${TTY_MARKER}" ]] || fail "TTY 安装后未启动向导"

# Dependency policy: user mode never calls apt; system mode uses only the whitelist.
APT_LOG="${TMP_DIR}/apt.log"
if (
  source "${ROOT_DIR}/install.sh"
  INSTALL_MODE=user
  missing_core_commands() { echo ansible-playbook; }
  run_apt_get() { echo "$*" >>"${APT_LOG}"; }
  ensure_dependencies
) >/dev/null 2>&1; then
  fail "普通用户缺少依赖时未失败"
fi
[[ ! -e "${APT_LOG}" ]] || fail "普通用户模式调用了 apt"

(
  source "${ROOT_DIR}/install.sh"
  INSTALL_MODE=system
  marker="${TMP_DIR}/deps-installed"
  missing_core_commands() {
    [[ -e "${marker}" ]] || echo ansible-playbook
    return 0
  }
  apt_get_available() { return 0; }
  run_apt_get() {
    echo "$*" >>"${APT_LOG}"
    [[ "${1:-}" == install ]] && : >"${marker}"
    return 0
  }
  ensure_dependencies
)
grep -Fx 'update' "${APT_LOG}" >/dev/null
grep -Fx 'install -y ansible python3 python3-pip git curl ca-certificates openssl sshpass' "${APT_LOG}" >/dev/null

# apt 的 ansible 版本过低时，系统模式改用 pip 安装 ansible-core。
PIP_LOG="${TMP_DIR}/pip.log"
(
  source "${ROOT_DIR}/install.sh"
  # 起始不达标；模拟 pip 安装后达标。
  ansible_core_meets_requirement() { [[ -e "${TMP_DIR}/pip-done" ]]; }
  pip_install_ansible_core() { echo called >>"${PIP_LOG}"; : >"${TMP_DIR}/pip-done"; }
  ensure_ansible_core
)
[[ -s "${PIP_LOG}" ]] || fail "ansible-core 版本过低时未触发 pip 安装"

"${ROOT_DIR}/install.sh" --help >/dev/null
echo "安装器测试通过。"
