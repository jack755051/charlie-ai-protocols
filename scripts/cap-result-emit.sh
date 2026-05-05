#!/usr/bin/env bash
#
# cap-result-emit.sh — P7 Phase B producer wiring helper.
#
# Sourceable bash helper used by ``cap-workflow-exec.sh`` end-of-run
# wiring. Aggregates a finished run_dir into the
# ``schemas/workflow-result.schema.yaml`` contract via
# ``engine/result_report_builder.build_workflow_result``, validates the
# JSON envelope, and (only on schema pass) writes both
# ``workflow-result.json`` and a fresh ``result.md`` rendered by
# ``render_result_md``.
#
# Failure modes (any of these) → return non-zero, files NOT written,
# message appended to ``workflow.log``; the caller is expected to fall
# back to its legacy hardcoded ``result.md`` template:
#   * builder import or runtime exception
#   * empty / unwritable JSON output
#   * schema validation fails
#   * builder / schema / step_runtime files missing on disk
#
# The helper deliberately never halts the run — log-only on failure, so
# a result-emitter regression cannot block workflow completion. Schema
# path is overridable via ``CAP_RESULT_SCHEMA_OVERRIDE`` (used by the
# focused wiring test to force a schema-fail path).
#
# Usage:
#   source "${SCRIPT_DIR}/cap-result-emit.sh"
#   if cap_result_emit "${run_dir}" "${cap_home}" "${status_file}" \
#                      "${out_json}" "${out_md}" "${workflow_log}"; then
#     # builder + schema OK; out_json / out_md are now in place
#   else
#     # write legacy fallback result.md
#   fi

cap_result_emit() {
  local run_dir="$1"
  local cap_home="$2"
  local status_file="$3"
  local out_json="$4"
  local out_md="$5"
  local workflow_log="$6"

  local helper_dir
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root="${CAP_ROOT:-$(cd "${helper_dir}/.." && pwd)}"
  local python_bin="${PYTHON_BIN:-python3}"
  local step_py="${STEP_PY:-${repo_root}/engine/step_runtime.py}"
  local schema="${CAP_RESULT_SCHEMA_OVERRIDE:-${repo_root}/schemas/workflow-result.schema.yaml}"
  local builder="${repo_root}/engine/result_report_builder.py"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  if [ ! -f "${builder}" ] || [ ! -f "${schema}" ] || [ ! -f "${step_py}" ]; then
    printf '[%s][workflow][workflow-result skipped: missing builder/schema/step_runtime]\n' \
      "${ts}" >> "${workflow_log}" 2>/dev/null || true
    return 1
  fi

  local tmp_json tmp_md
  tmp_json="$(mktemp -t cap-result-emit-XXXXXX.json)"
  tmp_md="$(mktemp -t cap-result-emit-XXXXXX.md)"

  PYTHONPATH="${repo_root}" "${python_bin}" - \
      "${run_dir}" "${cap_home}" "${status_file}" "${tmp_json}" "${tmp_md}" \
      <<'PY' 2>>"${workflow_log}"
import json
import sys
from pathlib import Path

from engine.result_report_builder import build_workflow_result, render_result_md

run_dir, cap_home, status_file, out_json, out_md = sys.argv[1:6]
try:
    result = build_workflow_result(
        run_dir,
        cap_home=cap_home or None,
        status_file=status_file or None,
    )
except Exception as exc:  # noqa: BLE001 — log-only fallback path.
    print(f"result_report_builder error: {exc}", file=sys.stderr)
    raise SystemExit(1)

Path(out_json).write_text(
    json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
)
Path(out_md).write_text(render_result_md(result), encoding="utf-8")
PY
  local builder_rc=$?
  if [ "${builder_rc}" -ne 0 ] || [ ! -s "${tmp_json}" ]; then
    rm -f "${tmp_json}" "${tmp_md}"
    printf '[%s][workflow][workflow-result fallback: builder rc=%s]\n' \
      "${ts}" "${builder_rc}" >> "${workflow_log}" 2>/dev/null || true
    return 1
  fi

  local schema_out schema_rc
  schema_out="$("${python_bin}" "${step_py}" validate-jsonschema "${tmp_json}" "${schema}" 2>&1)"
  schema_rc=$?
  if [ "${schema_rc}" -ne 0 ] || ! printf '%s' "${schema_out}" | grep -q '"ok": true'; then
    {
      printf '[%s][workflow][workflow-result fallback: schema validation failed]\n' "${ts}"
      printf '%s\n' "${schema_out}"
    } >> "${workflow_log}" 2>/dev/null || true
    rm -f "${tmp_json}" "${tmp_md}"
    return 1
  fi

  # Two-phase landing: JSON first, then MD. A failed mv (unwritable
  # destination, missing parent dir, ENOSPC, etc.) must NOT be reported
  # as success — the helper has to treat write failure exactly like
  # schema failure, so the caller falls back to the legacy result.md
  # template instead of leaving stale or partially-landed files behind.
  if ! mv "${tmp_json}" "${out_json}" 2>>"${workflow_log}"; then
    rm -f "${tmp_json}" "${tmp_md}"
    printf '[%s][workflow][workflow-result fallback: write failed at %s]\n' \
      "${ts}" "${out_json}" >> "${workflow_log}" 2>/dev/null || true
    return 1
  fi
  if ! mv "${tmp_md}" "${out_md}" 2>>"${workflow_log}"; then
    # JSON already landed but MD mv failed — roll back the JSON so the
    # fallback path leaves a clean state (legacy result.md only, no
    # orphan workflow-result.json claiming validated success).
    rm -f "${tmp_md}" "${out_json}"
    printf '[%s][workflow][workflow-result fallback: write failed at %s; rolled back %s]\n' \
      "${ts}" "${out_md}" "${out_json}" >> "${workflow_log}" 2>/dev/null || true
    return 1
  fi
  printf '[%s][workflow][workflow-result.json schema=ok rendered=result.md]\n' \
    "${ts}" >> "${workflow_log}" 2>/dev/null || true
  return 0
}
