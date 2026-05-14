#!/usr/bin/env bash
#
# test-component-type-registry.sh — focused P1b gate for the
# Component Fast Path component type registry.
#
# This keeps the first registry entry machine-readable before render
# scripts and template files depend on it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REGISTRY="${REPO_ROOT}/schemas/component-types/feedback-widget.yaml"

[ -f "${REGISTRY}" ] || { echo "FAIL: ${REGISTRY} missing"; exit 1; }

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
    echo "    haystack: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

echo "Case 1: registry parses and exposes canonical metadata"
meta="$("${PYTHON_BIN}" - "${REGISTRY}" <<'PY'
import sys
import yaml

path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8")) or {}
print("component_type=" + str(data.get("component_type")))
print("default_stack=" + str((data.get("defaults") or {}).get("stack_preset")))
print("default_ui=" + str((data.get("defaults") or {}).get("ui_adapter")))
print("default_store=" + str((data.get("defaults") or {}).get("storage_default")))
print("catalog_count=" + str(len(data.get("catalog") or [])))
PY
)"
assert_contains "component_type feedback-widget" "${meta}" "component_type=feedback-widget"
assert_contains "default stack preset" "${meta}" "default_stack=nextjs14_dotnet8_postgres16"
assert_contains "default ui adapter" "${meta}" "default_ui=shadcn_ui"
assert_contains "default store" "${meta}" "default_store=in_memory"

catalog_count="$(awk -F= '/^catalog_count=/ {print $2}' <<<"${meta}")"
if [ "${catalog_count}" -ge 20 ]; then
  echo "  PASS: catalog has at least 20 entries"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: catalog has at least 20 entries"
  echo "    actual: ${catalog_count}"
  fail_count=$((fail_count + 1))
fi

echo ""
echo "Case 2: every catalog entry has unique name/source/target"
case2="$("${PYTHON_BIN}" - "${REGISTRY}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
catalog = data.get("catalog") or []
names = [e.get("name") for e in catalog]
targets = [e.get("target_path") for e in catalog]
missing = [
    e.get("name") or "<unnamed>"
    for e in catalog
    if not e.get("name") or not e.get("source_template_path") or not e.get("target_path")
]
duplicate_names = sorted({x for x in names if names.count(x) > 1})
duplicate_targets = sorted({x for x in targets if targets.count(x) > 1})
print("missing=" + ",".join(missing))
print("duplicate_names=" + ",".join(duplicate_names))
print("duplicate_targets=" + ",".join(duplicate_targets))
PY
)"
assert_contains "no missing catalog fields" "${case2}" "missing="
assert_contains "no duplicate catalog names" "${case2}" "duplicate_names="
assert_contains "no duplicate target paths" "${case2}" "duplicate_targets="

echo ""
echo "Case 3: required target path groups are represented"
groups="$("${PYTHON_BIN}" - "${REGISTRY}" <<'PY'
import sys
import yaml
from collections import Counter

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
counts = Counter(e.get("artifact_group") for e in data.get("catalog") or [])
for key in ["root_config", "frontend_core", "frontend_ui", "design", "backend", "integration_runtime"]:
    print(f"{key}={counts.get(key, 0)}")
PY
)"
for group in root_config frontend_core frontend_ui design backend integration_runtime; do
  count="$(awk -F= -v key="${group}" '$1 == key {print $2}' <<<"${groups}")"
  if [ "${count:-0}" -gt 0 ]; then
    echo "  PASS: group ${group} represented"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: group ${group} represented"
    fail_count=$((fail_count + 1))
  fi
done

echo ""
echo "Case 4: no Redis in catalog targets or template paths"
redis_hits="$("${PYTHON_BIN}" - "${REGISTRY}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
hits = []
for entry in data.get("catalog") or []:
    haystack = " ".join(
        str(entry.get(k) or "")
        for k in ["name", "source_template_path", "target_path", "artifact_group"]
    ).lower()
    if "redis" in haystack:
        hits.append(entry.get("name") or "<unnamed>")
print(",".join(hits))
PY
)"
assert_eq "catalog does not reference Redis" "" "${redis_hits}"

echo ""
echo "Case 5: executable runtime smoke entry exists"
smoke="$("${PYTHON_BIN}" - "${REGISTRY}" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for entry in data.get("catalog") or []:
    if entry.get("target_path") == "scripts/runtime-smoke.sh":
        print(f"required={entry.get('required')};executable={entry.get('executable')}")
        break
PY
)"
assert_eq "runtime smoke required executable" "required=True;executable=True" "${smoke}"

echo ""
total=$((pass_count + fail_count))
echo "component-type-registry: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
