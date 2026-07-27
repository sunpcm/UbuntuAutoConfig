#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "警告：wsl-dev/update.sh 已弃用，将转调统一 bootstrap。" >&2
exec "${SCRIPT_DIR}/bootstrap.sh" "$@"
