#!/usr/bin/env bash
#
# test-component-fast-templates.sh — P1b slice 2 gate.
# Verifies every template referenced by
# schemas/component-types/feedback-widget.yaml exists, matches the
# audit rules, and only uses substitution tokens declared by the
# registry. Does NOT run the render script (P1b slice 3 owns that).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REGISTRY="${REPO_ROOT}/schemas/component-types/feedback-widget.yaml"
TEMPLATE_DIR="${REPO_ROOT}/templates/component-fast/feedback-widget"

[ -f "${REGISTRY}" ]      || { echo "FAIL: ${REGISTRY} missing"; exit 1; }
[ -d "${TEMPLATE_DIR}" ]  || { echo "FAIL: ${TEMPLATE_DIR} missing"; exit 1; }

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

# ── Case 1: every catalog source_template_path exists on disk ─────────
echo "Case 1: catalog source_template_path resolves to a regular file"
missing="$("${PYTHON_BIN}" - "${REGISTRY}" "${REPO_ROOT}" <<'PY'
import os
import sys
import yaml

registry, repo_root = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}
missing = []
for entry in data.get("catalog") or []:
    rel = entry.get("source_template_path") or ""
    abs_path = os.path.join(repo_root, rel)
    if not os.path.isfile(abs_path):
        missing.append(rel)
print(",".join(missing))
PY
)"
assert_eq "every catalog entry has a regular template file" "" "${missing}"

# ── Case 2: runtime-smoke.sh has executable bit (catalog says executable=true) ──
echo "Case 2: runtime-smoke.sh template is executable"
smoke_path="${TEMPLATE_DIR}/scripts/runtime-smoke.sh"
if [ -x "${smoke_path}" ]; then
  echo "  PASS: ${smoke_path} is executable"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: ${smoke_path} is NOT executable"
  fail_count=$((fail_count + 1))
fi

# ── Case 3: forbidden_core_import_patterns are NOT violated ───────────
#
# Pattern shape from the registry: "<glob>:<forbidden substring>".
# For every template file matching <glob>, the file's text must not
# contain <forbidden substring> (case-insensitive). Patterns whose
# glob matches no template file pass vacuously — that is the design
# (e.g. backend/Feedback/Domain/** has no template yet but the rule
# still guards future additions).
echo "Case 3: forbidden_core_import_patterns respected by templates"
violations="$("${PYTHON_BIN}" - "${REGISTRY}" "${TEMPLATE_DIR}" <<'PY'
import fnmatch
import os
import sys
import yaml

registry, template_dir = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}
patterns = (data.get("audit_rules") or {}).get("forbidden_core_import_patterns") or []

# Walk every template file once; cache (rel_path, content) for grep.
files = []
for root, _, names in os.walk(template_dir):
    for name in names:
        abs_path = os.path.join(root, name)
        rel = os.path.relpath(abs_path, template_dir).replace(os.sep, "/")
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as f:
                files.append((rel, f.read().lower()))
        except OSError:
            pass

violations = []
for pattern in patterns:
    if ":" not in pattern:
        continue
    glob_part, forbidden = pattern.rsplit(":", 1)
    forbidden_lower = forbidden.strip().lower()
    if not forbidden_lower:
        continue
    for rel, content in files:
        if fnmatch.fnmatch(rel, glob_part) and forbidden_lower in content:
            violations.append(f"{pattern} -> {rel}")
print(",".join(violations))
PY
)"
assert_eq "no forbidden_core_import_patterns violation" "" "${violations}"

# ── Case 4: hard_exclusions / forbidden_terms not present in templates ─
echo "Case 4: hard_exclusions terms (e.g. redis) absent from templates"
term_hits="$("${PYTHON_BIN}" - "${REGISTRY}" "${TEMPLATE_DIR}" <<'PY'
import os
import sys
import yaml

registry, template_dir = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}
terms = set()
for term in data.get("hard_exclusions") or []:
    if isinstance(term, str) and term:
        terms.add(term.lower())
for term in (data.get("audit_rules") or {}).get("forbidden_terms") or []:
    if isinstance(term, str) and term:
        terms.add(term.lower())

hits = []
for root, _, names in os.walk(template_dir):
    for name in names:
        abs_path = os.path.join(root, name)
        rel = os.path.relpath(abs_path, template_dir).replace(os.sep, "/")
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as f:
                content = f.read().lower()
        except OSError:
            continue
        for term in terms:
            if term in content:
                hits.append(f"{term} -> {rel}")
print(",".join(hits))
PY
)"
assert_eq "no forbidden term appears in any template" "" "${term_hits}"

# ── Case 5: only registered substitution tokens are used ──────────────
#
# Scan every template for ALL_CAPS ${TOKEN} occurrences. Each token
# must be either declared in `substitutions` (CAP render replacement)
# or declared in `env_vars[*].name` (runtime env interpolation —
# docker compose / shell handle these, render leaves them alone).
# Anything outside both sets is a typo and fails the test.
#
# Shell scripts (*.sh) are intentionally EXCLUDED from this check.
# Shell maintains its own variable namespace (local loop counters,
# script-internal config like SCRIPT_DIR / PROBE_RETRIES), and CAP
# tokens inside shell strings are unambiguous from context. The
# typo guard still covers the other 19 catalog files (TS / TSX /
# C# / JSON / CSS / MD / YAML / csproj / env).
echo "Case 5: every \${ALL_CAPS_TOKEN} in non-shell templates is registry-declared"
unknown_tokens="$("${PYTHON_BIN}" - "${REGISTRY}" "${TEMPLATE_DIR}" <<'PY'
import os
import re
import sys
import yaml

registry, template_dir = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}

allowed = set(data.get("substitutions") or {})
for env in data.get("env_vars") or []:
    name = env.get("name") if isinstance(env, dict) else None
    if isinstance(name, str) and name:
        allowed.add(name)

# Standalone DEFAULTs (docker compose interpolation) handled inline
# via :- expressions; capture the bare name before any colon.
token_re = re.compile(r"\$\{([A-Z][A-Z0-9_]*?)(?::[-+?][^}]*)?\}")
seen = set()
for root, _, names in os.walk(template_dir):
    for name in names:
        if name.endswith(".sh"):
            continue
        abs_path = os.path.join(root, name)
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError:
            continue
        seen.update(token_re.findall(content))

unknown = sorted(token for token in seen if token not in allowed)
print(",".join(unknown))
PY
)"
assert_eq "no unknown substitution / env tokens (non-shell)" "" "${unknown_tokens}"

# ── Case 6: at least one substitution token is referenced ─────────────
#
# Sanity check that templates actually USE the substitution table.
# A render script that has nothing to replace would still pass Cases
# 1-5 vacuously; this asserts the slice is functionally wired.
echo "Case 6: templates reference at least one substitution token"
sub_hit_count="$("${PYTHON_BIN}" - "${REGISTRY}" "${TEMPLATE_DIR}" <<'PY'
import os
import re
import sys
import yaml

registry, template_dir = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(registry, encoding="utf-8")) or {}
substitutions = set(data.get("substitutions") or {})
token_re = re.compile(r"\$\{([A-Z][A-Z0-9_]*?)\}")
hits = 0
for root, _, names in os.walk(template_dir):
    for name in names:
        abs_path = os.path.join(root, name)
        try:
            with open(abs_path, encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError:
            continue
        for token in token_re.findall(content):
            if token in substitutions:
                hits += 1
print(hits)
PY
)"
if [ "${sub_hit_count}" -ge 5 ]; then
  echo "  PASS: substitution tokens referenced ${sub_hit_count} times (>= 5)"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: substitution tokens referenced only ${sub_hit_count} times (want >= 5)"
  fail_count=$((fail_count + 1))
fi

echo ""
total=$((pass_count + fail_count))
echo "component-fast-templates: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
