#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
MANAGED_SSH_PORT="${MANAGED_SSH_PORT:-2222}"
TARGET_USER="${TARGET_USER:-devops_test}"
KEEP_INSTANCES=0
TEST_UV=0
MODE="run"
WORK_DIR=""
declare -a REQUESTED_INSTANCES=()
declare -a ACTIVE_INSTANCES=()
declare -a CREATED_INSTANCES=()

usage() {
  cat <<'EOF'
用法：
  ./tests/multipass-smoke.sh run [--instance NAME ...] [--keep] [--with-uv]
  ./tests/multipass-smoke.sh check [NAME ...]
  ./tests/multipass-smoke.sh cleanup NAME ...

说明：
  run      不传 --instance 时，为 Ubuntu 22.04/24.04 创建临时实例并在成功后清理；
           失败时保留现场。--instance 仅用于续跑已有的 *-test-* 临时实例。
           --with-uv 额外验证 GitHub 固定产物下载与 SHA256 校验，默认不启用。
  check    只检查实例状态、版本、架构、联网和 SSH 服务。
  cleanup  只删除由本脚本命名的 *-test-* 临时实例，先显示实例列表。

续跑临时实例示例：
  ./tests/multipass-smoke.sh run \
    --instance devops-toolkit-2204-test-YYYYMMDDhhmmss-PID
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "找不到命令：$1"
}

instance_exists() {
  multipass list --format json | python3 -c '
import json
import sys

name = sys.argv[1]
data = json.load(sys.stdin)
raise SystemExit(0 if any(item["name"] == name for item in data["list"]) else 1)
' "$1"
}

is_disposable_name() {
  [[ "$1" =~ ^devops-toolkit-(2204|2404)-test-[0-9]{14}-[0-9]+$ ]]
}

check_instance() {
  local instance="$1"
  echo "==> 检查 ${instance}"
  multipass info "${instance}"
  # 单引号内的变量刻意在 VM 内展开，不在宿主机展开。
  # shellcheck disable=SC2016
  multipass exec "${instance}" -- sh -lc '
    set -eu
    . /etc/os-release
    printf "release=%s arch=" "$VERSION_ID"
    uname -m
    getent hosts github.com >/dev/null
    printf "internet=ok ssh="
    systemctl is-active ssh
  '
}

cleanup_instances() {
  local instance
  (($# > 0)) || die "cleanup 至少需要一个实例名"
  for instance in "$@"; do
    is_disposable_name "${instance}" || \
      die "拒绝删除非临时实例：${instance}"
    instance_exists "${instance}" || die "实例不存在：${instance}"
    multipass list
  done
  for instance in "$@"; do
    multipass stop --force "${instance}" || true
    multipass delete "${instance}"
  done
  multipass purge
}

cleanup_mount() {
  local instance="$1"
  if multipass info "${instance}" 2>/dev/null | grep -Fq '/mnt/devops-toolkit-host'; then
    multipass unmount "${instance}:/mnt/devops-toolkit-host" || true
  fi
}

report_exit() {
  local status="$1"
  echo "测试工件保留在：${WORK_DIR}"
  if ((status != 0)) && ((${#CREATED_INSTANCES[@]} > 0)); then
    printf '临时实例已保留。确认后清理：%q cleanup' "$0"
    printf ' %q' "${CREATED_INSTANCES[@]}"
    printf '\n'
  fi
}

validate_mount() {
  local instance="$1"
  cleanup_mount "${instance}"
  multipass mount "${ROOT_DIR}" "${instance}:/mnt/devops-toolkit-host"
  multipass exec "${instance}" -- test -r /mnt/devops-toolkit-host/TODO.md
  cleanup_mount "${instance}"
  echo "${instance}: 项目目录挂载验证通过"
}

prepare_root_key() {
  local instance="$1"
  local public_key_file="$2"
  local remote_key="/tmp/devops-toolkit-${RUN_ID}.pub"
  multipass transfer "${public_key_file}" "${instance}:${remote_key}"
  multipass exec "${instance}" -- sudo sh -eu -c "
    install -d -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    key=\$(cat '${remote_key}')
    grep -Fqx \"\${key}\" /root/.ssh/authorized_keys || printf '%s\\n' \"\${key}\" >>/root/.ssh/authorized_keys
    rm -f '${remote_key}'
  "
}

instance_ip() {
  multipass info "$1" --format json | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(iter(d["info"].values()))["ipv4"][0])'
}

write_inventory() {
  local path="$1"
  local name="$2"
  local ip="$3"
  local port="$4"
  local key_file="$5"
  local known_hosts="$6"
  cat >"${path}" <<EOF
[ubuntu_servers]
${name} ansible_host=${ip} ansible_user=root ansible_port=${port} ansible_ssh_private_key_file=${key_file} ansible_ssh_common_args='-o UserKnownHostsFile=${known_hosts} -o IdentitiesOnly=yes'
EOF
}

assert_recap_clean() {
  local log_file="$1"
  local recap
  recap="$(grep -E 'changed=[0-9]+.*unreachable=[0-9]+.*failed=[0-9]+' "${log_file}" | tail -n 1 || true)"
  [[ -n "${recap}" ]] || die "无法识别 Ansible PLAY RECAP：${log_file}"
  if grep -Eq 'changed=[1-9][0-9]*|unreachable=[1-9][0-9]*|failed=[1-9][0-9]*' <<<"${recap}"; then
    die "第二次执行不是零变更：${recap}"
  fi
  echo "幂等验证通过：${recap}"
}

verify_result() {
  local instance="$1"
  local ip="$2"
  local key_file="$3"
  local known_hosts="$4"

  ssh -F /dev/null -i "${key_file}" -o IdentitiesOnly=yes \
    -o "UserKnownHostsFile=${known_hosts}" -p "${MANAGED_SSH_PORT}" \
    "${TARGET_USER}@${ip}" true
  ssh -F /dev/null -i "${key_file}" -o IdentitiesOnly=yes \
    -o "UserKnownHostsFile=${known_hosts}" -p "${MANAGED_SSH_PORT}" \
    "${TARGET_USER}@${ip}" sudo env \
    TARGET_USER="${TARGET_USER}" MANAGED_SSH_PORT="${MANAGED_SSH_PORT}" \
    TEST_UV="${TEST_UV}" sh -eu -s <<'EOF'
id "$TARGET_USER" >/dev/null
test -s "/home/$TARGET_USER/.ssh/authorized_keys"
sshd -T | grep -Eq "^port ${MANAGED_SSH_PORT}$"
ufw status | grep -Fq "Status: active"
# UFW converges through the managed application profile, so "ufw status" lists the
# profile name rather than the raw port. Assert the port via the profile itself.
ufw app info DevOpsToolkit | grep -Fq "${MANAGED_SSH_PORT}/tcp"
systemctl is-active --quiet docker
systemctl is-enabled --quiet docker
systemctl is-active --quiet nginx
systemctl is-enabled --quiet nginx
id -nG "$TARGET_USER" | tr " " "\n" | grep -Fxq docker
if [ "$TEST_UV" = 1 ]; then
  test -x "/home/$TARGET_USER/.local/bin/uv"
fi
EOF
  echo "${instance}: 用户、SSH、UFW、Docker、Nginx 验证通过"
}

run_instance() {
  local instance="$1"
  local work_dir="$2"
  local key_file="$3"
  local public_key_file="${key_file}.pub"
  local known_hosts="${work_dir}/${instance}.known_hosts"
  local initial_inventory="${work_dir}/${instance}-initial.ini"
  local managed_inventory="${work_dir}/${instance}-managed.ini"
  local vars_file="${work_dir}/${instance}-vars.yml"
  local second_log="${work_dir}/${instance}-second.log"
  local ip public_key initial_port

  check_instance "${instance}"
  validate_mount "${instance}"
  prepare_root_key "${instance}" "${public_key_file}"
  ip="$(instance_ip "${instance}")"
  public_key="$(cat "${public_key_file}")"
  cat >"${vars_file}" <<EOF
---
target_authorized_keys:
  - ${public_key}
ssh_port: ${MANAGED_SSH_PORT}
disable_password_auth: true
target_passwordless_sudo: true
install_docker: true
install_nginx: true
install_linuxbrew: false
configure_shell: false
configure_git: false
configure_node: false
configure_go: false
configure_homebrew_environment: false
configure_wsl_integration: false
configure_uv: $([[ "${TEST_UV}" == 1 ]] && echo true || echo false)
EOF

  initial_port=22
  if ! ssh-keyscan -T 3 -p "${initial_port}" -H "${ip}" >"${known_hosts}" 2>/dev/null; then
    initial_port="${MANAGED_SSH_PORT}"
    ssh-keyscan -T 3 -p "${initial_port}" -H "${ip}" >"${known_hosts}" 2>/dev/null || \
      die "${instance}: SSH 22 和 ${MANAGED_SSH_PORT} 均不可达"
  fi
  write_inventory "${initial_inventory}" "${instance}" "${ip}" \
    "${initial_port}" "${key_file}" "${known_hosts}"

  echo "==> ${instance}: 首次配置（SSH ${initial_port} -> ${MANAGED_SSH_PORT}）"
  "${ROOT_DIR}/bin/ubuntu-bootstrap" "${initial_inventory}" "${TARGET_USER}" \
    -e "@${vars_file}"

  ssh-keyscan -p "${MANAGED_SSH_PORT}" -H "${ip}" >"${known_hosts}" 2>/dev/null
  write_inventory "${managed_inventory}" "${instance}" "${ip}" \
    "${MANAGED_SSH_PORT}" "${key_file}" "${known_hosts}"

  echo "==> ${instance}: 第二次配置（幂等性）"
  "${ROOT_DIR}/bin/ubuntu-bootstrap" "${managed_inventory}" "${TARGET_USER}" \
    -e "@${vars_file}" | tee "${second_log}"

  assert_recap_clean "${second_log}"
  verify_result "${instance}" "${ip}" "${key_file}" "${known_hosts}"
}

parse_args() {
  if (($# > 0)) && [[ "$1" != --* ]]; then
    MODE="$1"
    shift
  fi
  case "${MODE}" in
    run)
      while (($# > 0)); do
        case "$1" in
          --instance)
            (($# >= 2)) || die "--instance 缺少实例名"
            REQUESTED_INSTANCES+=("$2")
            shift 2
            ;;
          --keep)
            KEEP_INSTANCES=1
            shift
            ;;
          --with-uv)
            TEST_UV=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *) die "未知参数：$1" ;;
        esac
      done
      ;;
    check|cleanup)
      REQUESTED_INSTANCES=("$@")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "未知模式：${MODE}" ;;
  esac
}

main() {
  local instance
  parse_args "$@"
  require_command multipass
  require_command ansible-playbook
  require_command ssh
  require_command ssh-keygen
  require_command ssh-keyscan
  require_command python3

  if [[ "${MODE}" == check ]]; then
    ((${#REQUESTED_INSTANCES[@]} > 0)) || die "check 至少需要一个实例名"
    for instance in "${REQUESTED_INSTANCES[@]}"; do check_instance "${instance}"; done
    exit 0
  fi
  if [[ "${MODE}" == cleanup ]]; then
    cleanup_instances "${REQUESTED_INSTANCES[@]}"
    exit 0
  fi

  WORK_DIR="$(mktemp -d)"
  trap 'report_exit "$?"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C "devops-toolkit-multipass-${RUN_ID}" \
    -f "${WORK_DIR}/id_ed25519"

  if ((${#REQUESTED_INSTANCES[@]} > 0)); then
    for instance in "${REQUESTED_INSTANCES[@]}"; do
      if ! is_disposable_name "${instance}" && [[ "${MANAGED_SSH_PORT}" != 22 ]]; then
        die "拒绝在长期实例 ${instance} 上切换 SSH 端口；请使用 *-test-* 临时实例"
      fi
    done
    ACTIVE_INSTANCES=("${REQUESTED_INSTANCES[@]}")
  else
    ACTIVE_INSTANCES=(
      "devops-toolkit-2204-test-${RUN_ID}"
      "devops-toolkit-2404-test-${RUN_ID}"
    )
    CREATED_INSTANCES+=("${ACTIVE_INSTANCES[0]}")
    multipass launch 22.04 --name "${ACTIVE_INSTANCES[0]}" --cpus 2 --memory 3G --disk 15G
    CREATED_INSTANCES+=("${ACTIVE_INSTANCES[1]}")
    multipass launch 24.04 --name "${ACTIVE_INSTANCES[1]}" --cpus 2 --memory 3G --disk 15G
  fi

  export ANSIBLE_CONFIG="${ROOT_DIR}/ansible/ansible.cfg"
  export ANSIBLE_LOCAL_TEMP="${WORK_DIR}/ansible-local"
  unset ANSIBLE_REMOTE_TEMP
  mkdir -p "${ANSIBLE_LOCAL_TEMP}"

  for instance in "${ACTIVE_INSTANCES[@]}"; do
    run_instance "${instance}" "${WORK_DIR}" "${WORK_DIR}/id_ed25519"
  done

  if ((${#CREATED_INSTANCES[@]} > 0)) && ((KEEP_INSTANCES == 0)); then
    cleanup_instances "${CREATED_INSTANCES[@]}"
  fi
  echo "Multipass Ubuntu 22.04/24.04 测试全部通过。"
}

main "$@"
