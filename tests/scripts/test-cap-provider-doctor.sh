#!/bin/bash
#
# test-cap-provider-doctor.sh
#
# Exercises `cap provider doctor` after the P1 readiness-schema wiring
# slice. Two contracts under test:
#
#   1. Behavior contract (unchanged from pre-P1):
#      - text mode lists both providers + the resolved default cli
#      - CAP_DEFAULT_AGENT_CLI override propagates to text output
#      - cap-entry routes `provider doctor` subcommand
#      - unknown subcommand exits non-zero
#      - body invokes no provider login flow
#
#   2. Readiness-JSON contract (new in P1-readiness):
#      - `--json` emits a report conforming to
#        schemas/provider-readiness.schema.yaml
#      - probe_policy locks no_token / no_interactive / no_mutation true
#      - providers array carries exactly the documented two entries
#        (claude, codex) with source=cli
#      - state is one of {provider_missing, auth_unknown} given the
#        P1 conservative mapping (no auth probing in v1)
#      - remediation is present and non-empty for every entry
#      - schema_version is 1, generated_at is ISO-8601-ish
#      - presence of cli_path is gated on state (missing → no path)
#
# Out of scope (per slice authorization):
#   - no workflow preflight wiring
#   - no actual provider invocation; the test runs against the real
#     PATH but uses the schema validator as truth, not provider output
#   - no obj/ cleanup, no convergence work

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_PROVIDER="${REPO_ROOT}/scripts/cap-provider.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
SCHEMA="${REPO_ROOT}/schemas/provider-readiness.schema.yaml"
PYTHON_BIN="${PYTHON_BIN:-python3}"

failures=0
checks=0

pass() {
  checks=$((checks + 1))
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -Fq "${needle}" <<<"${haystack}"; then
    pass
  else
    fail "${label}: expected to contain '${needle}'"
    echo "  --- haystack ---" >&2
    printf '%s\n' "${haystack}" | head -10 >&2
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass
  else
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

# ── Case 1: text mode header + provider rows + default cli line ─────────
echo "Case 1: cap provider doctor (text) reports default cli + provider rows"
OUT="$(bash "${CAP_PROVIDER}" doctor 2>&1)"
assert_contains "header present"    "CAP PROVIDER DOCTOR" "${OUT}"
assert_contains "default cli line"  "default cli:"         "${OUT}"
assert_contains "claude row"        "claude:"              "${OUT}"
assert_contains "codex row"         "codex:"               "${OUT}"

# ── Case 2: --json conforms to schemas/provider-readiness.schema.yaml ──
echo "Case 2: cap provider doctor --json conforms to readiness schema"
JSON_FILE="$(mktemp -t cap-doctor-json.XXXXXX)"
trap 'rm -f "${JSON_FILE}"' EXIT
bash "${CAP_PROVIDER}" doctor --json > "${JSON_FILE}" 2>/dev/null
validator_out="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${JSON_FILE}" "${SCHEMA}" 2>&1)"
validator_rc=$?
assert_eq        "validator rc=0 on doctor JSON"        "0"                  "${validator_rc}"
assert_contains "validator emits ok=true"                "\"ok\": true"       "${validator_out}"
assert_contains "validator emits empty errors"           "\"errors\": []"     "${validator_out}"

# ── Case 3: probe_policy locks no_token / no_interactive / no_mutation ─
echo "Case 3: probe_policy locks all three readiness rules true"
NO_TOKEN="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["probe_policy"]["no_token"])
' "${JSON_FILE}")"
NO_INTERACTIVE="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["probe_policy"]["no_interactive"])
' "${JSON_FILE}")"
NO_MUTATION="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["probe_policy"]["no_mutation"])
' "${JSON_FILE}")"
assert_eq "no_token=True"        "True" "${NO_TOKEN}"
assert_eq "no_interactive=True"  "True" "${NO_INTERACTIVE}"
assert_eq "no_mutation=True"     "True" "${NO_MUTATION}"

# ── Case 4: providers array carries exactly claude + codex, source=cli ─
echo "Case 4: providers array shape (names, source, presence, state)"
PROVIDER_REPORT="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
providers = data["providers"]
lines = []
lines.append(f"count={len(providers)}")
for p in providers:
    lines.append("name=" + p.get("name", "?"))
    lines.append("source=" + p.get("source", "?"))
    lines.append("state=" + p.get("state", "?"))
    lines.append("remediation_len=" + str(len(p.get("remediation", ""))))
    if p.get("state") == "provider_missing":
        lines.append(p["name"] + ".cli_path=" + str("cli_path" in p))
print("\n".join(lines))
' "${JSON_FILE}")"
assert_contains "providers count == 2"       "count=2"           "${PROVIDER_REPORT}"
assert_contains "claude name present"         "name=claude"       "${PROVIDER_REPORT}"
assert_contains "codex name present"          "name=codex"        "${PROVIDER_REPORT}"
assert_contains "every entry source=cli"      "source=cli"        "${PROVIDER_REPORT}"
# At least one of the documented P1 states must appear for each provider.
# v1 maps a missing CLI to provider_missing and a present CLI to
# auth_unknown; no other states are produced by this slice.
if grep -qE 'state=provider_missing|state=auth_unknown' <<<"${PROVIDER_REPORT}"; then
  pass
else
  fail "no provider entry shows state=provider_missing|auth_unknown — slice contract violated"
fi
# remediation is required + non-empty for every entry; if either was an
# empty string the schema validation in Case 2 would have failed, but
# the dedicated assertion below pins the contract at the test level too.
if grep -q 'remediation_len=0' <<<"${PROVIDER_REPORT}"; then
  fail "remediation_len=0 — every entry must carry actionable remediation text"
else
  pass
fi
# When a provider is reported missing, the entry must NOT carry cli_path
# (the schema allows the field to be absent; the slice's contract is to
# omit it when missing rather than emit an empty string).
if grep -q '\.cli_path=True$' <<<"${PROVIDER_REPORT}"; then
  fail "provider_missing entry must omit cli_path"
else
  pass
fi

# ── Case 5: schema_version=1 + ISO-8601 generated_at prefix ────────────
echo "Case 5: schema_version=1 + generated_at ISO-8601-ish"
SCHEMA_VERSION="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["schema_version"])
' "${JSON_FILE}")"
GENERATED_AT="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data["generated_at"])
' "${JSON_FILE}")"
assert_eq "schema_version=1" "1" "${SCHEMA_VERSION}"
if [[ "${GENERATED_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
  pass
else
  fail "generated_at not ISO-8601-prefix: ${GENERATED_AT}"
fi

# ── Case 6: CAP_DEFAULT_AGENT_CLI override propagates to text output ───
echo "Case 6: CAP_DEFAULT_AGENT_CLI override surfaces in text mode"
OVERRIDE_OUT="$(CAP_DEFAULT_AGENT_CLI=codex bash "${CAP_PROVIDER}" doctor 2>&1)"
assert_contains "override shown as codex (from env)" "codex (from CAP_DEFAULT_AGENT_CLI)" "${OVERRIDE_OUT}"
# JSON mode intentionally omits default_cli (it is operator preference,
# not provider readiness). Verify the readiness JSON does NOT carry that
# key so the schema's additionalProperties=false stays the source of
# truth for top-level shape.
OVERRIDE_JSON="$(mktemp -t cap-doctor-json.XXXXXX)"
CAP_DEFAULT_AGENT_CLI=codex bash "${CAP_PROVIDER}" doctor --json > "${OVERRIDE_JSON}" 2>/dev/null
if "${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if "default_cli" not in data else 1)
' "${OVERRIDE_JSON}"; then
  pass
else
  fail "JSON output must not carry default_cli (readiness shape stays pure)"
fi
rm -f "${OVERRIDE_JSON}"

# ── Case 7: cap-entry routes 'provider doctor' subcommand ──────────────
echo "Case 7: cap-entry routes 'provider doctor'"
ENTRY_OUT="$(bash "${CAP_ENTRY}" provider doctor 2>&1)"
assert_contains "entry route header" "CAP PROVIDER DOCTOR" "${ENTRY_OUT}"

# ── Case 8: unknown subcommand under provider exits non-zero ───────────
echo "Case 8: unknown subcommand under provider exits non-zero"
set +e
bash "${CAP_PROVIDER}" bogus 2>/dev/null
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
  pass
else
  fail "unknown subcommand should exit non-zero, got ${RC}"
fi

# ── Case 9: body invokes no provider login flow (no_interactive rule) ──
echo "Case 9: doctor body contains no login keyword (no_interactive rule)"
PROVIDER_BODY="$(cat "${CAP_PROVIDER}")"
if grep -qE 'claude[[:space:]]+login|codex[[:space:]]+login|--login' <<<"${PROVIDER_BODY}"; then
  fail "cap-provider.sh must not invoke provider login"
else
  pass
fi

# ── Case 10: provider_missing branch — stripped PATH hides both CLIs ──
#
# The host running this test has claude+codex installed; Cases 1–9
# only exercise the auth_unknown branch. The provider_missing path is
# the slice's other documented branch (per ADR-3 §4 + the slice
# authorization), so we must exercise it too. Strategy: run the
# doctor under a stripped PATH (/usr/bin:/bin) which carries no
# provider CLI but still has python3 / sed / head / etc.; pass
# PYTHON_BIN as an absolute path so the doctor's JSON emit step does
# not depend on the stripped PATH for python3 itself.
echo "Case 10: provider_missing branch under stripped PATH"
ABS_PYTHON="$(command -v "${PYTHON_BIN}")"
MISSING_JSON="$(mktemp -t cap-doctor-missing-json.XXXXXX)"
PATH="/usr/bin:/bin" PYTHON_BIN="${ABS_PYTHON}" \
  bash "${CAP_PROVIDER}" doctor --json > "${MISSING_JSON}" 2>/dev/null
missing_validator_out="$("${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${MISSING_JSON}" "${SCHEMA}" 2>&1)"
missing_validator_rc=$?
assert_eq        "validator rc=0 on missing-CLI JSON"  "0"                  "${missing_validator_rc}"
assert_contains "validator emits ok=true (missing)"     "\"ok\": true"       "${missing_validator_out}"
MISSING_REPORT="$("${PYTHON_BIN}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
lines = []
for p in data["providers"]:
    lines.append(p["name"] + ".state=" + p["state"])
    lines.append(p["name"] + ".has_cli_path=" + str("cli_path" in p))
    lines.append(p["name"] + ".rem=" + p.get("remediation", ""))
print("\n".join(lines))
' "${MISSING_JSON}")"
assert_contains "claude.state=provider_missing"  "claude.state=provider_missing"  "${MISSING_REPORT}"
assert_contains "codex.state=provider_missing"   "codex.state=provider_missing"   "${MISSING_REPORT}"
assert_contains "claude.cli_path absent"          "claude.has_cli_path=False"      "${MISSING_REPORT}"
assert_contains "codex.cli_path absent"           "codex.has_cli_path=False"       "${MISSING_REPORT}"
assert_contains "claude remediation mentions install" "Install Claude Code"        "${MISSING_REPORT}"
assert_contains "codex remediation mentions install"  "Install Codex CLI"          "${MISSING_REPORT}"
rm -f "${MISSING_JSON}"

# ── Case 11: no token-spending probe path appears in the script body ──
echo "Case 11: doctor body avoids token-spending probes (no_token rule)"
# Stop at the first match so a runaway false-positive does not flood the
# error stream. The intent is structural: this script must not call
# anything that would consume model quota in v1. `--version` is fine;
# `--print`, `-p`, `chat`, `exec` against the provider CLIs would not be.
TOKEN_HITS="$(grep -nE 'claude[[:space:]]+(-p|--print|exec)|codex[[:space:]]+(-p|exec)|--model' "${CAP_PROVIDER}" || true)"
if [ -n "${TOKEN_HITS}" ]; then
  fail "cap-provider.sh body shows potential token-spending invocation: ${TOKEN_HITS}"
else
  pass
fi

# ── Summary ────────────────────────────────────────────────────────────
PASSED=$((checks - failures))
echo "Summary: ${PASSED} passed, ${failures} failed"
[ "${failures}" -eq 0 ]
