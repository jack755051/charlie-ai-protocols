#!/usr/bin/env bash
#
# bootstrap-constitution-defaults.sh — Pipeline step: emit platform-level
# defaults that the upstream `draft_constitution` AI step cannot reasonably
# guess from a free-form user prompt.
#
# Reads:
#   - schemas/project-constitution.schema.yaml   (required field list)
#   - schemas/capabilities.yaml                  (allowed_capabilities)
#   - repo structure                             (source_of_truth defaults)
#
# Emits a markdown artifact that downstream draft_constitution step picks up
# as the `platform_defaults` input. The markdown is also wrapped with two
# fenced sections so the AI can copy them verbatim into the constitution JSON
# without re-deriving values.
#
# Exit code contract (docs/policies/workflow-executor-exit-codes.md):
#   - 0  : success — defaults emitted
#   - 40 : git_operation_failed (re-used: schema/capabilities file missing)
#
# This step is purely deterministic; it does not consult the user prompt.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-bootstrap_constitution_defaults}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

SCHEMA_PATH="${CAP_ROOT}/schemas/project-constitution.schema.yaml"
CAPS_PATH="${CAP_ROOT}/schemas/capabilities.yaml"
VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

fail_with() {
  local reason="$1"
  shift
  printf 'condition: git_operation_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

[ -f "${SCHEMA_PATH}" ] || fail_with "schema_missing" "expected: ${SCHEMA_PATH}"
[ -f "${CAPS_PATH}" ]   || fail_with "capabilities_missing" "expected: ${CAPS_PATH}"

# Repo-relative project_id default: resolve from cap-paths if the helper exists,
# otherwise fall back to the basename of CAP_ROOT (sanitized).
default_project_id() {
  local candidate=""
  if [ -x "${CAP_ROOT}/scripts/cap-paths.sh" ]; then
    candidate="$(bash "${CAP_ROOT}/scripts/cap-paths.sh" get project_id 2>/dev/null || true)"
  fi
  if [ -z "${candidate}" ]; then
    candidate="$(basename "${CAP_ROOT}")"
  fi
  printf '%s' "${candidate}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# Pull required fields out of the schema YAML.
required_fields_block() {
  "${PYTHON_BIN}" - "${SCHEMA_PATH}" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
req = data.get("required") or []
for name in req:
    print(f"  - {name}")
PY
}

# Pull allowed_capabilities out of capabilities.yaml. We list every capability
# whose binding_policy.default_agent is not "shell" (i.e. the AI-bound ones)
# plus the new shell-bound bootstrap/validation/persistence trio so the
# project's binding_policy.allowed_capabilities is complete.
allowed_capabilities_block() {
  "${PYTHON_BIN}" - "${CAPS_PATH}" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
caps = (data.get("capabilities") or {})
for name in caps.keys():
    print(f"  - {name}")
PY
}

PROJECT_ID="$(default_project_id)"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── emit artifact ──

cat <<HEADER
# ${step_id}

## Platform Defaults for Project Constitution Bootstrap

> Deterministic defaults derived from \`schemas/project-constitution.schema.yaml\`
> and \`schemas/capabilities.yaml\`. The downstream \`draft_constitution\` AI
> step MUST copy these blocks into the constitution JSON verbatim (it may
> override \`project_id\` / \`name\` / \`summary\` / \`project_goal\` based on
> the user prompt, but every governance field below is non-negotiable unless
> the user explicitly asks for a different value).

- generated_at: ${TIMESTAMP}
- schema_path: ${SCHEMA_PATH}
- capabilities_path: ${CAPS_PATH}
- default_project_id_seed: ${PROJECT_ID}

## Required Fields (from schema)

These keys MUST appear in the constitution JSON (top-level). Missing any
of them will fail \`validate_constitution\` and halt the workflow:

$(required_fields_block)

## Recommended Defaults

The draft step should embed the following blocks unmodified unless the user
prompt demands a different convention. Copy each YAML/JSON block into the
constitution JSON output and translate to JSON form. **Only \`name\`,
\`summary\`, \`project_goal\`, \`constitution_id\`, and \`project_id\` are
free-form derived from the user prompt.**

### source_of_truth (verbatim)

\`\`\`yaml
source_of_truth:
  project_constitution: .cap.constitution.yaml
  project_config: .cap.project.yaml
  skill_registry: .cap.skills.yaml
  agent_registry: .cap.agents.json
  builtin_workflows_dir: schemas/workflows
  builtin_capabilities: schemas/capabilities.yaml
\`\`\`

### runtime_workspace (verbatim)

\`\`\`yaml
runtime_workspace:
  root: ~/.cap/projects/<project_id>/
  stores:
    - constitutions
    - compiled-workflows
    - bindings
    - workspace
    - traces
    - logs
    - reports
    - sessions
    - drafts
\`\`\`

### binding_policy (verbatim defaults; allowed_capabilities full list)

\`\`\`yaml
binding_policy:
  defaults:
    binding_mode: fallback_allowed
    missing_policy: manual
  allowed_capabilities:
$(allowed_capabilities_block)
\`\`\`

### workflow_policy (verbatim)

\`\`\`yaml
workflow_policy:
  enforce_allowed_source_roots: true
  allowed_source_roots:
    - schemas/workflows
    - workflows
    - docs/workflows
\`\`\`

### executor_policy (verbatim defaults)

\`\`\`yaml
executor_policy:
  deterministic_first: true
  ai_on_ambiguity: true
  halt_on_risk: true
  allowed_providers:
    - claude
    - codex
\`\`\`

## ID Conventions

- \`schema_version\`: integer literal \`1\`
- \`constitution_id\`: kebab-case, derived from \`project_id\` plus
  \`-constitution\` (e.g. \`stt-pipeline-constitution\`); MUST be stable
  across revisions of the same project.
- \`project_id\`: kebab-case, lowercase; the AI step may infer this from the
  user prompt if no explicit name is given. Default seed: \`${PROJECT_ID}\`.

## Output Contract for Draft Step

The downstream \`draft_constitution\` step MUST:

1. Emit a single JSON object wrapped between
   \`<<<CONSTITUTION_JSON_BEGIN>>>\` and \`<<<CONSTITUTION_JSON_END>>>\`
   fences. This is the **only** authoritative format; ad-hoc \`\`\`json
   blocks may exist for examples but the validator will reject the artifact
   if the explicit fence pair is missing.
2. Include every required field listed above.
3. Embed \`source_of_truth\`, \`runtime_workspace\`, \`binding_policy\`,
   \`workflow_policy\`, and \`executor_policy\` exactly as specified, unless
   the user prompt explicitly overrides a key.

## 交接摘要

- agent_id: shell-bootstrap-constitution-defaults
- task_summary: emit deterministic platform defaults for project-constitution bootstrap
- output_paths:
  - ${CAP_WORKFLOW_OUTPUT_PATH:-stdout}
- result: success
HEADER

exit 0
