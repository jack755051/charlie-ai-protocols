#!/usr/bin/env bash
#
# test-cap-artifact-inspect.sh — P6 #1 + #2 gate.
#
# Verifies engine.artifact_inspector + the cap artifact shell wrapper
# expose the runtime-state.json artifact registry as a read-only CLI:
# list / inspect <name> / by-step <step_id>, with a derived consumer
# cross-reference computed from schemas/capabilities.yaml inputs.
#
# Read-only by design — none of the cases mutate the runtime-state
# fixture. Hermetic via --runtime-state, no real workflow execution.
#
# Coverage:
#   Case 1 list shows all artifacts:    list dumps the 4 fixture entries
#                                       in a single text block; exit 0.
#   Case 2 inspect existing artifact:   inspect <name> renders artifact +
#                                       producer + path + handoff_path +
#                                       derived consumers from the
#                                       capabilities cross-reference.
#   Case 3 missing artifact deterministic error:
#                                       inspect <unknown> → exit 1 with
#                                       JSON {"ok": false, "error":
#                                       "artifact_not_found", ...}.
#   Case 4 by-step lists producer outputs:
#                                       by-step <step_id> returns only
#                                       the artifacts that step produces.
#   Case 5 derived_consumers cross-ref:
#                                       fixture artifact 'task_constitution_draft' is
#                                       declared as input by capability
#                                       'consumer_cap'; the inspector
#                                       lists the matching step in the
#                                       same run as a derived consumer.
#   Case 6 JSON mode parseable:         --json on list / inspect / by-step
#                                       returns parseable envelopes.
#   Case 7 read-only:                   md5 of the runtime-state fixture
#                                       is unchanged after running every
#                                       command, proving the registry is
#                                       not mutated.
#   Case 8 cap-entry routing:           cap artifact list (via cap-entry
#                                       → cap-artifact dispatcher) reaches
#                                       the inspector.
#   Case 9 missing capabilities.yaml:   when capabilities cannot be
#                                       loaded, derived_consumers is
#                                       omitted (not falsely empty).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/artifact_inspector.py" ] || {
  echo "FAIL: engine/artifact_inspector.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/scripts/cap-artifact.sh" ] || {
  echo "FAIL: scripts/cap-artifact.sh missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-artifact-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

FIXTURE="${SANDBOX}/runtime-state.json"
cat > "${FIXTURE}" <<'EOF'
{
  "artifacts": {
    "task_constitution_draft": {
      "artifact": "task_constitution_draft",
      "source_step": "draft_step",
      "path": "/tmp/run/1-draft.md",
      "handoff_path": "/tmp/run/1-draft.handoff.md"
    },
    "task_y": {
      "artifact": "task_y",
      "source_step": "compose_step",
      "path": "/tmp/run/2-compose.md",
      "handoff_path": "/tmp/run/2-compose.handoff.md"
    },
    "task_constitution_draft_normalized": {
      "artifact": "task_constitution_draft_normalized",
      "source_step": "draft_step",
      "path": "/tmp/run/1-norm.md",
      "handoff_path": "/tmp/run/1-norm.handoff.md"
    },
    "orphan_artifact": {
      "artifact": "orphan_artifact",
      "source_step": "compose_step",
      "path": "/tmp/run/3-orphan.md",
      "handoff_path": "/tmp/run/3-orphan.handoff.md"
    }
  },
  "steps": {
    "draft_step": {
      "phase": 1,
      "capability": "task_constitution_planning",
      "execution_state": "validated",
      "blocked_reason": null,
      "output_source": "captured_stdout",
      "output_path": "/tmp/run/1-draft.md",
      "handoff_path": "/tmp/run/1-draft.handoff.md"
    },
    "compose_step": {
      "phase": 2,
      "capability": "task_constitution_persistence",
      "execution_state": "validated",
      "blocked_reason": null,
      "output_source": "captured_stdout",
      "output_path": "/tmp/run/2-compose.md",
      "handoff_path": "/tmp/run/2-compose.handoff.md"
    }
  }
}
EOF

CAP_ARTIFACT="${REPO_ROOT}/scripts/cap-artifact.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

pass_count=0
fail_count=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

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

md5_of() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$1" | awk '{print $1}'
  fi
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: list shows all artifacts"
out1="$(bash "${CAP_ARTIFACT}" list --runtime-state "${FIXTURE}" 2>&1)"
exit1=$?
assert_eq "exit 0 list happy"      "0"               "${exit1}"
assert_contains "header rendered"  "ARTIFACT"        "${out1}"
assert_contains "task_constitution_draft listed"     "task_constitution_draft "        "${out1}"
assert_contains "task_y listed"     "task_y "        "${out1}"
assert_contains "orphan listed"     "orphan_artifact" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: inspect existing artifact renders all fields"
out2="$(bash "${CAP_ARTIFACT}" inspect task_constitution_draft --runtime-state "${FIXTURE}" 2>&1)"
exit2=$?
assert_eq "exit 0 inspect happy"           "0"                                 "${exit2}"
assert_contains "artifact line"             "artifact: task_constitution_draft"                 "${out2}"
assert_contains "producer step rendered"   "source_step: draft_step"           "${out2}"
assert_contains "path rendered"             "path: /tmp/run/1-draft.md"        "${out2}"
assert_contains "handoff_path rendered"     "handoff_path:"                    "${out2}"
assert_contains "derived_consumers section" "derived_consumers"                "${out2}"
assert_contains "source_runtime_state trailer" "source_runtime_state: ${FIXTURE}" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: missing artifact → exit 1 with deterministic JSON error"
out3="$(bash "${CAP_ARTIFACT}" inspect not_in_fixture --runtime-state "${FIXTURE}" 2>&1)"
exit3=$?
assert_eq        "exit 1 on miss"            "1"                                            "${exit3}"
assert_contains "deterministic error tag"   "\"error\": \"artifact_not_found\""             "${out3}"
assert_contains "query echoed back"          "\"artifact_name\": \"not_in_fixture\""        "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: by-step lists artifacts produced by that step"
out4="$(bash "${CAP_ARTIFACT}" by-step draft_step --runtime-state "${FIXTURE}" --json 2>&1)"
parsed4="$(printf '%s' "${out4}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('count=' + str(d['count']))
print('names=' + ','.join(sorted(a['artifact'] for a in d['artifacts'])))
")"
assert_contains "two artifacts produced by draft_step" "count=2"                          "${parsed4}"
assert_contains "names match draft outputs"             "names=task_constitution_draft,task_constitution_draft_normalized"  "${parsed4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
# task_constitution_draft is declared as an input by capability task_constitution_persistence
# (per schemas/capabilities.yaml). Step compose_step in this run runs that
# capability, so it's a derived consumer of task_constitution_draft.
echo "Case 5: derived consumers reflect capabilities.yaml cross-ref"
out5="$(bash "${CAP_ARTIFACT}" inspect task_constitution_draft --runtime-state "${FIXTURE}" --json 2>&1)"
parsed5="$(printf '%s' "${out5}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
art = d['artifacts'][0]
cons = art.get('derived_consumers', [])
print('consumer_count=' + str(len(cons)))
if cons:
    print('first_consumer_step=' + cons[0]['step_id'])
    print('first_consumer_capability=' + cons[0]['capability'])
")"
assert_contains "at least one derived consumer"       "consumer_count="                                "${parsed5}"
assert_contains "consumer step is compose_step"       "first_consumer_step=compose_step"               "${parsed5}"
assert_contains "consumer cap is task_constitution_persistence" "first_consumer_capability=task_constitution_persistence" "${parsed5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: --json on all three subcommands returns parseable envelope"
out6_list="$(bash "${CAP_ARTIFACT}" list --runtime-state "${FIXTURE}" --json 2>&1)"
parsed6_list="$(printf '%s' "${out6_list}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('list_ok=' + str(d['ok']))
print('list_count=' + str(d['count']))
")"
assert_contains "list json ok"     "list_ok=True"  "${parsed6_list}"
assert_contains "list json count"  "list_count=4"  "${parsed6_list}"

out6_insp="$(bash "${CAP_ARTIFACT}" inspect task_y --runtime-state "${FIXTURE}" --json 2>&1)"
parsed6_insp="$(printf '%s' "${out6_insp}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('insp_ok=' + str(d['ok']))
print('insp_artifact=' + d['artifacts'][0]['artifact'])
")"
assert_contains "inspect json ok"        "insp_ok=True"        "${parsed6_insp}"
assert_contains "inspect json artifact"  "insp_artifact=task_y" "${parsed6_insp}"

out6_bs="$(bash "${CAP_ARTIFACT}" by-step compose_step --runtime-state "${FIXTURE}" --json 2>&1)"
parsed6_bs="$(printf '%s' "${out6_bs}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('bs_ok=' + str(d['ok']))
print('bs_count=' + str(d['count']))
")"
assert_contains "by-step json ok"     "bs_ok=True"  "${parsed6_bs}"
assert_contains "by-step json count"  "bs_count=2"  "${parsed6_bs}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: read-only — runtime-state fixture md5 unchanged"
md5_before="$(md5_of "${FIXTURE}")"
bash "${CAP_ARTIFACT}" list    --runtime-state "${FIXTURE}" >/dev/null
bash "${CAP_ARTIFACT}" inspect task_constitution_draft --runtime-state "${FIXTURE}" >/dev/null
bash "${CAP_ARTIFACT}" by-step draft_step --runtime-state "${FIXTURE}" >/dev/null
md5_after="$(md5_of "${FIXTURE}")"
assert_eq "fixture md5 unchanged after 3 commands" "${md5_before}" "${md5_after}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: cap artifact list (via cap-entry → cap-artifact dispatcher)"
out8="$(bash "${CAP_ENTRY}" artifact list --runtime-state "${FIXTURE}" --json 2>&1)"
exit8=$?
parsed8="$(printf '%s' "${out8}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('ok=' + str(d['ok']))
print('count=' + str(d['count']))
")"
assert_eq "cap-entry routing exit 0" "0" "${exit8}"
assert_contains "cap-entry json ok"    "ok=True"   "${parsed8}"
assert_contains "cap-entry json count" "count=4"  "${parsed8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
# Run from a sandbox cwd with no schemas/ dir so capabilities index
# cannot be loaded; inspector must omit derived_consumers entirely
# rather than report empty arrays (false negatives).
echo "Case 9: capabilities.yaml unavailable → derived_consumers omitted"
ISOLATED="${SANDBOX}/isolated"
mkdir -p "${ISOLATED}"
cp "${REPO_ROOT}/engine/artifact_inspector.py" "${ISOLATED}/"
out9="$(cd "${ISOLATED}" && python3 artifact_inspector.py inspect task_constitution_draft --runtime-state "${FIXTURE}" --json 2>&1)"
parsed9="$(printf '%s' "${out9}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
art = d['artifacts'][0]
print('has_field=' + str('derived_consumers' in art))
")"
assert_contains "derived_consumers omitted when index unavailable" "has_field=False" "${parsed9}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "cap-artifact-inspect: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
