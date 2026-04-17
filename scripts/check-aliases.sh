#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${PROJECT_ROOT}/docs/agent-skills"

TARGET_DIR="${1:-${PROJECT_ROOT}/.agents/skills}"

resolve_expected_alias() {
  local filename="$1"

  case "${filename}" in
    02a-ba-agent.md)
      echo "ba.md"
      ;;
    02b-dba-api-agent.md)
      echo "dba.md"
      ;;
    *)
      echo "${filename}" | sed -E 's/^[0-9]+[a-z]*-//; s/-agent\.md$/.md/'
      ;;
  esac
}

assert_symlink_points_to_source() {
  local link_path="$1"
  local expected_source="$2"

  if [ ! -L "${link_path}" ]; then
    echo "FAIL: missing symlink ${link_path}" >&2
    exit 1
  fi

  local resolved_link
  local resolved_source
  resolved_link="$(cd "$(dirname "${link_path}")" && realpath "$(readlink "${link_path}")")"
  resolved_source="$(realpath "${expected_source}")"

  if [ "${resolved_link}" != "${resolved_source}" ]; then
    echo "FAIL: ${link_path} -> ${resolved_link}, expected ${resolved_source}" >&2
    exit 1
  fi
}

if [ ! -d "${TARGET_DIR}" ]; then
  echo "FAIL: target directory not found: ${TARGET_DIR}" >&2
  exit 1
fi

agent_count=0
alias_count=0

for src in "${SOURCE_DIR}"/*-agent.md; do
  [ -f "${src}" ] || continue
  filename="$(basename "${src}")"
  alias_name="$(resolve_expected_alias "${filename}")"

  assert_symlink_points_to_source "${TARGET_DIR}/${filename}" "${src}"
  assert_symlink_points_to_source "${TARGET_DIR}/${alias_name}" "${src}"

  agent_count=$((agent_count + 1))
  alias_count=$((alias_count + 1))
done

for legacy_alias in 02a-ba.md 02b-dba-api.md; do
  if [ -e "${TARGET_DIR}/${legacy_alias}" ]; then
    echo "FAIL: legacy alias should not exist: ${TARGET_DIR}/${legacy_alias}" >&2
    exit 1
  fi
done

actual_alias_count="$(find "${TARGET_DIR}" -maxdepth 1 -type l ! -name '*-agent.md' | wc -l | tr -d ' ')"
if [ "${actual_alias_count}" != "${alias_count}" ]; then
  echo "FAIL: alias count mismatch in ${TARGET_DIR} (expected ${alias_count}, got ${actual_alias_count})" >&2
  exit 1
fi

echo "OK: ${TARGET_DIR} alias mapping verified (${agent_count} agents / ${alias_count} aliases)"
