#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH_HELPER="${SCRIPT_DIR}/cap-paths.sh"

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

json_escape() {
  printf '%s' "$1" \
    | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

append_trace() {
  local source="$1"
  local summary="$2"
  local result="$3"
  local trace_dir
  local trace_file
  local trace_jsonl_file
  local timestamp
  local source_clean
  local summary_clean
  local result_clean
  local project_id

  bash "${PATH_HELPER}" ensure >/dev/null
  trace_dir="$(bash "${PATH_HELPER}" get trace_dir)"
  project_id="$(bash "${PATH_HELPER}" get project_id)"
  trace_file="${trace_dir}/trace-$(date '+%Y-%m').log"
  trace_jsonl_file="${trace_dir}/trace-$(date '+%Y-%m').jsonl"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  source_clean="$(sanitize_text "${source}")"
  summary_clean="$(sanitize_text "${summary}")"
  result_clean="$(sanitize_text "${result}")"

  printf '[%s] [%s] [%s] [執行結果: %s]\n' \
    "${source_clean}" \
    "${summary_clean}" \
    "${timestamp}" \
    "${result_clean}" >> "${trace_file}"

  printf '{%s,%s,%s,%s}\n' \
    "\"timestamp\":$(json_escape "${timestamp}")" \
    "\"project_id\":$(json_escape "${project_id}")" \
    "\"source\":$(json_escape "${source_clean}")" \
    "\"summary\":$(json_escape "${summary_clean}")" \
    "\"result\":$(json_escape "${result_clean}")" >> "${trace_jsonl_file}"

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
