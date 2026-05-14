#!/usr/bin/env bash
#
# component-fast-resolve.sh — P1b slice 6a pre-flight resolver.
#
# Validates Component Fast Path arguments against the registry BEFORE
# any file is written. Runs the same checks component-fast-render.sh
# does in its early phase, but as a standalone workflow step so a
# bad argv halts before scaffold ever touches disk. Emits a
# machine-readable summary of the resolved inputs (project id,
# derived tokens, catalog size) so downstream steps and observers
# can see what the workflow committed to.
#
# Out of scope:
#   - No file writes anywhere.
#   - No AI / provider / network access.
#   - No reading of ~/.cap state.
#
# Usage:
#   scripts/workflows/component-fast-resolve.sh \
#     --component-type feedback-widget \
#     --project-id    component-feedback-widget \
#     --project-root  /tmp/sandbox/project
#
#   [--stack-preset name] [--ui-adapter name]
#   [--storage-default name] [--exclude csv]
#
# Exit codes:
#   0   inputs resolved.
#   2   usage / argument / value-not-registry-default error.
#   3   registry yaml not found.
#   4   registry malformed.

set -u

COMPONENT_TYPE=""
PROJECT_ID=""
PROJECT_ROOT=""
STACK_PRESET=""
UI_ADAPTER=""
STORAGE_DEFAULT=""
EXCLUDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 --component-type <name> --project-id <kebab> --project-root <path>
     [--stack-preset <name>] [--ui-adapter <name>]
     [--storage-default <name>] [--exclude <csv>]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --component-type)   COMPONENT_TYPE="${2:-}";    shift 2 ;;
    --project-id)       PROJECT_ID="${2:-}";        shift 2 ;;
    --project-root)     PROJECT_ROOT="${2:-}";      shift 2 ;;
    --stack-preset)     STACK_PRESET="${2:-}";      shift 2 ;;
    --ui-adapter)       UI_ADAPTER="${2:-}";        shift 2 ;;
    --storage-default)  STORAGE_DEFAULT="${2:-}";   shift 2 ;;
    --exclude)          EXCLUDE="${2:-}";           shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) printf 'error: unknown flag: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$COMPONENT_TYPE" ] || { echo "error: --component-type required" >&2; usage; exit 2; }
[ -n "$PROJECT_ID" ]     || { echo "error: --project-id required" >&2;     usage; exit 2; }
[ -n "$PROJECT_ROOT" ]   || { echo "error: --project-root required" >&2;   usage; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="${REPO_ROOT}/schemas/component-types/${COMPONENT_TYPE}.yaml"

if [ ! -f "${REGISTRY}" ]; then
  printf 'error: registry not found: %s\n' "${REGISTRY}" >&2
  exit 3
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" - \
  "${REGISTRY}" \
  "${COMPONENT_TYPE}" \
  "${PROJECT_ID}" \
  "${PROJECT_ROOT}" \
  "${STACK_PRESET}" \
  "${UI_ADAPTER}" \
  "${STORAGE_DEFAULT}" \
  "${EXCLUDE}" \
<<'PY'
import os
import re
import sys

import yaml

(
    registry_path,
    component_type,
    project_id,
    project_root,
    stack_preset_arg,
    ui_adapter_arg,
    storage_default_arg,
    exclude_arg,
) = sys.argv[1:9]


def die(code, msg):
    print("condition: component_fast_resolve_failed")
    print("result: failed")
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# Mirror render.sh validation order so a workflow run sees identical
# resolution semantics regardless of which step caught the typo.
if not re.fullmatch(r"[a-z][a-z0-9-]*", project_id):
    die(2, f"project_id must be kebab-case (lowercase + digits + hyphens): {project_id!r}")

try:
    with open(registry_path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except (OSError, yaml.YAMLError) as exc:
    die(4, f"registry parse failed ({exc!s})")

if data.get("component_type") != component_type:
    die(
        4,
        f"registry component_type={data.get('component_type')!r} "
        f"!= --component-type={component_type!r}",
    )

defaults = data.get("defaults") or {}
hard_exclusions = sorted(set(data.get("hard_exclusions") or []))

if stack_preset_arg and stack_preset_arg != defaults.get("stack_preset"):
    die(
        2,
        f"--stack-preset must be the registry default "
        f"{defaults.get('stack_preset')!r}; got {stack_preset_arg!r}",
    )
if ui_adapter_arg and ui_adapter_arg != defaults.get("ui_adapter"):
    die(
        2,
        f"--ui-adapter must be the registry default "
        f"{defaults.get('ui_adapter')!r}; got {ui_adapter_arg!r}",
    )
if storage_default_arg and storage_default_arg != defaults.get("storage_default"):
    die(
        2,
        f"--storage-default must be the registry default "
        f"{defaults.get('storage_default')!r}; got {storage_default_arg!r}",
    )

if exclude_arg:
    requested = {token.strip() for token in exclude_arg.split(",") if token.strip()}
    missing = sorted(set(hard_exclusions) - requested)
    if missing:
        die(2, f"--exclude must include registry hard_exclusions: {missing}")


def kebab_to_pascal(value):
    return "".join(part[:1].upper() + part[1:] for part in value.split("-") if part)


def in_memory_store_class(value):
    domain = value.split("-", 1)[0]
    if not domain:
        die(4, f"cannot derive store class from component_type={value!r}")
    return f"InMemory{domain[:1].upper()}{domain[1:]}Store"


project_name_pascal = kebab_to_pascal(project_id)
store_default = in_memory_store_class(component_type)
api_base_url = (
    ((data.get("substitutions") or {}).get("API_BASE_URL") or {}).get("default")
    or "http://localhost:8080"
)
catalog_count = len(data.get("catalog") or [])

# Machine-readable summary. Downstream steps can pipe this through
# `read -r` or parse the JSON-friendly key: value lines.
print("condition: ok")
print(f"component_type: {component_type}")
print(f"project_id: {project_id}")
print(f"project_root: {project_root}")
print(f"project_name_pascal: {project_name_pascal}")
print(f"store_default: {store_default}")
print(f"api_base_url: {api_base_url}")
print(f"hard_exclusions: {','.join(hard_exclusions)}")
print(f"catalog_count: {catalog_count}")
print("result: success")
PY
