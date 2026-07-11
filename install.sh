#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="sunpcm/DevOpsToolkit"
readonly ARCHIVE_NAME="devops-toolkit.tar.gz"
readonly CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
readonly BUNDLE_NAME="${ARCHIVE_NAME}.sigstore.json"
readonly COSIGN_VERSION="v3.1.1"
readonly REQUIRED_ANSIBLE_MAJOR=2
readonly REQUIRED_ANSIBLE_MINOR=12
# 用范围而非精确版本：让 pip 按运行时 Python 解析可用的最高 ansible-core
# （Ubuntu 22.04 的 Python 3.10 最高 2.17，24.04 的 3.12 可到 2.18）。
readonly ANSIBLE_CORE_PIP_SPEC="ansible-core>=2.12,<2.19"

INSTALL_MODE=""
REQUESTED_VERSION="${DEVOPS_TOOLKIT_VERSION:-}"
RUN_AFTER_INSTALL=true
TEMP_DIR=""

usage() {
  cat <<'EOF'
DevOpsToolkit installer

Usage:
  install.sh [--version v0.1.0] [--no-run] [--user|--system]

Options:
  --version VERSION  Install a specific GitHub Release tag.
  --no-run           Install only; do not launch the interactive wizard.
  --user             Install below ~/.local without privilege escalation.
  --system           Install below /opt and /usr/local/bin; requires root.
  -h, --help         Show this help.

Environment:
  DEVOPS_TOOLKIT_VERSION        Alternative to --version.
  DEVOPS_TOOLKIT_DOWNLOAD_BASE  Override the release asset directory (testing/mirror).
EOF
}

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

effective_uid() {
  id -u
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || fail "--version 需要版本号。"
        REQUESTED_VERSION="$2"
        shift 2
        ;;
      --no-run)
        RUN_AFTER_INSTALL=false
        shift
        ;;
      --user|--system)
        local requested_mode="${1#--}"
        if [[ -n "${INSTALL_MODE}" && "${INSTALL_MODE}" != "${requested_mode}" ]]; then
          fail "--user 与 --system 不能同时使用。"
        fi
        INSTALL_MODE="${requested_mode}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "未知参数：$1"
        ;;
    esac
  done

  if [[ -n "${REQUESTED_VERSION}" && ! "${REQUESTED_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.-]+)?$ ]]; then
    fail "版本格式无效：${REQUESTED_VERSION}，应类似 v0.1.0。"
  fi

  if [[ -z "${INSTALL_MODE}" ]]; then
    if [[ "$(effective_uid)" -eq 0 ]]; then
      INSTALL_MODE="system"
    else
      INSTALL_MODE="user"
    fi
  fi
  if [[ "${INSTALL_MODE}" == "system" && "$(effective_uid)" -ne 0 ]]; then
    fail "--system 需要 root；请使用 sudo 或改用 --user。"
  fi
}

missing_core_commands() {
  local command_name
  for command_name in curl tar python3 ansible-playbook ansible-galaxy git openssl; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      printf '%s\n' "${command_name}"
    fi
  done
}

run_apt_get() {
  apt-get "$@"
}

apt_get_available() {
  command -v apt-get >/dev/null 2>&1
}

pip_install_ansible_core() {
  local -a pip_cmd=(python3 -m pip install --upgrade "${ANSIBLE_CORE_PIP_SPEC}")
  # PEP 668：externally-managed 环境（如 Ubuntu 24.04）需显式放行系统级安装。
  if python3 -c 'import os, sysconfig, sys; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")) else 1)'; then
    pip_cmd+=(--break-system-packages)
  fi
  "${pip_cmd[@]}"
}

ensure_ansible_core() {
  # 部分发行版（如 Ubuntu 22.04）apt 的 ansible 仅 2.10，低于要求；改用 pip 安装 ansible-core。
  if ansible_core_meets_requirement; then
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || fail "缺少 python3，无法通过 pip 安装 ansible-core。"
  info "apt 的 ansible 版本过低或缺失，改用 pip 安装 ${ANSIBLE_CORE_PIP_SPEC}"
  pip_install_ansible_core || fail "pip 安装 ansible-core 失败。"
  hash -r
  ansible_core_meets_requirement || \
    fail "pip 安装后仍未获得满足要求的 ansible-core（可能 PATH 未优先 /usr/local/bin）。"
}

install_system_dependencies() {
  apt_get_available || \
    fail "系统模式只能在支持 apt-get 的 Ubuntu/WSL 自动安装依赖。"
  info "安装系统依赖"
  run_apt_get update
  DEBIAN_FRONTEND=noninteractive run_apt_get install -y \
    ansible python3 python3-pip git curl ca-certificates openssl sshpass
  ensure_ansible_core
}

ensure_dependencies() {
  local missing
  missing="$(missing_core_commands)"
  # 命令齐全但 ansible-core 版本过低时（如 Ubuntu 22.04 的 2.10）也需在系统模式下修复。
  if [[ "${INSTALL_MODE}" == "system" ]] && \
     { [[ -n "${missing}" ]] || ! ansible_core_meets_requirement; }; then
    install_system_dependencies
    missing="$(missing_core_commands)"
  fi
  if [[ -n "${missing}" ]]; then
    printf '缺少命令：\n%s\n' "${missing}" >&2
    if [[ "${INSTALL_MODE}" == "user" ]]; then
      printf '普通用户安装不会提权。请让管理员安装 python3、ansible、git、curl 和 openssl。\n' >&2
    fi
    exit 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    fail "找不到 sha256sum 或 shasum。"
  fi
}

ansible_core_version() {
  command -v ansible-playbook >/dev/null 2>&1 || return 1
  # 兼容两种版本串：新版 "ansible-playbook [core 2.18.6]" 与旧版 "ansible-playbook 2.10.7"。
  ansible-playbook --version 2>/dev/null | \
    sed -nE '1s/.*(core |ansible-playbook )([0-9]+)\.([0-9]+).*/\2.\3/p'
}

ansible_core_meets_requirement() {
  local version major minor
  version="$(ansible_core_version)" || return 1
  [[ -n "${version}" ]] || return 1
  major="${version%%.*}"
  minor="${version##*.}"
  (( major > REQUIRED_ANSIBLE_MAJOR || \
     (major == REQUIRED_ANSIBLE_MAJOR && minor >= REQUIRED_ANSIBLE_MINOR) ))
}

check_ansible_version() {
  ansible_core_meets_requirement && return 0
  local version
  version="$(ansible_core_version || true)"
  [[ -n "${version}" ]] || fail "无法识别 ansible-core 版本。"
  fail "需要 ansible-core >= ${REQUIRED_ANSIBLE_MAJOR}.${REQUIRED_ANSIBLE_MINOR}，当前为 ${version}。"
}

download_base_url() {
  if [[ -n "${DEVOPS_TOOLKIT_DOWNLOAD_BASE:-}" ]]; then
    printf '%s\n' "${DEVOPS_TOOLKIT_DOWNLOAD_BASE%/}"
  elif [[ -n "${REQUESTED_VERSION}" ]]; then
    printf 'https://github.com/%s/releases/download/%s\n' "${REPOSITORY}" "${REQUESTED_VERSION}"
  else
    printf 'https://github.com/%s/releases/latest/download\n' "${REPOSITORY}"
  fi
}

# 从 GitHub 拉产物时，中国大陆网络常见 TLS 连接被重置（curl 56 unexpected eof）。
# 对远程 URL 加有限重试 + 退避；--retry-all-errors 让连接类错误也参与重试。
# 本地 file://（测试用例）没有瞬时错误，跳过重试以免拖慢失败路径。
curl_download() {
  local url="$1" output="$2"
  if [[ "${url}" == file://* ]]; then
    curl --fail --silent --show-error --location \
      "${url}" --output "${output}"
  else
    # --speed-limit/--speed-time：传输速率低于 1KB/s 持续 30s 就中止本次尝试，
    # 避免连上后数据流卡死导致无限挂起；配合 --retry 让停滞的尝试自动重来。
    curl --fail --silent --show-error --location \
      --retry 5 --retry-delay 2 --retry-all-errors \
      --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
      "${url}" --output "${output}"
  fi
}

download_assets() {
  local base_url="$1"
  info "下载 DevOpsToolkit Release"
  curl_download "${base_url}/${ARCHIVE_NAME}" "${TEMP_DIR}/${ARCHIVE_NAME}"
  curl_download "${base_url}/${CHECKSUM_NAME}" "${TEMP_DIR}/${CHECKSUM_NAME}"
  curl_download "${base_url}/${BUNDLE_NAME}" "${TEMP_DIR}/${BUNDLE_NAME}"
  chmod 0600 \
    "${TEMP_DIR}/${ARCHIVE_NAME}" \
    "${TEMP_DIR}/${CHECKSUM_NAME}" \
    "${TEMP_DIR}/${BUNDLE_NAME}"
}

calculate_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

toolkit_base_dir() {
  if [[ "${INSTALL_MODE}" == "system" ]]; then
    printf '%s\n' "${DEVOPS_TOOLKIT_INSTALL_BASE:-/opt/devops-toolkit}"
  else
    printf '%s\n' "${DEVOPS_TOOLKIT_INSTALL_BASE:-${HOME}/.local/share/devops-toolkit}"
  fi
}

verify_checksum() {
  local expected actual expected_lower actual_lower
  expected="$(awk 'NR == 1 {print $1}' "${TEMP_DIR}/${CHECKSUM_NAME}")"
  [[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || fail "Release checksum 文件格式无效。"
  actual="$(calculate_sha256 "${TEMP_DIR}/${ARCHIVE_NAME}")"
  expected_lower="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"
  actual_lower="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"
  [[ "${actual_lower}" == "${expected_lower}" ]] || fail "Release SHA256 校验失败。"
  printf '%s\n' "${actual_lower}" >"${TEMP_DIR}/verified.sha256"
  info "SHA256 校验通过"
}

cosign_asset_name() {
  local operating_system architecture
  operating_system="$(uname -s | tr '[:upper:]' '[:lower:]')"
  architecture="$(uname -m)"
  case "${operating_system}" in
    linux|darwin) ;;
    *) fail "Cosign 暂不支持当前系统：${operating_system}。" ;;
  esac
  case "${architecture}" in
    x86_64|amd64) architecture="amd64" ;;
    arm64|aarch64) architecture="arm64" ;;
    *) fail "Cosign 暂不支持当前架构：${architecture}。" ;;
  esac
  printf 'cosign-%s-%s\n' "${operating_system}" "${architecture}"
}

cosign_expected_sha256() {
  case "$1" in
    cosign-darwin-amd64) printf '%s\n' '14d2678dfbfde18798151e86fbd91ebdadbb7424b18412a42a155dd8a2df4c7a' ;;
    cosign-darwin-arm64) printf '%s\n' '94b42a9e697be95675f6160ab031a9a5f1ec1e646d6f648d7b2f5cd59ececbc5' ;;
    cosign-linux-amd64) printf '%s\n' 'ae1ecd212663f3693ad9edf8b1a183900c9a52d3155ba6e354237f9a0f6463fc' ;;
    cosign-linux-arm64) printf '%s\n' '2ec865872e331c32fd12b08dae15332d3f92c0aa029219589684a4903ca85d11' ;;
    *) fail "没有 $1 的 Cosign 校验值。" ;;
  esac
}

cosign_download_base() {
  # DEVOPS_TOOLKIT_COSIGN_BASE 允许墙内用户把 cosign 二进制指向可达镜像；
  # SHA256 仍会强校验，镜像不影响安全性。基址需包含到版本目录，形如
  # https://<mirror>/https://github.com/sigstore/cosign/releases/download/vX.Y.Z
  if [[ -n "${DEVOPS_TOOLKIT_COSIGN_BASE:-}" ]]; then
    printf '%s\n' "${DEVOPS_TOOLKIT_COSIGN_BASE%/}"
  else
    printf 'https://github.com/sigstore/cosign/releases/download/%s\n' "${COSIGN_VERSION}"
  fi
}

prepare_cosign() {
  local asset_name expected_sha actual_sha download_base cache_dir cached_cosign cache_tmp
  asset_name="$(cosign_asset_name)"
  expected_sha="$(cosign_expected_sha256 "${asset_name}")"
  download_base="$(cosign_download_base)"

  cache_dir="$(toolkit_base_dir)/tools"
  cached_cosign="${cache_dir}/cosign-${COSIGN_VERSION}-${asset_name}"
  if [[ -f "${cached_cosign}" && \
        "$(calculate_sha256 "${cached_cosign}")" == "${expected_sha}" ]]; then
    info "复用已校验的 Cosign ${COSIGN_VERSION}"
    printf '%s\n' "${cached_cosign}"
    return 0
  fi

  info "下载并校验 Cosign ${COSIGN_VERSION}"
  curl_download "${download_base}/${asset_name}" "${TEMP_DIR}/cosign"
  chmod 0700 "${TEMP_DIR}/cosign"
  actual_sha="$(calculate_sha256 "${TEMP_DIR}/cosign")"
  [[ "${actual_sha}" == "${expected_sha}" ]] || fail "Cosign SHA256 校验失败。"
  mkdir -p "${cache_dir}"
  chmod 0755 "$(toolkit_base_dir)" "${cache_dir}"
  cache_tmp="${cache_dir}/.cosign-$$"
  cp "${TEMP_DIR}/cosign" "${cache_tmp}"
  chmod 0755 "${cache_tmp}"
  python3 - "${cache_tmp}" "${cached_cosign}" <<'PY'
import os
import sys

os.replace(sys.argv[1], sys.argv[2])
PY
  printf '%s\n' "${cached_cosign}"
}

verify_sigstore_signature() {
  local release_version="$1" cosign identity workflow_ref
  cosign="$(prepare_cosign | tail -n 1)"
  identity="https://github.com/${REPOSITORY}/.github/workflows/release.yml@refs/tags/${release_version}"
  workflow_ref="refs/tags/${release_version}"
  info "验证 Sigstore 签名与 GitHub Actions 身份"
  "${cosign}" verify-blob \
    --timeout 2m \
    --bundle "${TEMP_DIR}/${BUNDLE_NAME}" \
    --certificate-identity "${identity}" \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    --certificate-github-workflow-repository "${REPOSITORY}" \
    --certificate-github-workflow-ref "${workflow_ref}" \
    --certificate-github-workflow-trigger push \
    "${TEMP_DIR}/${ARCHIVE_NAME}" >/dev/null || \
      fail "Sigstore 签名验证失败，拒绝安装。"
  info "Sigstore 身份验证通过"
}

extract_archive_safely() {
  mkdir -m 0700 "${TEMP_DIR}/extracted"
  python3 - "${TEMP_DIR}/${ARCHIVE_NAME}" "${TEMP_DIR}/extracted" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

archive, destination = sys.argv[1:]
with tarfile.open(archive, "r:gz") as package:
    members = package.getmembers()
    if not members:
        raise SystemExit("empty release archive")
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not path.parts or path.parts[0] != "devops-toolkit":
            raise SystemExit(f"unexpected archive root: {member.name}")
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive entry: {member.name}")
    package.extractall(destination)
PY
}

read_release_version() {
  local source_dir="${TEMP_DIR}/extracted/devops-toolkit"
  [[ -f "${source_dir}/VERSION" ]] || fail "Release 缺少 VERSION。"
  [[ -x "${source_dir}/bin/devops-toolkit" ]] || fail "Release 缺少可执行入口。"
  [[ -f "${source_dir}/ansible/requirements.yml" ]] || fail "Release 缺少 Ansible requirements。"
  local release_version
  release_version="$(tr -d '[:space:]' <"${source_dir}/VERSION")"
  [[ "${release_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.-]+)?$ ]] || \
    fail "Release VERSION 格式无效。"
  if [[ -n "${REQUESTED_VERSION}" && "${release_version}" != "${REQUESTED_VERSION}" ]]; then
    fail "请求 ${REQUESTED_VERSION}，但 Release 内容为 ${release_version}。"
  fi
  printf '%s\n' "${release_version}"
}

install_release() {
  local release_version="$1" verified_sha source_dir base_dir bin_dir
  source_dir="${TEMP_DIR}/extracted/devops-toolkit"
  verified_sha="$(cat "${TEMP_DIR}/verified.sha256")"
  if [[ "${INSTALL_MODE}" == "system" ]]; then
    base_dir="$(toolkit_base_dir)"
    bin_dir="${DEVOPS_TOOLKIT_BIN_DIR:-/usr/local/bin}"
  else
    base_dir="$(toolkit_base_dir)"
    bin_dir="${DEVOPS_TOOLKIT_BIN_DIR:-${HOME}/.local/bin}"
  fi

  local releases_dir target_dir staging_dir current_link launcher_link
  releases_dir="${base_dir}/releases"
  target_dir="${releases_dir}/${release_version}"
  staging_dir="${releases_dir}/.install-${release_version}-$$"
  current_link="${base_dir}/current"
  launcher_link="${bin_dir}/devops-toolkit"
  mkdir -p "${releases_dir}"
  chmod 0755 "${base_dir}" "${releases_dir}"
  if [[ ! -d "${bin_dir}" ]]; then
    mkdir -p "${bin_dir}"
    chmod 0755 "${bin_dir}"
  fi

  if [[ -e "${current_link}" && ! -L "${current_link}" ]]; then
    fail "${current_link} 已存在且不是符号链接，拒绝覆盖。"
  fi
  if [[ -e "${launcher_link}" && ! -L "${launcher_link}" ]]; then
    fail "${launcher_link} 已存在且不是符号链接，拒绝覆盖。"
  fi

  local collection_root
  if [[ -e "${target_dir}" || -L "${target_dir}" ]]; then
    [[ -f "${target_dir}/.release-sha256" ]] || \
      fail "版本目录 ${target_dir} 已存在但缺少校验记录，拒绝覆盖。"
    [[ "$(cat "${target_dir}/.release-sha256")" == "${verified_sha}" ]] || \
      fail "版本 ${release_version} 的 Release 内容已变化，拒绝覆盖不可变版本。"
    info "版本 ${release_version} 已安装，复用现有文件"
    collection_root="${target_dir}"
  else
    rm -rf "${staging_dir}"
    mkdir -m 0755 "${staging_dir}"
    cp -a "${source_dir}/." "${staging_dir}/"
    chmod 0755 "${staging_dir}"
    printf '%s\n' "${verified_sha}" >"${staging_dir}/.release-sha256"
    chmod 0755 "${staging_dir}/bin/devops-toolkit"
    collection_root="${staging_dir}"
  fi

  if [[ -f "${collection_root}/.collections-ready" ]]; then
    info "Ansible collections 已就绪，跳过安装"
  else
    info "安装 Ansible collections 到版本目录"
    mkdir -p "${collection_root}/collections"
    if ! ANSIBLE_COLLECTIONS_PATH="${collection_root}/collections" \
      ANSIBLE_COLLECTIONS_PATHS="${collection_root}/collections" \
      ansible-galaxy collection install \
        --requirements-file "${collection_root}/ansible/requirements.yml" \
        --collections-path "${collection_root}/collections"; then
      [[ "${collection_root}" != "${staging_dir}" ]] || rm -rf "${staging_dir}"
      fail "Ansible collections 安装失败，current 未切换。"
    fi
    printf '%s\n' "${verified_sha}" >"${collection_root}/.collections-ready"
  fi

  find "${collection_root}" -type d -exec chmod a+rx {} +
  find "${collection_root}" -type f -exec chmod a+r {} +
  chmod 0600 "${collection_root}/.release-sha256" "${collection_root}/.collections-ready"

  if [[ "${collection_root}" == "${staging_dir}" ]]; then
    mv "${staging_dir}" "${target_dir}"
  fi

  local current_tmp launcher_tmp
  current_tmp="${base_dir}/.current-$$"
  launcher_tmp="${bin_dir}/.devops-toolkit-$$"
  ln -s "releases/${release_version}" "${current_tmp}"
  ln -s "${current_link}/bin/devops-toolkit" "${launcher_tmp}"
  python3 - "${current_tmp}" "${current_link}" "${launcher_tmp}" "${launcher_link}" <<'PY'
import os
import sys

current_tmp, current_link, launcher_tmp, launcher_link = sys.argv[1:]
os.replace(current_tmp, current_link)
os.replace(launcher_tmp, launcher_link)
PY

  printf '%s\n' "${launcher_link}"
}

main() {
  parse_args "$@"
  ensure_dependencies
  check_ansible_version
  umask 077
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devops-toolkit-install.XXXXXX")"
  chmod 0700 "${TEMP_DIR}"
  trap cleanup EXIT INT TERM

  local base_url release_version launcher
  base_url="$(download_base_url)"
  download_assets "${base_url}"
  verify_checksum
  extract_archive_safely
  release_version="$(read_release_version)"
  verify_sigstore_signature "${release_version}"
  launcher="$(install_release "${release_version}" | tail -n 1)"

  info "DevOpsToolkit ${release_version} 已安装：${launcher}"
  if [[ "${INSTALL_MODE}" == "user" && ":${PATH}:" != *":$(dirname "${launcher}"):"* ]]; then
    printf '提示：请将 %s 加入 PATH。\n' "$(dirname "${launcher}")"
  fi
  if [[ "${RUN_AFTER_INSTALL}" == true && -t 0 && -t 1 ]]; then
    exec "${launcher}"
  fi
  if [[ "${RUN_AFTER_INSTALL}" == true ]]; then
    info "当前不是交互终端，已跳过启动向导；稍后运行 devops-toolkit。"
  fi
}

# 通过 `bash -c "$(curl ... install.sh)"` 运行时 BASH_SOURCE 为空，set -u 会因未绑定变量报错。
# 用 ${BASH_SOURCE[0]:-$0} 兜底：直接执行或管道执行都运行 main，仅在被 source 时不运行。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
