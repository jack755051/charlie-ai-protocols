#!/usr/bin/env bash
#
# test-replay-verdict-schema.sh — H1 #2 schema gate.
#
# Validate schemas/replay-verdict.schema.yaml against positive +
# negative fixtures using step_runtime.py validate-jsonschema.
#
# Coverage:
#   Positive 1: replayable verdict (everything matches)
#   Positive 2: drifted_compatible (dir_hash differs, prompt_files_used aligned)
#   Positive 3: drifted_incompatible (prompt_files_changed non-empty)
#   Positive 4: unverifiable (baseline_observed null)
#   Positive 5: not_found (baseline_observed + baseline_current both null)
#   Negative 1: missing top-level required (verdict)
#   Negative 2: invalid verdict enum
#   Negative 3: missing drift_details required (project_skill_diff)
#   Negative 4: schema_version not in enum
#   Negative 5: prompt_files_used contains non-string
#   Negative 6: drift_details.dir_hash_match wrong type (string instead of bool)
#   Negative 7: project_skill_diff non-null non-object (forbidden in v1)
#
# Reference SSOT:
#   - docs/cap/REPLAY-CONTRACT-DESIGN.md §7 schema skeleton

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/replay-verdict.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-replay-verdict-test.XXXXXX)"
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

validate_fixture() {
  local fixture_path="$1"
  "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${fixture_path}" "${SCHEMA_PATH}" >/dev/null 2>&1
  echo $?
}

write_fixture() {
  local name="$1" payload="$2"
  local path="${SANDBOX}/${name}.json"
  printf '%s\n' "${payload}" > "${path}"
  printf '%s' "${path}"
}

# ── Positive 1: replayable ─────────────────────────────────────────

echo "Positive 1: replayable verdict"
P1="$(write_fixture pos1 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_20260507_aaaa",
  "verified_at": "2026-05-07T01:23:45Z",
  "verdict": "replayable",
  "reason": "stored baseline matches current baseline byte-for-byte",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "4d52bae",
    "git_dirty": false,
    "dir_hash": "sha256:abc",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "4d52bae",
    "git_dirty": false,
    "dir_hash": "sha256:abc",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": ["01-supervisor-agent.md", "04-frontend-agent.md"],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P1 replayable validates" "0" "$(validate_fixture "${P1}")"

# ── Positive 2: drifted_compatible ─────────────────────────────────

echo ""
echo "Positive 2: drifted_compatible (dir_hash differs but used files unchanged)"
P2="$(write_fixture pos2 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_20260507_bbbb",
  "verified_at": "2026-05-07T01:24:00Z",
  "verdict": "drifted_compatible",
  "reason": "dir_hash differs but prompt_files_used unaffected",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "4d52bae",
    "git_dirty": false,
    "dir_hash": "sha256:old",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "ffffff",
    "git_dirty": true,
    "dir_hash": "sha256:new",
    "file_count": 36
  },
  "drift_details": {
    "prompt_files_used": ["01-supervisor-agent.md"],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": true,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P2 drifted_compatible validates" "0" "$(validate_fixture "${P2}")"

# ── Positive 3: drifted_incompatible ──────────────────────────────

echo ""
echo "Positive 3: drifted_incompatible (used file changed)"
P3="$(write_fixture pos3 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_20260507_cccc",
  "verified_at": "2026-05-07T01:25:00Z",
  "verdict": "drifted_incompatible",
  "reason": "04-frontend-agent.md changed since the run",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "4d52bae",
    "git_dirty": false,
    "dir_hash": "sha256:old",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "ffffff",
    "git_dirty": false,
    "dir_hash": "sha256:new",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": ["04-frontend-agent.md", "07-qa-agent.md"],
    "prompt_files_changed": ["04-frontend-agent.md"],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": true,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P3 drifted_incompatible validates" "0" "$(validate_fixture "${P3}")"

# ── Positive 4: unverifiable ─────────────────────────────────────

echo ""
echo "Positive 4: unverifiable (pre-A0 #4 run, no baseline_observed)"
P4="$(write_fixture pos4 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_20260101_dddd",
  "verified_at": "2026-05-07T01:26:00Z",
  "verdict": "unverifiable",
  "reason": "run pre-dates A0 #4 baseline recording",
  "baseline_observed": null,
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "4d52bae",
    "git_dirty": false,
    "dir_hash": "sha256:abc",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": false,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P4 unverifiable validates" "0" "$(validate_fixture "${P4}")"

# ── Positive 5: not_found ─────────────────────────────────────────

echo ""
echo "Positive 5: not_found (run dir missing)"
P5="$(write_fixture pos5 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_99999999_eeee",
  "verified_at": "2026-05-07T01:27:00Z",
  "verdict": "not_found",
  "reason": "run directory does not exist under cap_home",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": false,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P5 not_found validates" "0" "$(validate_fixture "${P5}")"

# ── Negative 1: missing top-level required (verdict) ───────────────

echo ""
echo "Negative 1: missing top-level verdict field"
N1="$(write_fixture neg1 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": false,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N1 missing verdict rejected" "1" "$(validate_fixture "${N1}")"

# ── Negative 2: invalid verdict enum ──────────────────────────────

echo ""
echo "Negative 2: invalid verdict enum value"
N2="$(write_fixture neg2 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "maybe_replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": false,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N2 invalid verdict enum rejected" "1" "$(validate_fixture "${N2}")"

# ── Negative 3: missing drift_details required (project_skill_diff) ──

echo ""
echo "Negative 3: drift_details missing project_skill_diff"
N3="$(write_fixture neg3 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true
  }
}
EOF
)")"
assert_eq "N3 missing project_skill_diff rejected" "1" "$(validate_fixture "${N3}")"

# ── Negative 4: schema_version not in enum ────────────────────────

echo ""
echo "Negative 4: schema_version 2 (only 1 is valid)"
N4="$(write_fixture neg4 "$(cat <<'EOF'
{
  "schema_version": 2,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N4 schema_version=2 rejected" "1" "$(validate_fixture "${N4}")"

# ── Negative 5: prompt_files_used contains non-string ──────────────

echo ""
echo "Negative 5: prompt_files_used has integer entry"
N5="$(write_fixture neg5 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": ["a.md", 42],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N5 non-string in prompt_files_used rejected" "1" "$(validate_fixture "${N5}")"

# ── Negative 6: drift_details.dir_hash_match wrong type ────────────

echo ""
echo "Negative 6: dir_hash_match string instead of bool"
N6="$(write_fixture neg6 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": "true",
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N6 dir_hash_match wrong type rejected" "1" "$(validate_fixture "${N6}")"

# ── Negative 7: project_skill_diff non-null non-object (forbidden v1) ─

echo ""
echo "Negative 7: project_skill_diff scalar (must be object|null per schema)"
N7="$(write_fixture neg7 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T01:28:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": "deferred"
  }
}
EOF
)")"
assert_eq "N7 scalar project_skill_diff rejected" "1" "$(validate_fixture "${N7}")"

# ── H2 #3: project_skill_diff body widened from reserved-null ───────

# ── Positive 6: project_skill_diff full body (H2 happy path) ────────

echo ""
echo "Positive 6: project_skill_diff body present (H2 was_recorded=true happy)"
P6="$(write_fixture pos6 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h2_aaaa",
  "verified_at": "2026-05-07T02:00:00Z",
  "verdict": "replayable",
  "reason": "both axes replayable",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": ["01-supervisor-agent.md"],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": {
      "was_recorded": true,
      "axis_verdict": "replayable",
      "project_dir_present_observed": true,
      "project_dir_present_current": true,
      "dir_hash_observed": "sha256:pp",
      "dir_hash_current": "sha256:pp",
      "skills_used": ["my-frontend-react18"],
      "skills_changed": [],
      "skills_removed": [],
      "skills_added_masked": [],
      "reason": null
    }
  }
}
EOF
)")"
assert_eq "P6 H2 full project_skill_diff body validates" "0" "$(validate_fixture "${P6}")"

# ── Positive 7: project_skill_diff with was_recorded=false neutral ──

echo ""
echo "Positive 7: project_skill_diff with was_recorded=false (neutral axis)"
P7="$(write_fixture pos7 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h2_bbbb",
  "verified_at": "2026-05-07T02:01:00Z",
  "verdict": "replayable",
  "reason": "builtin replayable; project axis neutral",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": {
      "was_recorded": false,
      "axis_verdict": "unverifiable_axis",
      "project_dir_present_observed": null,
      "project_dir_present_current": false,
      "dir_hash_observed": null,
      "dir_hash_current": null,
      "skills_used": [],
      "skills_changed": [],
      "skills_removed": [],
      "skills_added_masked": [],
      "reason": "project_skill_baseline absent on envelope"
    }
  }
}
EOF
)")"
assert_eq "P7 unverifiable_axis neutral body validates" "0" "$(validate_fixture "${P7}")"

# ── Positive 8: drifted_incompatible with project skills_changed ────

echo ""
echo "Positive 8: drifted_incompatible from project axis (skills_changed populated)"
P8="$(write_fixture pos8 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h2_cccc",
  "verified_at": "2026-05-07T02:02:00Z",
  "verdict": "drifted_incompatible",
  "reason": "project_skills_changed=my-frontend-react18",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": ["01-supervisor-agent.md"],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": {
      "was_recorded": true,
      "axis_verdict": "drifted_incompatible",
      "project_dir_present_observed": true,
      "project_dir_present_current": true,
      "dir_hash_observed": "sha256:pp1",
      "dir_hash_current": "sha256:pp2",
      "skills_used": ["my-frontend-react18"],
      "skills_changed": ["my-frontend-react18"],
      "skills_removed": [],
      "skills_added_masked": [],
      "reason": null
    }
  }
}
EOF
)")"
assert_eq "P8 project axis drifted_incompatible validates" "0" "$(validate_fixture "${P8}")"

# ── Positive 9: project_skill_diff null still accepted (legacy) ────

echo ""
echo "Positive 9: project_skill_diff null still accepted (pre-A0 #4 envelopes)"
P9="$(write_fixture pos9 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_legacy",
  "verified_at": "2026-05-07T02:03:00Z",
  "verdict": "unverifiable",
  "reason": "pre-A0 #4 envelope with no agent_skills_baseline",
  "baseline_observed": null,
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "abc1234",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": false,
    "cap_version_match": false,
    "git_commit_match": false,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P9 legacy null project_skill_diff validates" "0" "$(validate_fixture "${P9}")"

# ── Negative 8: invalid axis_verdict enum ───────────────────────────

echo ""
echo "Negative 8: project_skill_diff.axis_verdict invalid enum"
N8="$(write_fixture neg8 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T02:04:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": {
      "was_recorded": true,
      "axis_verdict": "maybe_drifted",
      "project_dir_present_observed": true,
      "project_dir_present_current": true,
      "dir_hash_observed": "sha256:p",
      "dir_hash_current": "sha256:p",
      "skills_used": [],
      "skills_changed": [],
      "skills_removed": [],
      "skills_added_masked": []
    }
  }
}
EOF
)")"
assert_eq "N8 invalid axis_verdict rejected" "1" "$(validate_fixture "${N8}")"

# ── Positive 10: H3 #3 workflow_yaml_diff body present ─────────────

echo ""
echo "Positive 10: workflow_yaml_diff body (H3 #3 widening)"
P10="$(write_fixture pos10 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h3_aaa",
  "verified_at": "2026-05-07T05:00:00Z",
  "verdict": "drifted_compatible",
  "reason": "workflow_yaml content_hash differs",
  "baseline_observed": {
    "cap_version": "v0.22.0",
    "git_commit": "abc",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "baseline_current": {
    "cap_version": "v0.22.0",
    "git_commit": "abc",
    "git_dirty": false,
    "dir_hash": "sha256:bb",
    "file_count": 35
  },
  "drift_details": {
    "prompt_files_used": ["01-supervisor-agent.md"],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "workflow_yaml_diff": {
      "was_recorded": true,
      "axis_verdict": "drifted_compatible",
      "workflow_id": "project-spec-pipeline",
      "workflow_path": "/abs/wf.yaml",
      "source_layer": "builtin",
      "workflow_present_observed": true,
      "workflow_present_current": true,
      "content_hash_observed": "sha256:wf1",
      "content_hash_current": "sha256:wf2",
      "reason": "workflow YAML content_hash differs"
    },
    "constitution_diff": null,
    "capability_schema_diff": null,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P10 workflow_yaml_diff body validates" "0" "$(validate_fixture "${P10}")"

# ── Positive 11: constitution_diff body present ────────────────────

echo ""
echo "Positive 11: constitution_diff body (H3 #3)"
P11="$(write_fixture pos11 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h3_bbb",
  "verified_at": "2026-05-07T05:01:00Z",
  "verdict": "drifted_compatible",
  "reason": "constitution content_hash differs",
  "baseline_observed": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "baseline_current": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "workflow_yaml_diff": null,
    "constitution_diff": {
      "was_recorded": true,
      "axis_verdict": "drifted_compatible",
      "constitution_path": "/abs/.cap/constitution.yaml",
      "constitution_present_observed": true,
      "constitution_present_current": true,
      "content_hash_observed": "sha256:c1",
      "content_hash_current": "sha256:c2",
      "reason": "constitution content_hash differs"
    },
    "capability_schema_diff": null,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P11 constitution_diff body validates" "0" "$(validate_fixture "${P11}")"

# ── Positive 12: capability_schema_diff body present ───────────────

echo ""
echo "Positive 12: capability_schema_diff body (H3 #3)"
P12="$(write_fixture pos12 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h3_ccc",
  "verified_at": "2026-05-07T05:02:00Z",
  "verdict": "drifted_compatible",
  "reason": "capability_schema content_hash differs",
  "baseline_observed": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "baseline_current": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "workflow_yaml_diff": null,
    "constitution_diff": null,
    "capability_schema_diff": {
      "was_recorded": true,
      "axis_verdict": "drifted_compatible",
      "schema_path": "/abs/schemas/capabilities.yaml",
      "schema_present_observed": true,
      "schema_present_current": true,
      "content_hash_observed": "sha256:cs1",
      "content_hash_current": "sha256:cs2",
      "reason": "capability schema content_hash differs"
    },
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P12 capability_schema_diff body validates" "0" "$(validate_fixture "${P12}")"

# ── Positive 13: legacy null on all three new H3 axes accepted ─────

echo ""
echo "Positive 13: legacy null on all three H3 axes (pre-H3 envelope)"
P13="$(write_fixture pos13 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_h2_legacy",
  "verified_at": "2026-05-07T05:03:00Z",
  "verdict": "replayable",
  "reason": "ok",
  "baseline_observed": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "baseline_current": {"cap_version":"v0.22.0","git_commit":"abc","git_dirty":false,"dir_hash":"sha256:bb","file_count":35},
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "workflow_yaml_diff": null,
    "constitution_diff": null,
    "capability_schema_diff": null,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "P13 legacy null on H3 axes validates" "0" "$(validate_fixture "${P13}")"

# ── Negative 10: H3 axis invalid axis_verdict enum ─────────────────

echo ""
echo "Negative 10: workflow_yaml_diff invalid axis_verdict enum"
N10="$(write_fixture neg10 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T05:04:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "workflow_yaml_diff": {
      "was_recorded": true,
      "axis_verdict": "totally_made_up",
      "workflow_id": null,
      "workflow_path": null,
      "source_layer": null,
      "workflow_present_observed": true,
      "workflow_present_current": true,
      "content_hash_observed": "sha256:a",
      "content_hash_current": "sha256:a"
    },
    "constitution_diff": null,
    "capability_schema_diff": null,
    "project_skill_diff": null
  }
}
EOF
)")"
assert_eq "N10 invalid workflow_yaml axis_verdict rejected" "1" "$(validate_fixture "${N10}")"

# ── Negative 9: skills_changed contains non-string ─────────────────

echo ""
echo "Negative 9: skills_changed has non-string entry"
N9="$(write_fixture neg9 "$(cat <<'EOF'
{
  "schema_version": 1,
  "run_id": "run_x",
  "verified_at": "2026-05-07T02:05:00Z",
  "verdict": "replayable",
  "baseline_observed": null,
  "baseline_current": null,
  "drift_details": {
    "prompt_files_used": [],
    "prompt_files_changed": [],
    "prompt_files_removed": [],
    "dir_hash_match": true,
    "cap_version_match": true,
    "git_commit_match": true,
    "project_skill_diff": {
      "was_recorded": true,
      "axis_verdict": "replayable",
      "project_dir_present_observed": true,
      "project_dir_present_current": true,
      "dir_hash_observed": "sha256:p",
      "dir_hash_current": "sha256:p",
      "skills_used": [],
      "skills_changed": [123],
      "skills_removed": [],
      "skills_added_masked": []
    }
  }
}
EOF
)")"
assert_eq "N9 non-string skills_changed rejected" "1" "$(validate_fixture "${N9}")"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
