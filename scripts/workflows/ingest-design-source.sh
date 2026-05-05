#!/usr/bin/env bash
#
# ingest-design-source.sh — Pipeline step: deterministically ingest the
# project's design source package into a versioned docs/design/ summary
# bundle so downstream UI steps consume a stable, hash-cached digest
# instead of re-reading the raw design package every run.
#
# Reads:
#   - Project Constitution in $CWD (design_source block; v0.20.0+ shape).
#     P0c batch 2.6 dual-path: prefers .cap/constitution.yaml (new namespace)
#     and falls back to legacy .cap.constitution.yaml when only the legacy
#     file exists. The actual lookup is delegated to
#     engine/step_runtime._read_constitution_design_source so this script
#     stays in sync with the rest of the engine.
#   - Project's runtime workspace via $CAP_HOME (defaults ~/.cap)
#
# Behavior:
#   1. Resolve the active design source path through the same three-step
#      logic as engine/step_runtime.py _design_source_path:
#        constitution.design_source.source_path  →
#        constitution.design_source.{design_root,package} join  →
#        legacy ~/.cap/designs/<project_id> fallback
#      Constitution.design_source.type == "none" or missing source path
#      means the project has no design ingest target and we exit 0
#      cleanly with a markdown report saying so.
#   2. Compute a SHA256 hash over every file under source_path
#      (sorted by relative path) so renames and content edits both
#      invalidate the cache. Skip dotfiles and .DS_Store.
#   3. Read the sentinel docs/design/.source-hash.txt if present. If the
#      hash matches and all three artifacts (source-summary.md,
#      source-tree.txt, design-source.yaml) already exist, skip rebuild
#      and exit 0 with a "cached" report.
#   4. Otherwise rebuild the bundle:
#        docs/design/source-summary.md     human-readable summary
#        docs/design/source-tree.txt        deterministic file list
#        docs/design/design-source.yaml     machine-readable metadata
#      Plus update the sentinel hash file.
#
# Output target:
#   <cwd>/docs/design/   (relative to the project root)
#
# Exit codes:
#   - 0  : success (rebuilt, cached-hit, or design_source.type none)
#   - 40 : critical failure — source_path declared but missing on disk,
#          write failure, malformed constitution.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-ingest_design_source}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Design Source Ingest Report\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: schema_validation_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  # exit 41 = schema_validation_failed (schema-class executor per
  # policies/workflow-executor-exit-codes.md). Distinct from 40
  # git_operation_failed used by vc-class executors.
  exit 41
}

print_header

# Single-shot Python: resolve, hash, compare, rebuild.
result_payload="$(
  CAP_HOME="${CAP_HOME:-${HOME}/.cap}" \
  CAP_PROJECT_ROOT="${PWD}" \
  CAP_REPO_ROOT="${CAP_ROOT}" \
  "${PYTHON_BIN}" - <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

project_root = Path(os.environ["CAP_PROJECT_ROOT"]).resolve()
repo_root = Path(os.environ["CAP_REPO_ROOT"]).resolve()
cap_home = Path(os.environ["CAP_HOME"]).expanduser()

sys.path.insert(0, str(repo_root / "engine"))
try:
    import step_runtime  # type: ignore[import]
except Exception as exc:
    print(f"ERROR:cannot_import_step_runtime:{exc}", file=sys.stderr)
    raise SystemExit(2)

# We need _design_source_path to read constitution from project_root, so chdir.
os.chdir(project_root)

constitution_block = step_runtime._read_constitution_design_source()
source_type = ""
if isinstance(constitution_block, dict):
    source_type = str(constitution_block.get("type") or "")

design_dir = project_root / "docs" / "design"
sentinel = design_dir / ".source-hash.txt"
summary_md = design_dir / "source-summary.md"
tree_txt = design_dir / "source-tree.txt"
metadata_yaml = design_dir / "design-source.yaml"

# Type none or block missing => no-op success
if constitution_block is None and source_type == "":
    # Probe legacy fallback: only treat as ingestable if the directory exists.
    legacy_path = step_runtime._design_source_path()
    if not legacy_path.is_dir() or not any(legacy_path.iterdir()):
        print(json.dumps({
            "outcome": "no_design_source",
            "reason": "constitution has no design_source block and legacy fallback path is empty or missing",
            "design_dir": str(design_dir),
        }))
        raise SystemExit(0)
    source_path = legacy_path
    source_descriptor = {"type": "legacy_fallback", "source_path": str(legacy_path)}
elif source_type == "none":
    print(json.dumps({
        "outcome": "design_source_type_none",
        "reason": "constitution.design_source.type == none; nothing to ingest",
        "design_dir": str(design_dir),
    }))
    raise SystemExit(0)
else:
    source_path = step_runtime._design_source_path()
    if not source_path.is_dir():
        print(
            f"ERROR:source_path_missing:{source_path}",
            file=sys.stderr,
        )
        raise SystemExit(3)
    source_descriptor = {
        "type": source_type or "local_design_package",
        "design_root": str((constitution_block or {}).get("design_root") or ""),
        "package": str((constitution_block or {}).get("package") or ""),
        "source_path": str(source_path),
        "mode": str((constitution_block or {}).get("mode") or "read_only_reference"),
    }

# Walk files deterministically (sorted by relative path), skip .DS_Store and dotfiles.
files: list[Path] = []
for path in sorted(source_path.rglob("*"), key=lambda p: str(p.relative_to(source_path))):
    if not path.is_file():
        continue
    rel = path.relative_to(source_path)
    if any(part.startswith(".") for part in rel.parts):
        continue
    if path.name == ".DS_Store":
        continue
    files.append(path)

hasher = hashlib.sha256()
total_bytes = 0
for f in files:
    rel = f.relative_to(source_path)
    hasher.update(str(rel).encode("utf-8"))
    hasher.update(b"\0")
    blob = f.read_bytes()
    hasher.update(blob)
    hasher.update(b"\0")
    total_bytes += len(blob)
current_hash = hasher.hexdigest()

# Check cache
prior_hash = ""
if sentinel.is_file():
    prior_hash = sentinel.read_text(encoding="utf-8").strip()

cache_hit = (
    prior_hash == current_hash
    and summary_md.is_file()
    and tree_txt.is_file()
    and metadata_yaml.is_file()
)

if cache_hit:
    print(json.dumps({
        "outcome": "cached",
        "source_path": str(source_path),
        "files_count": len(files),
        "total_bytes": total_bytes,
        "hash": current_hash,
        "design_dir": str(design_dir),
        "artifacts": {
            "source_summary": str(summary_md),
            "source_tree": str(tree_txt),
            "design_source_metadata": str(metadata_yaml),
        },
    }))
    raise SystemExit(0)

# Rebuild
design_dir.mkdir(parents=True, exist_ok=True)

# tree
tree_lines = [str(f.relative_to(source_path)) for f in files]
tree_txt.write_text("\n".join(tree_lines) + ("\n" if tree_lines else ""), encoding="utf-8")

# summary
summary_lines = [
    "# Design Source Summary",
    "",
    f"- source_path: `{source_path}`",
    f"- type: `{source_descriptor.get('type', '')}`",
    f"- package: `{source_descriptor.get('package', '')}`",
    f"- file_count: {len(files)}",
    f"- total_bytes: {total_bytes}",
    f"- sha256: `{current_hash}`",
    f"- generated_at: {datetime.now(timezone.utc).isoformat()}",
    "",
    "## File Tree",
    "",
    "```",
] + tree_lines + ["```", ""]
summary_md.write_text("\n".join(summary_lines), encoding="utf-8")

# metadata yaml (hand-written; deterministic)
yaml_lines = [
    f"schema_version: 1",
    f"source_path: {source_descriptor.get('source_path', '')}",
    f"type: {source_descriptor.get('type', '')}",
    f"design_root: {source_descriptor.get('design_root', '')}",
    f"package: {source_descriptor.get('package', '')}",
    f"mode: {source_descriptor.get('mode', '')}",
    f"file_count: {len(files)}",
    f"total_bytes: {total_bytes}",
    f"sha256: {current_hash}",
    f"generated_at: {datetime.now(timezone.utc).isoformat()}",
]
metadata_yaml.write_text("\n".join(yaml_lines) + "\n", encoding="utf-8")

# sentinel
sentinel.write_text(current_hash + "\n", encoding="utf-8")

print(json.dumps({
    "outcome": "rebuilt",
    "source_path": str(source_path),
    "files_count": len(files),
    "total_bytes": total_bytes,
    "hash": current_hash,
    "design_dir": str(design_dir),
    "artifacts": {
        "source_summary": str(summary_md),
        "source_tree": str(tree_txt),
        "design_source_metadata": str(metadata_yaml),
    },
}))
PY
)"
ingest_rc=$?

if [ ${ingest_rc} -ne 0 ]; then
  fail_with "ingest_failed" "${result_payload}" "rc=${ingest_rc}"
fi

outcome="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["outcome"])')"

case "${outcome}" in
  no_design_source|design_source_type_none)
    printf -- 'condition: ok\n'
    printf -- 'outcome: %s\n' "${outcome}"
    printf -- '\n'
    printf -- '## Output Artifacts\n\n'
    printf -- '(none — project declared no design source)\n'
    exit 0
    ;;
  cached|rebuilt)
    summary_path="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["artifacts"]["source_summary"])')"
    tree_path="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["artifacts"]["source_tree"])')"
    yaml_path="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["artifacts"]["design_source_metadata"])')"
    files_count="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["files_count"])')"
    hash_value="$(printf '%s' "${result_payload}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.loads(sys.stdin.read())["hash"])')"
    printf -- 'condition: ok\n'
    printf -- 'outcome: %s\n' "${outcome}"
    printf -- 'files_count: %s\n' "${files_count}"
    printf -- 'sha256: %s\n' "${hash_value}"
    printf -- '\n'
    printf -- '## Output Artifacts\n\n'
    printf -- '- name=design_source_summary path=%s\n' "${summary_path}"
    printf -- '- name=design_source_tree path=%s\n' "${tree_path}"
    printf -- '- name=design_source_metadata path=%s\n' "${yaml_path}"
    exit 0
    ;;
  *)
    fail_with "unexpected_outcome" "${outcome}" "${result_payload}"
    ;;
esac
