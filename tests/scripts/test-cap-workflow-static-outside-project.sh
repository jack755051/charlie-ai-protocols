#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"

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
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "${needle}" <<<"${haystack}"; then
    pass
  else
    fail "${label}: missing ${needle}"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${tmpdir}/plain"
cd "${tmpdir}/plain"

unset CAP_PROJECT_ID_OVERRIDE
unset CAP_ALLOW_BASENAME_FALLBACK

output="$("${CAP_WORKFLOW}" list 2>&1)" || {
  rc=$?
  fail "cap workflow list should work outside a CAP project (rc=${rc}); output=${output}"
  echo "Summary: $((checks - failures)) passed, ${failures} failed"
  exit 1
}

assert_contains "${output}" "WORKFLOW LIST" "workflow list header"
assert_contains "${output}" "workflow-smoke-test.yaml" "builtin workflow visible"

mkdir -p "${tmpdir}/dogfood-repo"
cd "${tmpdir}/dogfood-repo"
git init >/dev/null 2>&1

mkdir -p "${tmpdir}/cap_home/projects/project-constitution-bootstrap"
cat > "${tmpdir}/cap_home/projects/project-constitution-bootstrap/.identity.json" <<EOF
{
  "schema_version": 2,
  "project_id": "project-constitution-bootstrap",
  "resolved_mode": "override",
  "origin_path": "${REPO_ROOT}",
  "created_at": "2026-05-13T00:00:00Z",
  "last_resolved_at": "2026-05-13T00:00:00Z",
  "migrated_at": null,
  "cap_version": null,
  "previous_versions": []
}
EOF

unset CAP_PROJECT_ID_OVERRIDE
output="$(CAP_HOME="${tmpdir}/cap_home" "${CAP_WORKFLOW}" run --dry-run project-constitution "bootstrap dogfood repo" 2>&1)" || {
  rc=$?
  fail "project-constitution dry-run should use dogfood repo id instead of colliding bootstrap id (rc=${rc}); output=${output}"
  echo "Summary: $((checks - failures)) passed, ${failures} failed"
  exit 1
}

assert_contains "${output}" "WORKFLOW DRY RUN" "project-constitution dry-run header"
if [ -d "${tmpdir}/cap_home/projects/dogfood-repo/bindings/project-constitution" ]; then
  pass
else
  fail "project-constitution dry-run should persist binding under dogfood-repo project id"
fi

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
