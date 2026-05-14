#!/usr/bin/env bash
#
# component-fast-audit.sh — P1b slice 4 deterministic compliance gate.
#
# Validates a RENDERED Component Fast Path project root against the
# registry's `audit_rules` and `catalog`. Read-only — never mutates
# files, never runs the smoke script. The smoke script is a separate
# workflow step (P1b slice 5/6) that exercises runtime; this audit
# stays in the same conceptual layer as `git status` and a lint.
#
# Pipeline position (after slice 3):
#
#   catalog (slice 1) -> templates (slice 2) -> render (slice 3)
#                                              -> AUDIT (this slice)
#
# Out of scope:
#   - No workflow YAML / capabilities wiring.
#   - No re-render of templates (compare existing on-disk tree only).
#   - No exit-code on warning-level findings — every check is either
#     PASS or hard FAIL (the registry contract is the contract).
#
# Usage:
#   scripts/workflows/component-fast-audit.sh \
#     --component-type feedback-widget \
#     --project-root /tmp/sandbox/project
#
#   [--registry /alternate/path/to/feedback-widget.yaml]
#
# Exit codes:
#   0   audit passed.
#   2   usage / argument error.
#   3   registry yaml not found.
#   4   registry malformed.
#   5   audit failed (rendered output violates contract).

set -u

COMPONENT_TYPE=""
PROJECT_ROOT=""
REGISTRY_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 --component-type <name> --project-root <path>
     [--registry <yaml-path>]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --component-type)   COMPONENT_TYPE="${2:-}";    shift 2 ;;
    --project-root)     PROJECT_ROOT="${2:-}";      shift 2 ;;
    --registry)         REGISTRY_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) printf 'error: unknown flag: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$COMPONENT_TYPE" ] || { echo "error: --component-type required" >&2; usage; exit 2; }
[ -n "$PROJECT_ROOT" ]   || { echo "error: --project-root required" >&2;   usage; exit 2; }

if [ -n "$REGISTRY_OVERRIDE" ]; then
  REGISTRY="$REGISTRY_OVERRIDE"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  REGISTRY="${REPO_ROOT}/schemas/component-types/${COMPONENT_TYPE}.yaml"
fi

if [ ! -f "$REGISTRY" ]; then
  printf 'error: registry not found: %s\n' "$REGISTRY" >&2
  exit 3
fi
if [ ! -d "$PROJECT_ROOT" ]; then
  printf 'error: project_root not a directory: %s\n' "$PROJECT_ROOT" >&2
  exit 2
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" - "${REGISTRY}" "${COMPONENT_TYPE}" "${PROJECT_ROOT}" <<'PY'
import fnmatch
import os
import re
import sys

import yaml

registry_path, component_type, project_root = sys.argv[1:4]


def die(code, msg):
    print("condition: component_fast_audit_failed")
    print("result: failed")
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


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

audit_rules = data.get("audit_rules") or {}
catalog = data.get("catalog") or []
if not catalog:
    die(4, "registry catalog is empty")

# ── Index every rendered file once so the five check groups can grep
#    in-memory instead of re-walking the tree each time. Skip the
#    common VCS / build directories so a partially-built sandbox does
#    not slow the audit down.
IGNORE_DIRS = {".git", "node_modules", ".next", "obj", "bin", "dist", "build"}
file_index = []  # (rel_path, abs_path, content_text, content_lower)
for root, dirs, names in os.walk(project_root):
    dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
    for name in names:
        abs_path = os.path.join(root, name)
        rel = os.path.relpath(abs_path, project_root).replace(os.sep, "/")
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        file_index.append((rel, abs_path, text, text.lower()))

failures = []
files_checked = 0


def fail(msg):
    failures.append(msg)


# ── Check 1: file existence + executable bit ─────────────────────────
for entry in catalog:
    target_rel = entry.get("target_path")
    if not target_rel:
        continue
    target_abs = os.path.join(project_root, target_rel)
    is_required = entry.get("required") is True
    is_executable = entry.get("executable") is True
    if is_required:
        if not os.path.isfile(target_abs):
            fail(f"required target missing: {target_rel}")
            continue
        if os.path.getsize(target_abs) == 0:
            fail(f"required target empty: {target_rel}")
            continue
        files_checked += 1
    if is_executable and os.path.isfile(target_abs):
        if not os.access(target_abs, os.X_OK):
            fail(f"target should be executable but isn't: {target_rel}")

# ── Check 2: forbidden_terms ────────────────────────────────────────
forbidden_terms = [
    t.lower() for t in (audit_rules.get("forbidden_terms") or [])
    if isinstance(t, str) and t
]
for term in forbidden_terms:
    for rel, _, _, content_lower in file_index:
        if term in content_lower:
            fail(f"forbidden_term '{term}' found in {rel}")
            break  # one hit per term is enough to flag the run

# ── Check 3: forbidden_core_import_patterns ──────────────────────────
for pattern in audit_rules.get("forbidden_core_import_patterns") or []:
    if not isinstance(pattern, str) or ":" not in pattern:
        continue
    glob_part, forbidden = pattern.rsplit(":", 1)
    forbidden_lower = forbidden.strip().lower()
    if not forbidden_lower:
        continue
    for rel, _, _, content_lower in file_index:
        if fnmatch.fnmatch(rel, glob_part) and forbidden_lower in content_lower:
            fail(f"forbidden_core_import_pattern '{pattern}' violated by {rel}")

# ── Check 4: env-driven runtime contract ─────────────────────────────
env_runtime_vars = [
    v for v in (audit_rules.get("env_driven_runtime") or [])
    if isinstance(v, str) and v
]

env_example_path = os.path.join(project_root, ".env.example")
if env_runtime_vars:
    if os.path.isfile(env_example_path):
        with open(env_example_path, encoding="utf-8", errors="replace") as f:
            env_text = f.read()
        for var in env_runtime_vars:
            if not re.search(rf"^\s*{re.escape(var)}\s*=", env_text, re.M):
                fail(f"env_driven_runtime '{var}' missing from .env.example")
    else:
        fail(".env.example missing (cannot verify env_driven_runtime)")

compose_path = os.path.join(project_root, "docker-compose.yml")
if os.path.isfile(compose_path):
    with open(compose_path, encoding="utf-8", errors="replace") as f:
        compose_text = f.read()

    # 4b: each env_driven_runtime var must appear as ${VAR} (or
    # ${VAR:-default} / ${VAR-default}) somewhere in compose. The
    # negative regex below explicitly REJECTS ${VAR_OTHER_NAME} so
    # the check does not silently accept prefix-only matches.
    for var in env_runtime_vars:
        compose_pattern = re.compile(
            rf"\$\{{{re.escape(var)}(?:[:\-+?][^}}]*)?\}}"
        )
        if not compose_pattern.search(compose_text):
            fail(f"docker-compose.yml missing ${{{var}}} interpolation")

    # 4c: hardcoded short-form port mappings for env_driven_runtime
    # variables. Only the ports tied to env_driven_runtime defaults
    # are checked — postgres `5432:5432` for the optional integration
    # runtime is not flagged because POSTGRES_PORT is not in the
    # registry's env_driven_runtime contract. Long-form mappings
    # ({target: N, published: N}) are out of scope for slice 4.
    env_vars_map = {
        env.get("name"): env
        for env in (data.get("env_vars") or [])
        if isinstance(env, dict) and isinstance(env.get("name"), str)
    }
    env_driven_port_defaults = set()
    for var in env_runtime_vars:
        env_def = env_vars_map.get(var)
        if not isinstance(env_def, dict):
            continue
        default = env_def.get("default")
        if isinstance(default, str) and default.isdigit():
            env_driven_port_defaults.add(default)

    try:
        compose_yaml = yaml.safe_load(compose_text) or {}
    except yaml.YAMLError:
        compose_yaml = {}
    hardcoded_port_re = re.compile(r"^(\d+):(\d+)$")
    services = compose_yaml.get("services") or {}
    if isinstance(services, dict):
        for svc_name, svc in services.items():
            if not isinstance(svc, dict):
                continue
            for port_entry in svc.get("ports") or []:
                entry_str = str(port_entry).strip().strip('"').strip("'")
                match = hardcoded_port_re.match(entry_str)
                if not match:
                    continue
                host_port, container_port = match.group(1), match.group(2)
                if (
                    host_port in env_driven_port_defaults
                    or container_port in env_driven_port_defaults
                ):
                    fail(
                        f"docker-compose.yml service '{svc_name}' has "
                        f"hardcoded env-driven port '{entry_str}' "
                        f"(use ${{VAR:-default}})"
                    )

# ── Check 5: secret pattern guard ────────────────────────────────────
HIGH_CONFIDENCE = [
    ("openai-key-shape", re.compile(r"sk-[A-Za-z0-9_\-]{20,}")),
    ("aws-access-key-shape", re.compile(r"AKIA[A-Z0-9]{16}")),
    (
        "pem-private-key",
        re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
    ),
]

# Contextual pattern: `password=...` / `api_key=...` / `apikey=...`.
# The value side is allowlisted against common placeholder shapes so
# `POSTGRES_PASSWORD=change-me` (the .env.example default) does NOT
# trip a finding.
CONTEXTUAL_RE = re.compile(
    r"\b(password|api[-_]?key)\s*=\s*([^\s\"',;]*)", re.I
)
PLACEHOLDER_RE = re.compile(
    r"^(?:change[-_ ]?me|changeme|placeholder|example|todo|tbd|"
    r"your[-_ ].*|<.*>|\$\{[^}]+\})?$",
    re.I,
)


def is_placeholder(value):
    if value is None:
        return True
    return bool(PLACEHOLDER_RE.match(value))


for rel, _, content, _ in file_index:
    for label, pattern in HIGH_CONFIDENCE:
        match = pattern.search(content)
        if match:
            sample = match.group(0)
            if len(sample) > 40:
                sample = sample[:40] + "…"
            fail(f"secret_pattern '{label}' detected in {rel}: {sample}")
    for ctx_match in CONTEXTUAL_RE.finditer(content):
        value = ctx_match.group(2) or ""
        if is_placeholder(value):
            continue
        head = ctx_match.group(0)
        if len(head) > 60:
            head = head[:60] + "…"
        fail(f"non-placeholder credential in {rel}: {head}")

# ── Emit machine-readable result ─────────────────────────────────────
if failures:
    print("condition: component_fast_audit_failed")
    print(f"failure_count: {len(failures)}")
    print("result: failed")
    for f in failures:
        print(f"failure: {f}", file=sys.stderr)
    sys.exit(5)

print("condition: ok")
print(f"rendered_files_checked: {files_checked}")
print("result: success")
PY
