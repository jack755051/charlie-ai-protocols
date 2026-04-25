#!/usr/bin/env bash
#
# Private version-control shell executor.
# Exit code contract: docs/policies/workflow-executor-exit-codes.md

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-version_control}"
user_prompt="${CAP_WORKFLOW_USER_PROMPT:-}"

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Shell Executor Report\n\n'
}

git_or_fail() {
  git "$@"
  local code=$?
  if [ "${code}" -ne 0 ]; then
    printf '\ncondition: git_operation_failed\n'
    printf 'failed_command: git %s\n' "$*"
    exit 40
  fi
}

detect_sensitive_files() {
  git status --short | awk '{print $NF}' | grep -E '(^|/)(\.env(\..*)?|credentials\.json|id_rsa|id_ed25519|.*\.pem|.*\.key)$'
}

changed_paths() {
  git status --short | awk '
    {
      path=$0
      sub(/^.../, "", path)
      if (path ~ / -> /) {
        sub(/^.* -> /, "", path)
      }
      print path
    }
  '
}

infer_type_for_path() {
  local path="$1"
  case "${path}" in
    docs/*|*.md) printf 'docs\n' ;;
    test/*|tests/*|*test*|*spec*) printf 'test\n' ;;
    scripts/*|engine/*|schemas/*|Makefile|*.sh|*.py|*.yaml|*.yml|*.json) printf 'feat\n' ;;
    *) printf 'chore\n' ;;
  esac
}

infer_scope() {
  local paths="$1"
  local first
  first="$(printf '%s\n' "${paths}" | head -n 1)"
  case "${first}" in
    docs/*|*.md) printf 'docs\n' ;;
    schemas/*) printf 'schemas\n' ;;
    engine/*) printf 'engine\n' ;;
    scripts/*) printf 'scripts\n' ;;
    *) printf 'workflow\n' ;;
  esac
}

is_release_requested() {
  printf '%s' "${user_prompt}" | grep -qiE 'release|tag|changelog|readme|發版|版本|正式'
}

highest_impact_type() {
  local types="$1"
  if printf '%s\n' "${types}" | grep -qx 'feat'; then
    printf 'feat\n'
  elif printf '%s\n' "${types}" | grep -qx 'fix'; then
    printf 'fix\n'
  elif printf '%s\n' "${types}" | grep -qx 'docs'; then
    printf 'docs\n'
  elif printf '%s\n' "${types}" | grep -qx 'test'; then
    printf 'test\n'
  else
    printf 'chore\n'
  fi
}

next_version_for_type() {
  local commit_type="$1"
  local latest
  local version
  local major minor patch
  latest="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  version="${latest#v}"
  if ! printf '%s' "${version}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    version="0.0.0"
  fi
  IFS=. read -r major minor patch <<EOF
${version}
EOF
  case "${commit_type}" in
    feat)
      minor=$((minor + 1))
      patch=0
      ;;
    fix)
      patch=$((patch + 1))
      ;;
    *)
      patch=$((patch + 1))
      ;;
  esac
  printf 'v%s.%s.%s\n' "${major}" "${minor}" "${patch}"
}

update_release_docs() {
  local next_tag="$1"
  local commit_type="$2"
  local subject="$3"
  local today
  local section
  today="$(date '+%Y-%m-%d')"
  case "${commit_type}" in
    feat) section="Added" ;;
    fix) section="Fixed" ;;
    docs) section="Changed" ;;
    test) section="Changed" ;;
    *) section="Changed" ;;
  esac

  if [ -f CHANGELOG.md ] && ! grep -q "^## \\[${next_tag}\\]" CHANGELOG.md; then
    tmp="$(mktemp)"
    awk -v tag="${next_tag}" -v today="${today}" -v section="${section}" -v subject="${subject}" '
      BEGIN { inserted=0 }
      NR == 1 { print; next }
      inserted == 0 && /^## / {
        print ""
        print "## [" tag "] - " today
        print ""
        print "### " section
        print "- " subject
        inserted=1
      }
      { print }
      END {
        if (inserted == 0) {
          print ""
          print "## [" tag "] - " today
          print ""
          print "### " section
          print "- " subject
        }
      }
    ' CHANGELOG.md > "${tmp}" && mv "${tmp}" CHANGELOG.md
  fi

  if [ -f README.md ]; then
    tmp="$(mktemp)"
    sed -E 's/最新已驗證 tag：`v[0-9]+\.[0-9]+\.[0-9]+`/最新已驗證 tag：`'"${next_tag}"'`/g' README.md > "${tmp}" && mv "${tmp}" README.md
  fi
}

print_header

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'condition: policy_blocked\nreason: not_inside_git_work_tree\n'
  exit 30
fi

branch="$(git branch --show-current 2>/dev/null || true)"
if [ -z "${branch}" ]; then
  printf 'condition: policy_blocked\nreason: detached_head\n'
  exit 30
fi

status="$(git status --short)"
printf 'branch: %s\n\n' "${branch}"
printf '### Git Status\n\n```text\n%s\n```\n\n' "${status}"

if [ -z "${status}" ]; then
  printf 'condition: no_changes\nresult: nothing_to_commit\n'
  exit 10
fi

sensitive="$(detect_sensitive_files || true)"
if [ -n "${sensitive}" ]; then
  printf 'condition: sensitive_file_risk\n'
  printf 'matched_paths:\n%s\n' "${sensitive}"
  exit 50
fi

paths="$(changed_paths)"
types="$(while IFS= read -r path; do infer_type_for_path "${path}"; done <<< "${paths}" | sort -u)"
type_count="$(printf '%s\n' "${types}" | sed '/^$/d' | wc -l | tr -d ' ')"
printf '### Diff Stat\n\n```text\n'
git diff --stat
git diff --cached --stat
printf '```\n\n'
printf 'detected_types:\n%s\n\n' "${types}"

if [ "${type_count}" -gt 1 ] && ! is_release_requested; then
  printf 'condition: mixed_change_type\n'
  printf 'reason: changed paths map to multiple conventional commit types\n'
  printf 'changed_paths:\n%s\n' "${paths}"
  exit 21
fi

if [ "${type_count}" -gt 1 ]; then
  commit_type="$(highest_impact_type "${types}")"
else
  commit_type="$(printf '%s\n' "${types}" | sed '/^$/d' | head -n 1)"
fi
if [ -z "${commit_type}" ]; then
  printf 'condition: ambiguous_change_type\nreason: unable_to_infer_commit_type\n'
  exit 20
fi

scope="$(infer_scope "${paths}")"
subject="update ${scope} workflow assets"
commit_message="${commit_type}(${scope}): ${subject}"
tag_result="not_requested"
next_tag=""

if is_release_requested; then
  next_tag="$(next_version_for_type "${commit_type}")"
  update_release_docs "${next_tag}" "${commit_type}" "${subject}"
  tag_result="pending"
fi

printf 'commit_message: %s\n\n' "${commit_message}"
git_or_fail add -A
git_or_fail commit -m "${commit_message}"
commit_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"

if [ -n "${next_tag}" ]; then
  git_or_fail tag -a "${next_tag}" -m "Release ${next_tag}"
  tag_result="created:${next_tag}"
fi

push_result="skipped"
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  if git push; then
    push_result="pushed_upstream"
  else
    printf 'condition: git_operation_failed\nfailed_command: git push\n'
    exit 40
  fi
  if [ -n "${next_tag}" ]; then
    if git push origin "${next_tag}"; then
      tag_result="pushed:${next_tag}"
    else
      printf 'condition: git_operation_failed\nfailed_command: git push origin %s\n' "${next_tag}"
      exit 40
    fi
  fi
else
  push_result="no_upstream_configured"
fi

printf '\n## 交接摘要\n\n'
printf -- '- agent_id: shell-version-control\n'
printf -- '- task_summary: private version-control shell executor completed commit\n'
printf -- '- output_paths:\n'
printf '  - %s\n' "${CAP_WORKFLOW_OUTPUT_PATH:-stdout}"
printf -- '- result: success\n'
printf -- '- commit_hash: %s\n' "${commit_hash}"
printf -- '- tag_result: %s\n' "${tag_result}"
printf -- '- push_result: %s\n' "${push_result}"
