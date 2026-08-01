#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
OUTPUT_DIR="${2:-${ROOT_DIR}/dist}"
COLLECTIONS_SOURCE="${DEVOPS_TOOLKIT_COLLECTIONS_SOURCE:-}"

if [[ ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.-]+)?$ ]]; then
  echo "用法：$0 v0.1.0 [输出目录]" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devops-toolkit-release.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT
PACKAGE_DIR="${STAGE_DIR}/devops-toolkit"

if [[ -z "${COLLECTIONS_SOURCE}" || \
      ! -f "${COLLECTIONS_SOURCE}/ansible_collections/ansible/posix/MANIFEST.json" || \
      ! -f "${COLLECTIONS_SOURCE}/ansible_collections/community/general/MANIFEST.json" ]]; then
  echo "错误：缺少固定版本 Ansible collections 构建目录。" >&2
  exit 1
fi

mkdir -p "${PACKAGE_DIR}/collections" "${OUTPUT_DIR}"
cp -R \
  "${ROOT_DIR}/ansible" \
  "${ROOT_DIR}/bin" \
  "${ROOT_DIR}/docs" \
  "${PACKAGE_DIR}/"
cp "${ROOT_DIR}/README.md" "${ROOT_DIR}/install.sh" "${PACKAGE_DIR}/"
cp -R "${COLLECTIONS_SOURCE}/ansible_collections" "${PACKAGE_DIR}/collections/"
python3 - "${PACKAGE_DIR}/collections" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    "ansible.posix": ("ansible", "posix", "1.5.4"),
    "community.general": ("community", "general", "7.5.2"),
}
actual = {}
for manifest in root.glob("ansible_collections/*/*/MANIFEST.json"):
    data = json.loads(manifest.read_text(encoding="utf-8"))
    info = data["collection_info"]
    qualified_name = f"{info['namespace']}.{info['name']}"
    actual[qualified_name] = str(info["version"])

expected_versions = {name: values[2] for name, values in expected.items()}
if actual != expected_versions:
    raise SystemExit(
        f"bundled collection mismatch: expected {expected_versions}, got {actual}"
    )

(root / ".bundled-collections").write_text(
    "".join(f"{name}={version}\n" for name, version in sorted(actual.items())),
    encoding="utf-8",
)
PY
printf '%s\n' "${VERSION}" >"${PACKAGE_DIR}/VERSION"
find "${PACKAGE_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "${PACKAGE_DIR}" -type f \( -name '*.pyc' -o -name '.DS_Store' -o -name '._*' \) -delete
chmod 0755 "${PACKAGE_DIR}/bin/devops-toolkit" "${PACKAGE_DIR}/install.sh"

rm -f \
  "${OUTPUT_DIR}/devops-toolkit.tar.gz" \
  "${OUTPUT_DIR}/devops-toolkit.tar.gz.sha256"
COPYFILE_DISABLE=1 tar --no-xattrs -C "${STAGE_DIR}" \
  -czf "${OUTPUT_DIR}/devops-toolkit.tar.gz" devops-toolkit

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUTPUT_DIR}" && sha256sum devops-toolkit.tar.gz >devops-toolkit.tar.gz.sha256)
else
  (cd "${OUTPUT_DIR}" && shasum -a 256 devops-toolkit.tar.gz >devops-toolkit.tar.gz.sha256)
fi

echo "Release 资产已生成：${OUTPUT_DIR}"
