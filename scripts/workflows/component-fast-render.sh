#!/usr/bin/env bash
#
# component-fast-render.sh — P1b slice 3 deterministic renderer.
#
# Reads schemas/component-types/<component_type>.yaml, walks its
# `catalog`, substitutes the registry's declared tokens, and writes
# each template to <project_root>/<target_path>. Pure file-system
# work — no AI, no network, no provider, no compose probe.
#
# Out of scope for slice 3 (per docs/cap/COMPONENT-FAST-PATH-MEMO.md
# P1b slice ordering):
#   * No workflow YAML wiring (slice ≥ 6).
#   * No new capabilities entry.
#   * No audit / smoke step — slice 4 / 5 own those.
#   * `--stack-preset` / `--ui-adapter` / `--storage-default` /
#     `--exclude` flags are accepted for forward-compat but only
#     the registry defaults are valid values; any other value is
#     rejected with exit 2.
#
# Usage:
#   scripts/workflows/component-fast-render.sh \
#     --component-type feedback-widget \
#     --project-id component-feedback-widget \
#     --project-root /tmp/sandbox/project
#
# Exit codes:
#   0   success — every catalog entry rendered.
#   2   usage / argument / value-not-registry-default error.
#   3   registry file missing.
#   4   catalog malformed or referenced template missing on disk.

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

Slice 3 only accepts the registry defaults for the optional flags.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --component-type)   COMPONENT_TYPE="${2:-}";   shift 2 ;;
    --project-id)       PROJECT_ID="${2:-}";       shift 2 ;;
    --project-root)     PROJECT_ROOT="${2:-}";     shift 2 ;;
    --stack-preset)     STACK_PRESET="${2:-}";     shift 2 ;;
    --ui-adapter)       UI_ADAPTER="${2:-}";       shift 2 ;;
    --storage-default)  STORAGE_DEFAULT="${2:-}";  shift 2 ;;
    --exclude)          EXCLUDE="${2:-}";          shift 2 ;;
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
  "${REPO_ROOT}" \
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
import stat
import sys

import yaml

(
    registry_path,
    repo_root,
    component_type,
    project_id,
    project_root,
    stack_preset_arg,
    ui_adapter_arg,
    storage_default_arg,
    exclude_arg,
) = sys.argv[1:10]


def die(code, msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def kebab_to_pascal(value):
    return "".join(part[:1].upper() + part[1:] for part in value.split("-") if part)


def in_memory_store_class(component_type_value):
    """Derive the storage class name for storage_default=in_memory.

    Pattern: take the first segment of component_type (the "domain
    noun"), Pascal-case it, and wrap with `InMemory*Store`.
    For component_type=feedback-widget this yields
    `InMemoryFeedbackStore`, which matches the slice-2 template's
    actual class file under
    `backend/Feedback/Infrastructure/InMemoryFeedbackStore.cs`.
    """
    domain = component_type_value.split("-", 1)[0]
    if not domain:
        die(4, f"cannot derive store class from component_type={component_type_value!r}")
    domain_pascal = domain[:1].upper() + domain[1:]
    return f"InMemory{domain_pascal}Store"


# ─── Validate inputs ─────────────────────────────────────────────────
project_id_re = re.compile(r"^[a-z][a-z0-9-]*$")
if not project_id_re.match(project_id):
    die(2, f"project_id must be kebab-case (lowercase + digits + hyphens): {project_id!r}")

try:
    with open(registry_path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except (OSError, yaml.YAMLError) as exc:
    die(3, f"registry parse failed ({exc!s})")

if data.get("component_type") != component_type:
    die(
        4,
        f"registry component_type={data.get('component_type')!r} "
        f"!= --component-type={component_type!r}",
    )

defaults = data.get("defaults") or {}
hard_exclusions = sorted(set(data.get("hard_exclusions") or []))

# Slice 3 only accepts the registry defaults. Future slices can relax this.
if stack_preset_arg and stack_preset_arg != defaults.get("stack_preset"):
    die(
        2,
        f"--stack-preset must be the registry default "
        f"{defaults.get('stack_preset')!r} (slice 3); got {stack_preset_arg!r}",
    )
if ui_adapter_arg and ui_adapter_arg != defaults.get("ui_adapter"):
    die(
        2,
        f"--ui-adapter must be the registry default "
        f"{defaults.get('ui_adapter')!r} (slice 3); got {ui_adapter_arg!r}",
    )
if storage_default_arg and storage_default_arg != defaults.get("storage_default"):
    die(
        2,
        f"--storage-default must be the registry default "
        f"{defaults.get('storage_default')!r} (slice 3); got {storage_default_arg!r}",
    )

if exclude_arg:
    requested = {token.strip() for token in exclude_arg.split(",") if token.strip()}
    missing = sorted(set(hard_exclusions) - requested)
    if missing:
        die(2, f"--exclude must include registry hard_exclusions: {missing}")

# ─── Build substitution table ────────────────────────────────────────
api_base_url = (
    ((data.get("substitutions") or {}).get("API_BASE_URL") or {}).get("default")
    or "http://localhost:8080"
)

tokens = {
    "PROJECT_ID": project_id,
    "PROJECT_NAME_PASCAL": kebab_to_pascal(project_id),
    "COMPONENT_TYPE": component_type,
    "STORE_DEFAULT": in_memory_store_class(component_type),
    "API_BASE_URL": api_base_url,
}

# Render only tokens declared by the registry — keeps the renderer
# honest if a future registry adds / removes entries.
registered = set(data.get("substitutions") or {})
unknown_tokens = sorted(set(tokens) - registered)
if unknown_tokens:
    die(4, f"renderer carries tokens not in registry substitutions: {unknown_tokens}")
missing_tokens = sorted(registered - set(tokens))
if missing_tokens:
    die(4, f"registry substitutions not handled by renderer: {missing_tokens}")

# ─── Render each catalog entry ───────────────────────────────────────
catalog = data.get("catalog") or []
if not catalog:
    die(4, "registry catalog is empty")

rendered = 0
for entry in catalog:
    name = entry.get("name") or "<unnamed>"
    source_rel = entry.get("source_template_path")
    target_rel = entry.get("target_path")
    if not source_rel or not target_rel:
        die(4, f"catalog entry {name!r} missing source_template_path / target_path")

    source_abs = os.path.join(repo_root, source_rel)
    target_abs = os.path.join(project_root, target_rel)

    if not os.path.isfile(source_abs):
        die(4, f"template file missing on disk: {source_rel}")

    try:
        with open(source_abs, encoding="utf-8") as f:
            content = f.read()
    except OSError as exc:
        die(4, f"could not read template {source_rel}: {exc!s}")

    for token_name, value in tokens.items():
        content = content.replace("${" + token_name + "}", value)

    parent = os.path.dirname(target_abs)
    if parent:
        os.makedirs(parent, exist_ok=True)

    try:
        with open(target_abs, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as exc:
        die(4, f"could not write target {target_rel}: {exc!s}")

    if entry.get("executable") is True:
        current_mode = os.stat(target_abs).st_mode
        os.chmod(
            target_abs,
            current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH,
        )

    rendered += 1

# ─── Machine-readable summary ────────────────────────────────────────
print("result: success")
print(f"rendered_count: {rendered}")
print(f"project_root: {project_root}")
PY
