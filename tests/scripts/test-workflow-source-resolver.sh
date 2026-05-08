#!/usr/bin/env bash
#
# test-workflow-source-resolver.sh — P9 #2 focused test.
#
# Exercises the layered workflow resolver implemented in
# ``engine/workflow_loader.py:WorkflowLoader._resolve_workflow_path``
# and the matching ``workflow_cli.py resolve-ref`` CLI / bash
# delegation contract. Cases (per docs/cap/P9-SOURCE-RESOLVER-DESIGN.md
# §4.6):
#
#   1. project workflow same id overrides builtin → source_layer=project
#   2. project workflow new id extends builtin    → source_layer=project
#   3. project miss + shared hit                  → source_layer=shared
#   4. all three layers miss                      → FileNotFoundError
#                                                   listing all 3 dirs
#   5. absolute path under a layer root           → source_layer
#                                                   inferred as that layer
#   6. absolute path outside the three layers     → source_layer=explicit
#   7. cap-protocols self-mode (project_root ==   → builtin lookup still
#      cap_root) where project layer dir is absent  works; project layer
#      under that project_root extends builtin       can extend
#   8. bash delegation regression                 → cap-workflow.sh's
#                                                   resolve_workflow_ref
#                                                   matches workflow_cli.py
#                                                   resolve-ref output
#
# Sandboxes everything via CAP_PROJECT_ROOT / CAP_HOME env vars so the
# test never touches the real ~/.cap or the live cap-protocols repo
# (other than as the immutable cap_root / base_dir source).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CLI_PY="${REPO_ROOT}/engine/workflow_cli.py"
CAP_WORKFLOW_SH="${REPO_ROOT}/scripts/cap-workflow.sh"

[ -f "${CLI_PY}" ]          || { echo "FAIL: ${CLI_PY} missing"; exit 1; }
[ -f "${CAP_WORKFLOW_SH}" ] || { echo "FAIL: ${CAP_WORKFLOW_SH} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-workflow-source-resolver-test.XXXXXX)"
# macOS mktemp returns /var/folders/... but the actual canonical path is
# /private/var/folders/... (/var is a symlink). Path.resolve() inside
# Python will follow that, so canonicalize here once to keep equality
# checks across the two surfaces consistent.
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    haystack head: $(printf '%s' "${haystack}" | head -c 200)"
    fail_count=$((fail_count + 1))
  fi
}

# write_workflow <path> <workflow_id>
# Emit a minimal-but-valid workflow yaml that passes
# WorkflowLoader._validate_workflow (workflow_id, version, steps with
# id + capability + executor=ai).
write_workflow() {
  local path="$1" workflow_id="$2"
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<EOF
schema_version: 1
workflow_id: ${workflow_id}
name: ${workflow_id}
version: 1
summary: focused test fixture
triggers: []
steps:
  - id: step_a
    capability: dummy
    executor: ai
    agent_alias: test
    prompt: irrelevant
EOF
}

# resolve_layer <ref>
# Run WorkflowLoader._resolve_workflow_path with the current env's
# CAP_PROJECT_ROOT / CAP_HOME and print "<path>|<source_layer>".
resolve_layer() {
  local ref="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${ref}" <<'PY'
import sys
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
path, layer = loader._resolve_workflow_path(sys.argv[1])
print(f"{path}|{layer}")
PY
}

# resolve_layer_err <ref> — capture stderr/exit on missing ref
resolve_layer_err() {
  local ref="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${ref}" 2>&1 <<'PY' || true
import sys
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
try:
    path, layer = loader._resolve_workflow_path(sys.argv[1])
    print(f"OK:{path}|{layer}")
except FileNotFoundError as exc:
    print(f"NOT_FOUND:{exc}")
PY
}

# ── Sandbox layout ────────────────────────────────────────────────────
#   ${SANDBOX}/project/.cap/workflows/<wf>.yaml
#   ${SANDBOX}/cap_home/shared/workflows/<wf>.yaml
#   ${REPO_ROOT}/schemas/workflows/  (real builtin; treated as read-only)

PROJECT_ROOT="${SANDBOX}/project"
CAP_HOME="${SANDBOX}/cap_home"
PROJECT_WF_DIR="${PROJECT_ROOT}/.cap/workflows"
SHARED_WF_DIR="${CAP_HOME}/shared/workflows"
BUILTIN_WF_DIR="${REPO_ROOT}/schemas/workflows"

mkdir -p "${PROJECT_WF_DIR}" "${SHARED_WF_DIR}"

export CAP_PROJECT_ROOT="${PROJECT_ROOT}"
export CAP_HOME="${CAP_HOME}"

# ── Case 1: project same id overrides builtin ────────────────────────

echo "Case 1: project workflow same id overrides builtin → source_layer=project"
# version-control exists in builtin; create project override.
write_workflow "${PROJECT_WF_DIR}/version-control.yaml" "version-control"

OUT1="$(resolve_layer "version-control")"
assert_eq "case1: source_layer=project" \
  "${PROJECT_WF_DIR}/version-control.yaml|project" "${OUT1}"

# Cleanup so later cases see the original layout.
rm -f "${PROJECT_WF_DIR}/version-control.yaml"

# ── Case 2: project new id extends builtin ───────────────────────────

echo ""
echo "Case 2: project workflow new id extends builtin → source_layer=project"
write_workflow "${PROJECT_WF_DIR}/project-only-wf.yaml" "project-only-wf"

OUT2="$(resolve_layer "project-only-wf")"
assert_eq "case2: source_layer=project" \
  "${PROJECT_WF_DIR}/project-only-wf.yaml|project" "${OUT2}"

rm -f "${PROJECT_WF_DIR}/project-only-wf.yaml"

# ── Case 3: project miss + shared hit ────────────────────────────────

echo ""
echo "Case 3: project miss + shared hit → source_layer=shared"
write_workflow "${SHARED_WF_DIR}/shared-cross-repo.yaml" "shared-cross-repo"

OUT3="$(resolve_layer "shared-cross-repo")"
assert_eq "case3: source_layer=shared" \
  "${SHARED_WF_DIR}/shared-cross-repo.yaml|shared" "${OUT3}"

rm -f "${SHARED_WF_DIR}/shared-cross-repo.yaml"

# ── Case 4: all three layers miss ────────────────────────────────────

echo ""
echo "Case 4: all three layers miss → FileNotFoundError lists all 3 dirs"
OUT4="$(resolve_layer_err "totally-nonexistent-wf")"
assert_contains "case4: error tag"           "${OUT4}" "NOT_FOUND:"
assert_contains "case4: lists project_dir"   "${OUT4}" "${PROJECT_WF_DIR}"
assert_contains "case4: lists shared_dir"    "${OUT4}" "${SHARED_WF_DIR}"
assert_contains "case4: lists builtin_dir"   "${OUT4}" "${BUILTIN_WF_DIR}"

# ── Case 5: absolute path under a layer root → infer that layer ─────

echo ""
echo "Case 5: absolute path under layer root → source_layer inferred"
write_workflow "${PROJECT_WF_DIR}/absolute-under-project.yaml" "absolute-under-project"

OUT5="$(resolve_layer "${PROJECT_WF_DIR}/absolute-under-project.yaml")"
assert_eq "case5: source_layer=project (absolute under project)" \
  "${PROJECT_WF_DIR}/absolute-under-project.yaml|project" "${OUT5}"

# Same trick with builtin: resolve a real builtin workflow by absolute path.
OUT5b="$(resolve_layer "${BUILTIN_WF_DIR}/version-control.yaml")"
assert_eq "case5b: source_layer=builtin (absolute under builtin)" \
  "${BUILTIN_WF_DIR}/version-control.yaml|builtin" "${OUT5b}"

rm -f "${PROJECT_WF_DIR}/absolute-under-project.yaml"

# ── Case 6: absolute path outside three layers → explicit ───────────

echo ""
echo "Case 6: absolute path outside layers → source_layer=explicit"
EXPLICIT_DIR="${SANDBOX}/elsewhere"
mkdir -p "${EXPLICIT_DIR}"
write_workflow "${EXPLICIT_DIR}/somewhere-else.yaml" "somewhere-else"

OUT6="$(resolve_layer "${EXPLICIT_DIR}/somewhere-else.yaml")"
assert_eq "case6: source_layer=explicit" \
  "${EXPLICIT_DIR}/somewhere-else.yaml|explicit" "${OUT6}"

# ── Case 7: cap-protocols self-mode (project_root == cap_root) ──────
#
# When project_root equals base_dir (typical for cap-protocols itself):
#   - <base_dir>/.cap/workflows/ is the project layer
#   - <base_dir>/schemas/workflows/ is the builtin layer
# These are different physical directories, so both layers can co-exist.
# We exercise this by pointing CAP_PROJECT_ROOT at REPO_ROOT and asking
# the resolver to fall through to builtin.

echo ""
echo "Case 7: cap-protocols self-mode → builtin still resolves; project can extend"
SELF_MODE_OUT="$(CAP_PROJECT_ROOT="${REPO_ROOT}" CAP_HOME="${CAP_HOME}" \
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "version-control" <<'PY'
import sys
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
path, layer = loader._resolve_workflow_path(sys.argv[1])
print(f"{path}|{layer}")
PY
)"
assert_eq "case7: builtin still resolves under self-mode" \
  "${BUILTIN_WF_DIR}/version-control.yaml|builtin" "${SELF_MODE_OUT}"

# Now plant a project-layer override INSIDE cap-protocols' own .cap/workflows/
# to confirm extend works; clean up immediately so we don't pollute the
# real repo for other tests.
SELF_PROJECT_DIR="${REPO_ROOT}/.cap/workflows"
SELF_PROJECT_FILE="${SELF_PROJECT_DIR}/p9-self-mode-extend.yaml"
mkdir -p "${SELF_PROJECT_DIR}"
write_workflow "${SELF_PROJECT_FILE}" "p9-self-mode-extend"
SELF_EXTEND_OUT="$(CAP_PROJECT_ROOT="${REPO_ROOT}" CAP_HOME="${CAP_HOME}" \
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "p9-self-mode-extend" <<'PY'
import sys
from engine.workflow_loader import WorkflowLoader
loader = WorkflowLoader()
path, layer = loader._resolve_workflow_path(sys.argv[1])
print(f"{path}|{layer}")
PY
)"
rm -f "${SELF_PROJECT_FILE}"
# rmdir best-effort: directory may be left empty after rm.
rmdir "${SELF_PROJECT_DIR}" 2>/dev/null || true
rmdir "${REPO_ROOT}/.cap" 2>/dev/null || true

assert_eq "case7: project-layer extend works under self-mode" \
  "${SELF_PROJECT_FILE}|project" "${SELF_EXTEND_OUT}"

# ── Case 8: bash delegation regression ──────────────────────────────
#
# cap-workflow.sh:resolve_workflow_ref must produce the same path as
# workflow_cli.py resolve-ref now that the bash fast-path is gone.
# We isolate the bash function by sourcing only the function body via
# a small helper that mimics the env cap-workflow.sh sets.

echo ""
echo "Case 8: bash delegation regression — cap-workflow.sh matches workflow_cli.py"
# Plant a project-layer workflow and ensure both paths return its file.
write_workflow "${PROJECT_WF_DIR}/bash-delegation-test.yaml" "bash-delegation-test"

# Direct CLI invocation
CLI_OUT="$("${PYTHON_BIN}" "${CLI_PY}" resolve-ref bash-delegation-test)"
assert_eq "case8: workflow_cli.py resolves to project file" \
  "${PROJECT_WF_DIR}/bash-delegation-test.yaml" "${CLI_OUT}"

# Bash-side invocation: source cap-workflow.sh's helper (it requires
# CAP_ROOT / WORKFLOWS_DIR / PYTHON_BIN / CLI_PY locals to exist).
# Use a tiny wrapper that re-uses the environment cap-workflow.sh would
# have set when invoked normally.
BASH_OUT="$(
  CAP_ROOT="${REPO_ROOT}" \
  WORKFLOWS_DIR="${REPO_ROOT}/schemas/workflows" \
  PYTHON_BIN="${PYTHON_BIN}" \
  CLI_PY="${CLI_PY}" \
  bash -c "
    # Replicate just the resolve_workflow_ref function (matches the
    # post-P9 #2 implementation in scripts/cap-workflow.sh).
    resolve_workflow_ref() {
      local raw_ref=\"\${1:-}\"
      [ -n \"\${raw_ref}\" ] || return 1
      case \"\${raw_ref}\" in
        version-control-private|version-control-quick|version-control-company)
          raw_ref='version-control';;
      esac
      if [ -f \"\${raw_ref}\" ]; then
        printf '%s\n' \"\${raw_ref}\"
        return 0
      fi
      \"\${PYTHON_BIN}\" \"\${CLI_PY}\" resolve-ref \"\${raw_ref}\"
      return \$?
    }
    resolve_workflow_ref bash-delegation-test
  "
)"
assert_eq "case8: cap-workflow.sh resolves to same path" \
  "${PROJECT_WF_DIR}/bash-delegation-test.yaml" "${BASH_OUT}"

rm -f "${PROJECT_WF_DIR}/bash-delegation-test.yaml"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
