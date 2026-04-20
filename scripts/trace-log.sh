#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRACE_DIR="${CAP_ROOT}/workspace/history"

usage() {
  echo "Usage: bash scripts/trace-log.sh append <source> <summary> <result>" >&2
  exit 1
}

sanitize_text() {
  printf '%s' "${1}" \
    | tr '\r\n' '  ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | awk '{ if (length($0) > 180) { print substr($0, 1, 177) "..." } else { print } }'
}

append_trace() {
  local source="$1"
  local summary="$2"
  local result="$3"
  local trace_file
  local timestamp

  mkdir -p "${TRACE_DIR}"
  trace_file="${TRACE_DIR}/trace-$(date '+%Y-%m').log"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  printf '[%s] [%s] [%s] [執行結果: %s]\n' \
    "$(sanitize_text "${source}")" \
    "$(sanitize_text "${summary}")" \
    "${timestamp}" \
    "$(sanitize_text "${result}")" >> "${trace_file}"

  printf '%s\n' "${trace_file}"
}

case "${1:-}" in
  append)
    [ "$#" -eq 4 ] || usage
    append_trace "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
