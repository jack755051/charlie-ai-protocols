#!/usr/bin/env bash
#
# test-binder-project-context-origin.sh — Regression test locking the
# v0.25.1 fix for ProjectContextLoader's base_dir vs project_root
# confusion.
#
# Pre-fix bug:
#   RuntimeBinder.__init__ initialised
#     self.project_context_loader = ProjectContextLoader(self.base_dir)
#   so project_id resolution and ledger origin tracking ran against the
#   cap install directory rather than the user's working project. When
#   the global cap wrapper is invoked from outside the install dir, the
#   install dir's basename ("charlie-ai-protocols" by default) collides
#   with any local clone of the dev repo and ProjectContextLoader halts
#   with ProjectIdCollisionError on the SECOND call (the first call from
#   `cap project init` runs through a different code path that reads
#   the user's CWD and wrote a ledger entry pointing at the user's
#   actual project path; subsequent `cap workflow run` invocations then
#   computed current_origin from base_dir and found a mismatch).
#
# Fix (v0.25.1):
#   self.project_context_loader = ProjectContextLoader(self.project_root)
#
# This fixture guards the contract by:
#   Case 1: a binder created with base_dir != project_root resolves
#           project_id from the project_root's basename, NOT base_dir's.
#   Case 2: ledger origin written by such a binder records the
#           project_root's path, so a subsequent verify call from the
#           same project_root succeeds.
#   Case 3: the underlying ProjectContextLoader instance held by the
#           binder is anchored at project_root (introspection-level
#           assertion so the wiring can't silently regress to base_dir).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-binder-origin-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

# ProjectContextLoader writes the identity ledger to
# ${CAP_HOME}/projects/<id>/.identity.json — env var, not a kwarg, so
# we MUST point CAP_HOME at the sandbox to avoid clobbering the real
# user's ~/.cap storage.
export CAP_HOME="${SANDBOX}/cap_home"

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

# Sandbox layout — distinct base_dir and project_root, both under git
# init so _is_inside_git_repo returns True.
PROJECT_ROOT="${SANDBOX}/user-component-repo"
INSTALL_BASE="${SANDBOX}/cap-install"
CAP_HOME_DIR="${SANDBOX}/cap_home"
mkdir -p "${PROJECT_ROOT}" "${INSTALL_BASE}/.cap" "${CAP_HOME_DIR}/shared"
git -C "${PROJECT_ROOT}" init -q
git -C "${INSTALL_BASE}" init -q

# Minimal builtin layer so registry load doesn't fall back to legacy
# adapter (irrelevant to this test but keeps the signal noise low).
cat > "${INSTALL_BASE}/.cap/skills.yaml" <<'EOF'
schema_version: 2
skills: []
EOF

# ── Case 1: project_id derives from project_root, not base_dir ──────
echo "Case 1: project_id resolves from project_root basename"
case1_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${INSTALL_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import json, sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

install_base, project_root, cap_home_dir = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(install_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
ctx = binder.project_context_loader.load()
print(json.dumps({
    "project_id": ctx["project_id"],
    "project_root": ctx["project_root"],
}))
PY
)"
project_id_resolved="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1])["project_id"])
' "${case1_out}")"
project_root_recorded="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1])["project_root"])
' "${case1_out}")"
# Resolve through symlinks the same way ProjectContextLoader does
expected_root="$(cd "${PROJECT_ROOT}" && pwd -P)"
assert_eq "1a. project_id matches project_root basename (not install basename)" \
  "user-component-repo" "${project_id_resolved}"
assert_eq "1b. project_root recorded as the user's working repo path" \
  "${expected_root}" "${project_root_recorded}"

# ── Case 2: ledger origin matches project_root and reverify succeeds ─
echo "Case 2: ledger origin tracks project_root, no collision on reverify"
case2_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${INSTALL_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import json, sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

install_base, project_root, cap_home_dir = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(install_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
# First call writes the ledger; second call hits _verify_or_write_ledger
# again and must NOT raise ProjectIdCollisionError.
binder.project_context_loader.load()
binder2 = RuntimeBinder(
    base_dir=Path(install_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
try:
    binder2.project_context_loader.load()
    print(json.dumps({"ok": True, "error": None}))
except Exception as exc:
    print(json.dumps({"ok": False, "error": type(exc).__name__}))

# Read the ledger to confirm origin_path
ledger = Path(cap_home_dir) / "projects" / "user-component-repo" / ".identity.json"
import json as _json
data = _json.loads(ledger.read_text())
print(data.get("origin_path", ""))
PY
)"
verify_status="$(printf '%s' "${case2_out}" | sed -n '1p')"
ledger_origin="$(printf '%s' "${case2_out}" | sed -n '2p')"
verify_ok="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1])["ok"])
' "${verify_status}")"
expected_origin="$(cd "${PROJECT_ROOT}" && pwd -P)"
assert_eq "2a. second binder load succeeds (no collision)" "True" "${verify_ok}"
assert_eq "2b. ledger origin_path equals project_root (not install path)" \
  "${expected_origin}" "${ledger_origin}"

# ── Case 3: introspection — loader.base_dir IS project_root ─────────
echo "Case 3: ProjectContextLoader.base_dir wired to project_root"
case3_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${INSTALL_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

install_base, project_root, cap_home_dir = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(install_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
loader_base = str(binder.project_context_loader.base_dir.resolve())
expected = str(Path(project_root).resolve())
print("MATCH" if loader_base == expected else f"DIFF loader={loader_base} expected={expected}")
PY
)"
assert_eq "3. project_context_loader.base_dir == project_root.resolve()" \
  "MATCH" "${case3_out}"

# ── Case 4: workflow_cli production path passes project_root=cwd ────
# This is the call path that broke on the v0.25.0 dogfood run. The
# pure RuntimeBinder constructor fix in v0.25.1 was necessary but not
# sufficient — workflow_cli.py three call sites (cmd_plan / cmd_bind /
# cmd_build_bound_plan) used to call RuntimeBinder(base_dir=base_dir)
# only, which falls back to project_root=base_dir when base_dir is
# explicit. Production-grade fix is to pass project_root=Path.cwd()
# from those call sites; this test pins the contract by greping the
# source file (cheap, no exec needed) plus running cmd_build_bound_plan
# end-to-end in the sandbox so a future refactor that reverts to the
# bare base_dir form fails immediately.
echo "Case 4: workflow_cli production paths thread project_root=cwd"
cli_path="${REPO_ROOT}/engine/workflow_cli.py"
bare_calls="$(grep -c "RuntimeBinder(base_dir=base_dir)$" "${cli_path}" || true)"
threaded_calls="$(grep -c "RuntimeBinder(base_dir=base_dir, project_root=Path.cwd())" "${cli_path}" || true)"
assert_eq "4a. workflow_cli has zero bare RuntimeBinder(base_dir=base_dir) calls" \
  "0" "${bare_calls}"
assert_eq "4b. workflow_cli has three RuntimeBinder(...,project_root=Path.cwd()) calls" \
  "3" "${threaded_calls}"

# End-to-end: invoke cmd_build_bound_plan from the sandbox project_root
# and confirm it does NOT raise ProjectIdCollisionError. Uses a
# trivial workflow ref that exists in the install layer; the goal is
# not to exercise the workflow itself, just to prove the binding path
# loads project context without halting.
set +e
case4c_out="$(cd "${PROJECT_ROOT}" && CAP_HOME="${CAP_HOME}" PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${REPO_ROOT}" 2>&1 <<'PY'
import sys
repo_root = sys.argv[1]
sys.path.insert(0, repo_root)
sys.path.insert(0, repo_root + "/engine")
import io, contextlib
from engine.workflow_cli import cmd_build_bound_plan
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        cmd_build_bound_plan(repo_root, "project-constitution")
    print("HALT_FREE")
except Exception as exc:
    name = type(exc).__name__
    print(f"HALTED:{name}")
PY
)"
set -e 2>/dev/null || true
case4c_status="$(printf '%s' "${case4c_out}" | grep -oE 'HALT_FREE|HALTED:[A-Za-z]+' | head -1)"
assert_eq "4c. cmd_build_bound_plan does not raise ProjectIdCollisionError" \
  "HALT_FREE" "${case4c_status}"

echo ""
total=$((pass_count + fail_count))
echo "binder-project-context-origin: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
