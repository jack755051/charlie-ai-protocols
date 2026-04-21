#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_FILE="${CAP_ROOT}/.cap.agents.json"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-registry.sh show
  bash scripts/cap-registry.sh get <agent_alias>
  bash scripts/cap-registry.sh list
EOF
  exit 1
}

[ -f "${REGISTRY_FILE}" ] || {
  echo "找不到 agent registry：${REGISTRY_FILE}" >&2
  exit 1
}

case "${1:-}" in
  show)
    [ "$#" -eq 1 ] || usage
    cat "${REGISTRY_FILE}"
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    python3 - <<'PY' "${REGISTRY_FILE}"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for alias, meta in sorted(data.get("agents", {}).items()):
    print(f"{alias}\t{meta.get('provider','unknown')}\t{meta.get('prompt_file','')}\t{meta.get('cli', data.get('default_cli','codex'))}")
PY
    ;;
  get)
    [ "$#" -eq 2 ] || usage
    python3 - <<'PY' "${REGISTRY_FILE}" "$2"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
alias = sys.argv[2]
meta = data.get("agents", {}).get(alias)
if not meta:
    sys.exit(1)
print(json.dumps({
    "alias": alias,
    "provider": meta.get("provider", "builtin"),
    "prompt_file": meta.get("prompt_file", ""),
    "cli": meta.get("cli", data.get("default_cli", "codex")),
}, ensure_ascii=False))
PY
    ;;
  *)
    usage
    ;;
esac
