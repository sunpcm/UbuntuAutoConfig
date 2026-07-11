#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "警告：wsl-dev/bootstrap.sh 已弃用，请改用 bin/wsl-bootstrap。" >&2

if [[ -n "${TARGET_USER:-}" ]]; then
  TARGET_USER="${TARGET_USER}"
elif [[ "$#" -gt 0 && ! "$1" =~ ^- ]]; then
  TARGET_USER="$1"
  shift
else
  TARGET_USER="${SUDO_USER:-${USER}}"
fi
if [[ "${EUID}" -eq 0 ]]; then
  exec "${ROOT_DIR}/bin/wsl-bootstrap" "${TARGET_USER}" "$@"
else
  exec sudo "${ROOT_DIR}/bin/wsl-bootstrap" "${TARGET_USER}" "$@"
fi
