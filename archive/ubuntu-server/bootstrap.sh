#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY="${INVENTORY:-${SCRIPT_DIR}/host.ini}"

echo "警告：ubuntu-server/bootstrap.sh 已弃用，请改用 bin/ubuntu-bootstrap。" >&2

if [[ ! -f "${INVENTORY}" ]]; then
  echo "错误：找不到 inventory：${INVENTORY}" >&2
  exit 1
fi

TARGET_USER="${TARGET_USER:-}"
if [[ -z "${TARGET_USER}" ]]; then
  echo "错误：旧入口不再读取已归档变量，请显式设置 TARGET_USER。" >&2
  echo "示例：TARGET_USER=developer $0 --private-key ~/.ssh/id_ed25519" >&2
  exit 1
fi

exec "${ROOT_DIR}/bin/ubuntu-bootstrap" "${INVENTORY}" "${TARGET_USER}" "$@"
