#!/usr/bin/env bash
#
# test-cap-config-namespace-readers.sh — P0c Config Namespace Migration
# batch 2.5 reader gate (skills / agents / constitution surfaces).
#
# Verifies that the four secondary readers (in addition to the project_id
# resolver covered by test-cap-config-namespace-resolver.sh) honor the
# dual-path contract: prefer .cap/<name> when present, fall back to legacy
# .cap.<name> flat-file. When both happen to exist, new namespace wins.
#
# Surfaces under test:
#
#   Reader E — engine/runtime_binder.py
#     E1. .cap/skills.yaml only         → load_skill_registry uses new
#     E2. .cap.skills.yaml only         → load_skill_registry uses legacy
#     E3. both present                  → new wins (legacy ignored)
#     E4. neither + .cap/agents.json    → adapter consults new agents path
#     E5. neither + .cap.agents.json    → adapter consults legacy agents path
#     E6. neither + both agents files   → adapter prefers new agents path
#
#   Reader F — engine/workflow_loader.py
#     F1. .cap/agents.json only         → agents_path resolves to new
#     F2. .cap.agents.json only         → agents_path resolves to legacy
#     F3. both present                  → new wins
#
#   Reader G — scripts/cap-registry.sh
#     G1. .cap/agents.json only         → REGISTRY_FILE points to new
#     G2. .cap.agents.json only         → REGISTRY_FILE points to legacy
#     G3. both present                  → REGISTRY_FILE points to new
#
#   Reader H — engine/step_runtime.py:_read_constitution_design_source
#     H1. .cap/constitution.yaml only   → returns block from new
#     H2. .cap.constitution.yaml only   → returns block from legacy
#     H3. both present                  → returns block from new

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_BINDER="${REPO_ROOT}/engine/runtime_binder.py"
WORKFLOW_LOADER="${REPO_ROOT}/engine/workflow_loader.py"
CAP_REGISTRY_SH="${REPO_ROOT}/scripts/cap-registry.sh"
STEP_RUNTIME="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${RUNTIME_BINDER}" ]   || { echo "FAIL: engine/runtime_binder.py missing"; exit 1; }
[ -f "${WORKFLOW_LOADER}" ]  || { echo "FAIL: engine/workflow_loader.py missing"; exit 1; }
[ -f "${CAP_REGISTRY_SH}" ]  || { echo "FAIL: scripts/cap-registry.sh missing"; exit 1; }
[ -f "${STEP_RUNTIME}" ]     || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-cfg-readers-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_neq() {
  local desc="$1" forbidden="$2" actual="$3"
  if [ "${forbidden}" = "${actual}" ]; then
    echo "  FAIL: ${desc}"
    echo "    must not equal: ${forbidden}"
    echo "    actual:         ${actual}"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  fi
}

# Helpers ---------------------------------------------------------------

# Build a sandbox repo with seeded .cap/<file> and/or .cap.<file>.
# Args: $1 sandbox subdir name; $2 = csv of seed kinds:
#   skills_new, skills_legacy, agents_new, agents_legacy,
#   constitution_new, constitution_legacy
build_sandbox() {
  local name="$1" kinds="$2"
  local root="${SANDBOX}/${name}"
  mkdir -p "${root}"
  # The runtime_binder legacy-agents adapter path calls
  # WorkflowLoader.load_capabilities(), which needs schemas/capabilities.yaml
  # under the base_dir. Symlink the repo's schemas dir into the sandbox so
  # the adapter can resolve capability metadata. Cases that don't traverse
  # the adapter still benefit from a present (unused) schemas tree.
  ln -s "${REPO_ROOT}/schemas" "${root}/schemas"
  case ",${kinds}," in *",skills_new,"*)
    mkdir -p "${root}/.cap"
    cat > "${root}/.cap/skills.yaml" <<'EOF'
schema_version: 1
default_provider: builtin
skills:
  - skill_id: alpha-new
    capability: ping
    provider: builtin
EOF
  ;; esac
  case ",${kinds}," in *",skills_legacy,"*)
    cat > "${root}/.cap.skills.yaml" <<'EOF'
schema_version: 1
default_provider: builtin
skills:
  - skill_id: alpha-legacy
    capability: ping
    provider: builtin
EOF
  ;; esac
  case ",${kinds}," in *",agents_new,"*)
    mkdir -p "${root}/.cap"
    cat > "${root}/.cap/agents.json" <<'EOF'
{"agents": {"sentinel": {"prompt_file": "agent-skills/01-supervisor-agent.md", "provider": "builtin", "_marker": "agents_new"}}}
EOF
  ;; esac
  case ",${kinds}," in *",agents_legacy,"*)
    cat > "${root}/.cap.agents.json" <<'EOF'
{"agents": {"sentinel": {"prompt_file": "agent-skills/01-supervisor-agent.md", "provider": "builtin", "_marker": "agents_legacy"}}}
EOF
  ;; esac
  case ",${kinds}," in *",constitution_new,"*)
    mkdir -p "${root}/.cap"
    cat > "${root}/.cap/constitution.yaml" <<'EOF'
constitution_id: namespaced-cons
design_source:
  type: local
  source_path: /tmp/from-new-namespace
EOF
  ;; esac
  case ",${kinds}," in *",constitution_legacy,"*)
    cat > "${root}/.cap.constitution.yaml" <<'EOF'
constitution_id: legacy-cons
design_source:
  type: local
  source_path: /tmp/from-legacy
EOF
  ;; esac
  printf '%s\n' "${root}"
}

# ── Reader E: runtime_binder skill registry ─────────────────────────────

echo "Reader E: engine/runtime_binder.py — load_skill_registry"

run_binder_skills() {
  local root="$1"
  ( cd "${REPO_ROOT}" && python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'engine')
from runtime_binder import RuntimeBinder
binder = RuntimeBinder(base_dir=Path('${root}'))
reg = binder.load_skill_registry()
print('source_path=' + reg.get('_source_path', ''))
print('adapter=' + str(reg.get('_adapter_from_legacy', False)))
for s in reg.get('skills', []):
    print('skill_id=' + s.get('skill_id', ''))
" 2>&1 )
}

echo "Case E1: .cap/skills.yaml only"
E1="$(build_sandbox e1 skills_new)"
out_e1="$(run_binder_skills "${E1}")"
assert_contains "E1 source is namespaced path" ".cap/skills.yaml"  "${out_e1}"
assert_contains "E1 alpha-new loaded"          "skill_id=alpha-new" "${out_e1}"

echo "Case E2: .cap.skills.yaml only"
E2="$(build_sandbox e2 skills_legacy)"
out_e2="$(run_binder_skills "${E2}")"
assert_contains "E2 source is legacy path"     ".cap.skills.yaml"  "${out_e2}"
assert_contains "E2 alpha-legacy loaded"       "skill_id=alpha-legacy" "${out_e2}"

echo "Case E3: both present → new wins"
E3="$(build_sandbox e3 skills_new,skills_legacy)"
out_e3="$(run_binder_skills "${E3}")"
assert_contains "E3 source is namespaced path" ".cap/skills.yaml"  "${out_e3}"
assert_contains "E3 alpha-new wins"            "skill_id=alpha-new" "${out_e3}"
case "${out_e3}" in
  *alpha-legacy*) echo "  FAIL: E3 legacy leaked"; fail_count=$((fail_count + 1)) ;;
  *)              echo "  PASS: E3 legacy does not leak"; pass_count=$((pass_count + 1)) ;;
esac

echo "Case E4: no skills + .cap/agents.json → legacy adapter consults new agents path"
E4="$(build_sandbox e4 agents_new)"
out_e4="$(run_binder_skills "${E4}")"
assert_contains "E4 adapter from legacy"        "adapter=True"        "${out_e4}"
assert_contains "E4 sources from .cap/agents"   ".cap/agents.json"    "${out_e4}"

echo "Case E5: no skills + .cap.agents.json → adapter consults legacy agents path"
E5="$(build_sandbox e5 agents_legacy)"
out_e5="$(run_binder_skills "${E5}")"
assert_contains "E5 adapter from legacy"        "adapter=True"        "${out_e5}"
assert_contains "E5 sources from .cap.agents"   ".cap.agents.json"    "${out_e5}"

echo "Case E6: no skills + both agents files → adapter prefers new agents"
E6="$(build_sandbox e6 agents_new,agents_legacy)"
out_e6="$(run_binder_skills "${E6}")"
assert_contains "E6 adapter sources from new"   ".cap/agents.json"    "${out_e6}"
case "${out_e6}" in
  *.cap.agents.json*) echo "  FAIL: E6 legacy agents leaked into source path"; fail_count=$((fail_count + 1)) ;;
  *)                  echo "  PASS: E6 legacy agents path does not leak"; pass_count=$((pass_count + 1)) ;;
esac

# ── Reader F: workflow_loader agents path ───────────────────────────────

echo ""
echo "Reader F: engine/workflow_loader.py — agents_path resolution"

run_loader_agents() {
  local root="$1"
  ( cd "${REPO_ROOT}" && python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'engine')
from workflow_loader import WorkflowLoader
loader = WorkflowLoader(base_dir=Path('${root}'))
print('agents_path=' + str(loader.agents_path))
try:
    agents = loader.load_agents()
    for alias, meta in agents.items():
        print('marker=' + str(meta.get('_marker', '')))
except FileNotFoundError as exc:
    print('ERROR=' + str(exc))
" 2>&1 )
}

echo "Case F1: .cap/agents.json only"
F1="$(build_sandbox f1 agents_new)"
out_f1="$(run_loader_agents "${F1}")"
assert_contains "F1 agents_path is new"        ".cap/agents.json"  "${out_f1}"
assert_contains "F1 marker is agents_new"      "marker=agents_new" "${out_f1}"

echo "Case F2: .cap.agents.json only"
F2="$(build_sandbox f2 agents_legacy)"
out_f2="$(run_loader_agents "${F2}")"
assert_contains "F2 agents_path is legacy"     ".cap.agents.json"     "${out_f2}"
assert_contains "F2 marker is agents_legacy"   "marker=agents_legacy" "${out_f2}"

echo "Case F3: both present → new wins"
F3="$(build_sandbox f3 agents_new,agents_legacy)"
out_f3="$(run_loader_agents "${F3}")"
assert_contains "F3 agents_path is new"        ".cap/agents.json"  "${out_f3}"
assert_contains "F3 marker is agents_new"      "marker=agents_new" "${out_f3}"

# ── Reader G: cap-registry.sh ───────────────────────────────────────────

echo ""
echo "Reader G: scripts/cap-registry.sh — REGISTRY_FILE resolution"

# cap-registry.sh resolves CAP_ROOT relative to the script's own location,
# so we cannot relocate the script itself. Instead we override the registry
# paths by testing whether the dispatcher prints the same registry data the
# Python loader sees. Easiest reliable check: spawn cap-registry.sh in a
# sandbox that contains both files, then verify which file content was
# printed by the `show` subcommand.
#
# We sandbox by overwriting the in-repo .cap and .cap.agents.json files for
# the duration of the test, then restoring on exit. This is the only way
# to exercise cap-registry.sh's actual lookup precedence end-to-end without
# refactoring the script. Use a unique sentinel marker per case so we can
# tell them apart.

readonly REPO_NAMESPACED="${REPO_ROOT}/.cap/agents.json"
readonly REPO_LEGACY="${REPO_ROOT}/.cap.agents.json"

# Snapshot any existing files so we restore them on exit.
SNAPSHOT_DIR="${SANDBOX}/cap-registry-snapshot"
mkdir -p "${SNAPSHOT_DIR}"
[ -f "${REPO_NAMESPACED}" ] && cp "${REPO_NAMESPACED}" "${SNAPSHOT_DIR}/agents.json.namespaced.bak"
[ -f "${REPO_LEGACY}" ]     && cp "${REPO_LEGACY}"     "${SNAPSHOT_DIR}/agents.json.legacy.bak"
[ -d "${REPO_ROOT}/.cap" ]  && touch "${SNAPSHOT_DIR}/.cap.was.dir"

restore_repo_registry() {
  rm -f "${REPO_NAMESPACED}" "${REPO_LEGACY}"
  if [ -f "${SNAPSHOT_DIR}/agents.json.namespaced.bak" ]; then
    mkdir -p "${REPO_ROOT}/.cap"
    cp "${SNAPSHOT_DIR}/agents.json.namespaced.bak" "${REPO_NAMESPACED}"
  elif [ ! -f "${SNAPSHOT_DIR}/.cap.was.dir" ]; then
    rmdir "${REPO_ROOT}/.cap" 2>/dev/null || true
  fi
  if [ -f "${SNAPSHOT_DIR}/agents.json.legacy.bak" ]; then
    cp "${SNAPSHOT_DIR}/agents.json.legacy.bak" "${REPO_LEGACY}"
  fi
}
trap 'restore_repo_registry; rm -rf "${SANDBOX}"' EXIT

write_repo_namespaced() {
  mkdir -p "${REPO_ROOT}/.cap"
  cat > "${REPO_NAMESPACED}" <<EOF
{"agents": {"sentinel": {"prompt_file": "agent-skills/01-supervisor-agent.md", "provider": "builtin", "_marker": "$1"}}}
EOF
}

write_repo_legacy() {
  cat > "${REPO_LEGACY}" <<EOF
{"agents": {"sentinel": {"prompt_file": "agent-skills/01-supervisor-agent.md", "provider": "builtin", "_marker": "$1"}}}
EOF
}

clear_repo_registry() {
  rm -f "${REPO_NAMESPACED}" "${REPO_LEGACY}"
}

echo "Case G1: .cap/agents.json only → REGISTRY_FILE points to new"
clear_repo_registry
write_repo_namespaced "G1-new"
out_g1="$(bash "${CAP_REGISTRY_SH}" show 2>&1 | head -5)"
assert_contains "G1 marker present"           "G1-new"  "${out_g1}"

echo "Case G2: .cap.agents.json only → REGISTRY_FILE points to legacy"
clear_repo_registry
write_repo_legacy "G2-legacy"
out_g2="$(bash "${CAP_REGISTRY_SH}" show 2>&1 | head -5)"
assert_contains "G2 marker present"           "G2-legacy"  "${out_g2}"

echo "Case G3: both present → REGISTRY_FILE points to new"
clear_repo_registry
write_repo_namespaced "G3-new"
write_repo_legacy "G3-legacy"
out_g3="$(bash "${CAP_REGISTRY_SH}" show 2>&1 | head -5)"
assert_contains "G3 new wins"                 "G3-new"     "${out_g3}"
case "${out_g3}" in
  *G3-legacy*) echo "  FAIL: G3 legacy leaked"; fail_count=$((fail_count + 1)) ;;
  *)           echo "  PASS: G3 legacy does not leak"; pass_count=$((pass_count + 1)) ;;
esac

# ── Reader H: step_runtime constitution design source ──────────────────

echo ""
echo "Reader H: engine/step_runtime.py — _read_constitution_design_source"

run_step_constitution() {
  local root="$1"
  ( cd "${root}" && python3 -c "
import sys
sys.path.insert(0, '${REPO_ROOT}/engine')
from step_runtime import _read_constitution_design_source
block = _read_constitution_design_source()
print('source_path=' + (block.get('source_path', '') if block else 'NONE'))
" 2>&1 )
}

echo "Case H1: .cap/constitution.yaml only"
H1="$(build_sandbox h1 constitution_new)"
out_h1="$(run_step_constitution "${H1}")"
assert_contains "H1 reads new namespace"      "source_path=/tmp/from-new-namespace"  "${out_h1}"

echo "Case H2: .cap.constitution.yaml only"
H2="$(build_sandbox h2 constitution_legacy)"
out_h2="$(run_step_constitution "${H2}")"
assert_contains "H2 reads legacy"             "source_path=/tmp/from-legacy"  "${out_h2}"

echo "Case H3: both present → new wins"
H3="$(build_sandbox h3 constitution_new,constitution_legacy)"
out_h3="$(run_step_constitution "${H3}")"
assert_contains "H3 picks new"                "source_path=/tmp/from-new-namespace"  "${out_h3}"
case "${out_h3}" in
  *from-legacy*) echo "  FAIL: H3 legacy leaked"; fail_count=$((fail_count + 1)) ;;
  *)             echo "  PASS: H3 legacy does not leak"; pass_count=$((pass_count + 1)) ;;
esac

echo ""
echo "cap-config-namespace-readers: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
