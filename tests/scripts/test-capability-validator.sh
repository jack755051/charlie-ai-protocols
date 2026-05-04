#!/usr/bin/env bash
#
# test-capability-validator.sh — P6 #5 + #6 + #7 gate.
#
# Verifies engine.capability_validator dispatches the right validator
# per capability via DEFAULT_RULES, supports the JSON-schema kind end
# to end (fence extraction → JSON parse → schema validation reusing
# step_runtime.validate_jsonschema_fallback), and supports the
# Markdown required-sections kind as a mechanism (no production
# capability registers it yet — exercised here via injected rules).
#
# Coverage (inline-Python, hermetic — uses sandboxed artifact files):
#   Case 1 happy json_schema:        valid task-constitution JSON
#                                    inside a line-anchored fence →
#                                    ok=True kind=json_schema.
#   Case 2 missing required:        JSON missing 'goal' /
#                                    'success_criteria' → ok=False with
#                                    field-level errors from
#                                    validate_jsonschema_fallback.
#   Case 3 fence-anchored extractor: inline prose containing the fence
#                                    markers as quoted text does NOT
#                                    match (line-anchored regex);
#                                    real fence on its own lines does.
#   Case 4 nested ```json strip:    inner block double-wrapped with
#                                    ```json ... ``` still parses.
#   Case 5 PARSE_ERROR:             fence content that isn't valid JSON
#                                    → ok=False kind=json_schema with
#                                    PARSE_ERROR: prefix.
#   Case 6 fence not found:         artifact has no fence at all →
#                                    ok=False with explanatory error.
#   Case 7 markdown sections happy: required headers all present →
#                                    ok=True kind=markdown_sections.
#   Case 8 markdown sections missing: missing headers reported with
#                                    "missing required section: <h>"
#                                    error per missing item.
#   Case 9 unknown capability:      capability not in registry →
#                                    ok=True kind=no_validator
#                                    (treated as skipped).
#   Case 10 missing artifact:       artifact path doesn't exist →
#                                    ok=False kind=missing_artifact.
#   Case 11 unknown rule kind:      rule with kind="weird" →
#                                    ok=False kind=unknown_kind.
#   Case 12 historical real-world:  validates the rc9-investigated
#                                    failed draft from token-monitor;
#                                    reports the same MISSING_REQUIRED
#                                    findings as the persist script.
#                                    Skipped if path absent.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/capability_validator.py" ] || {
  echo "FAIL: engine/capability_validator.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-validator-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

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

run_py() {
  ( cd "${REPO_ROOT}" && python3 -c "$1" 2>&1 )
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: happy json_schema → ok=True"
GOOD="${SANDBOX}/c1_good.md"
cat > "${GOOD}" <<'EOF'
# task constitution draft

<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "demo-good",
  "project_id": "charlie-ai-protocols",
  "source_request": "demo source request",
  "goal": "demonstrate validator happy path",
  "goal_stage": "informal_planning",
  "success_criteria": ["validator returns ok=True"],
  "non_goals": [],
  "execution_plan": [
    {"step_id": "plan", "capability": "task_constitution_planning"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out1="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${GOOD}')
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
print('errors_count=' + str(len(r.errors)))
")"
assert_contains "ok=True"           "ok=True"           "${out1}"
assert_contains "kind=json_schema"  "kind=json_schema"  "${out1}"
assert_contains "no errors"          "errors_count=0"   "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: missing required fields → ok=False with field-level errors"
BAD="${SANDBOX}/c2_bad.md"
cat > "${BAD}" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "demo-bad",
  "project_id": "charlie-ai-protocols",
  "source_request": "missing goal + success_criteria",
  "goal_stage": "informal_planning",
  "non_goals": [],
  "execution_plan": [
    {"step_id": "plan", "capability": "task_constitution_planning"}
  ]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out2="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${BAD}')
print('ok=' + str(r.ok))
print('errors_count=' + str(len(r.errors)))
print('errors_joined=' + ' | '.join(r.errors[:5]))
")"
assert_contains "ok=False"                       "ok=False"                                          "${out2}"
assert_contains "missing goal surfaced"          "missing required field 'goal'"                    "${out2}"
assert_contains "missing success_criteria"       "missing required field 'success_criteria'"        "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: fence markers quoted in prose do NOT match (line-anchored)"
PROSE="${SANDBOX}/c3_prose.md"
cat > "${PROSE}" <<'EOF'
這份說明文件描述了 supervisor 的輸出格式：
請以 <<<TASK_CONSTITUTION_JSON_BEGIN>>> ... <<<TASK_CONSTITUTION_JSON_END>>> 包裹 JSON，下游會抓取此區塊。

<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{
  "task_id": "demo-prose",
  "project_id": "charlie-ai-protocols",
  "source_request": "verify prose example does not eat fence",
  "goal": "fence anchored to line boundaries",
  "goal_stage": "informal_planning",
  "success_criteria": ["actual JSON wins over inline prose example"],
  "non_goals": [],
  "execution_plan": [{"step_id": "x", "capability": "y"}]
}
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out3="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${PROSE}')
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
print('errors_count=' + str(len(r.errors)))
")"
assert_contains "anchored fence captures real JSON, not prose"  "ok=True"          "${out3}"
assert_contains "kind json_schema"                                "kind=json_schema" "${out3}"
assert_contains "no errors"                                       "errors_count=0"   "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo 'Case 4: nested ```json wrapper inside fence is stripped'
NESTED="${SANDBOX}/c4_nested.md"
cat > "${NESTED}" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
```json
{
  "task_id": "demo-nested",
  "project_id": "charlie-ai-protocols",
  "source_request": "nested wrapper",
  "goal": "nested ```json fence still parses",
  "goal_stage": "informal_planning",
  "success_criteria": ["v0.21.5 strip carried over"],
  "non_goals": [],
  "execution_plan": [{"step_id": "x", "capability": "y"}]
}
```
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out4="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${NESTED}')
print('ok=' + str(r.ok))
print('errors_count=' + str(len(r.errors)))
")"
assert_contains "nested fence parses ok"  "ok=True"          "${out4}"
assert_contains "no errors"                "errors_count=0"  "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: fence content is not valid JSON → PARSE_ERROR prefix"
PARSE="${SANDBOX}/c5_parse.md"
cat > "${PARSE}" <<'EOF'
<<<TASK_CONSTITUTION_JSON_BEGIN>>>
{not actually json
<<<TASK_CONSTITUTION_JSON_END>>>
EOF
out5="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${PARSE}')
print('ok=' + str(r.ok))
print('first_error=' + (r.errors[0] if r.errors else ''))
")"
assert_contains "ok=False"                "ok=False"          "${out5}"
assert_contains "PARSE_ERROR prefix"      "PARSE_ERROR:"      "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: artifact has no fence at all → fence not found"
NOFENCE="${SANDBOX}/c6_nofence.md"
cat > "${NOFENCE}" <<'EOF'
just a markdown file
no fence markers here
EOF
out6="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${NOFENCE}')
print('ok=' + str(r.ok))
print('first_error=' + (r.errors[0] if r.errors else ''))
")"
assert_contains "ok=False"               "ok=False"             "${out6}"
assert_contains "fence not found error"  "fence markers not found" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: markdown_sections — all required headers present → ok=True"
MD_OK="${SANDBOX}/c7_md.md"
cat > "${MD_OK}" <<'EOF'
# Some Document

## 交接摘要

content...

## 驗收結果

content...
EOF
out7="$(run_py "
from engine.capability_validator import validate_capability_output
custom_rules = {
    'fake_capability': {
        'kind': 'markdown_sections',
        'required_sections': ['## 交接摘要', '## 驗收結果'],
    }
}
r = validate_capability_output('fake_capability', '${MD_OK}', rules=custom_rules)
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
")"
assert_contains "markdown all sections present"  "ok=True"                   "${out7}"
assert_contains "kind markdown_sections"         "kind=markdown_sections"   "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: markdown_sections — missing headers reported"
MD_BAD="${SANDBOX}/c8_md.md"
cat > "${MD_BAD}" <<'EOF'
# Some Document

## 交接摘要

content...
EOF
out8="$(run_py "
from engine.capability_validator import validate_capability_output
custom_rules = {
    'fake_capability': {
        'kind': 'markdown_sections',
        'required_sections': ['## 交接摘要', '## 驗收結果', '## 後續建議'],
    }
}
r = validate_capability_output('fake_capability', '${MD_BAD}', rules=custom_rules)
print('ok=' + str(r.ok))
print('errors_count=' + str(len(r.errors)))
print('errors=' + ' | '.join(r.errors))
")"
assert_contains "ok=False"                          "ok=False"                              "${out8}"
assert_contains "two missing sections reported"     "errors_count=2"                       "${out8}"
assert_contains "missing 驗收結果"                  "missing required section: ## 驗收結果" "${out8}"
assert_contains "missing 後續建議"                  "missing required section: ## 後續建議" "${out8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: unknown capability → ok=True kind=no_validator (skipped)"
out9="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('definitely_not_registered', '/tmp/nope.md')
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
")"
assert_contains "no_validator skip ok"  "ok=True"           "${out9}"
assert_contains "kind no_validator"      "kind=no_validator" "${out9}"

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: missing artifact file → ok=False kind=missing_artifact"
out10="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${SANDBOX}/no-such-file.md')
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
print('first_error=' + (r.errors[0] if r.errors else ''))
")"
assert_contains "ok=False"                "ok=False"             "${out10}"
assert_contains "kind missing_artifact"    "kind=missing_artifact" "${out10}"
assert_contains "error names path"         "no-such-file.md"      "${out10}"

# ── Case 11 ─────────────────────────────────────────────────────────────
echo "Case 11: unknown rule kind → ok=False kind=unknown_kind"
WHATEVER="${SANDBOX}/c11.md"
echo "anything" > "${WHATEVER}"
out11="$(run_py "
from engine.capability_validator import validate_capability_output
custom_rules = {'weird_cap': {'kind': 'something_unknown'}}
r = validate_capability_output('weird_cap', '${WHATEVER}', rules=custom_rules)
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
print('first_error=' + (r.errors[0] if r.errors else ''))
")"
assert_contains "ok=False"             "ok=False"            "${out11}"
assert_contains "kind unknown_kind"     "kind=unknown_kind"  "${out11}"
assert_contains "error mentions kind"   "something_unknown"  "${out11}"

# ── Case 12 ─────────────────────────────────────────────────────────────
HISTORICAL="/Users/charlie010583/.cap/projects/token-monitor/reports/workflows/project-spec-pipeline/run_20260430124841_00e055fc/1-draft_task_constitution.md"
if [ -f "${HISTORICAL}" ]; then
  echo "Case 12: historical rc9-diagnosed draft replays MISSING_REQUIRED:goal"
  out12="$(run_py "
from engine.capability_validator import validate_capability_output
r = validate_capability_output('task_constitution_planning', '${HISTORICAL}')
print('ok=' + str(r.ok))
print('kind=' + r.validator_kind)
print('errors_joined=' + ' | '.join(r.errors[:4]))
")"
  assert_contains "historical draft fails as expected"           "ok=False"                                "${out12}"
  assert_contains "rediscovers MISSING goal"                      "missing required field 'goal'"          "${out12}"
  assert_contains "rediscovers MISSING success_criteria"           "missing required field 'success_criteria'" "${out12}"
else
  echo "Case 12: historical artifact not present, skipping"
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "capability-validator: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
