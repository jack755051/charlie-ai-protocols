#!/usr/bin/env bash
#
# Private version-control shell executor.
# Exit code contract: docs/policies/workflow-executor-exit-codes.md

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-version_control}"
user_prompt="${CAP_WORKFLOW_USER_PROMPT:-}"
requested_mode="${CAP_WORKFLOW_REQUESTED_MODE:-}"
selected_mode="${CAP_WORKFLOW_SELECTED_MODE:-}"

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
  git status --short | while IFS= read -r line; do
    code="${line:0:2}"
    path="${line:3}"
    if printf '%s' "${path}" | grep -q ' -> '; then
      path="${path##* -> }"
    fi
    if [ "${code}" = "??" ] && [ -d "${path}" ]; then
      git ls-files --others --exclude-standard -- "${path}"
    else
      printf '%s\n' "${path}"
    fi
  done
}

diff_summary() {
  git diff --unified=0 -- 2>/dev/null
  git diff --cached --unified=0 -- 2>/dev/null
  git ls-files --others --exclude-standard | while IFS= read -r path; do
    if [ -f "${path}" ] && grep -Iq . "${path}" 2>/dev/null; then
      printf 'diff --git a/%s b/%s\n' "${path}" "${path}"
      printf '%s\n' '--- /dev/null'
      printf '+++ b/%s\n' "${path}"
      sed -n '1,120p' "${path}" | sed 's/^/+/'
    fi
  done
}

has_path() {
  local paths="$1"
  local pattern="$2"
  printf '%s\n' "${paths}" | grep -Eq "${pattern}"
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
  if has_path "${paths}" '(^schemas/workflows/|^scripts/workflows/|^scripts/cap-workflow|^engine/workflow_|^engine/step_runtime\.py|^engine/runtime_binder\.py)'; then
    printf 'workflow\n'
    return
  fi
  case "${first}" in
    docs/agent-skills/*) printf 'agent-skills\n' ;;
    docs/policies/*) printf 'policies\n' ;;
    docs/workflows/*) printf 'workflow-docs\n' ;;
    CHANGELOG.md|README.md|docs/*|*.md) printf 'docs\n' ;;
    schemas/*) printf 'schemas\n' ;;
    engine/*) printf 'engine\n' ;;
    scripts/*) printf 'scripts\n' ;;
    *) printf 'workflow\n' ;;
  esac
}

infer_type_from_diff() {
  local path_type="$1"
  local diff="$2"

  case "${path_type}" in
    docs|test)
      printf '%s\n' "${path_type}"
      return
      ;;
  esac

  if printf '%s' "${diff}" | grep -qiE '(^\+.*(fix|bug|regression|escape|quote|fail|failure|error|blocked|crash|broken|incorrect|wrong))|(^-.*bug)|(^\+.*修正)'; then
    printf 'fix\n'
    return
  fi
  if printf '%s' "${diff}" | grep -qiE '(^\+.*(refactor|extract|rename|split|consolidate|deduplicate|cleanup|simplify))|(^\+.*重構)'; then
    printf 'refactor\n'
    return
  fi
  printf '%s\n' "${path_type}"
}

subject_from_diff() {
  local commit_type="$1"
  local scope="$2"
  local paths="$3"
  local diff="$4"

  if printf '%s' "${diff}" | grep -qiE 'release_requires_ai_semantic_review|semantic release review|AI fallback required'; then
    printf 'require semantic release review'
  elif printf '%s' "${diff}" | grep -qiE 'update .* workflow assets|subject=.*workflow assets|commit_message=.*workflow assets|infer_subject|subject_from_diff|diff_summary'; then
    printf 'derive commit messages from diff signals'
  elif printf '%s' "${diff}" | grep -qiE 'fallback\.when|ambiguous_change_type|mixed_change_type|git_operation_failed|fallback'; then
    printf 'tighten workflow fallback routing'
  elif printf '%s' "${diff}" | grep -qiE 'CHANGELOG|README|release notes|latest verified tag|最新已驗證 tag'; then
    printf 'sync release documentation'
  elif printf '%s' "${diff}" | grep -qiE 'sensitive_file_risk|credential|private key|\\.env'; then
    printf 'tighten sensitive file guard'
  elif has_path "${paths}" '^schemas/workflows/'; then
    printf 'update workflow contract rules'
  elif has_path "${paths}" '^scripts/workflows/'; then
    printf 'update workflow shell executor'
  elif has_path "${paths}" '^scripts/cap-workflow|^engine/workflow_|^engine/step_runtime\.py|^engine/runtime_binder\.py'; then
    printf 'update workflow runtime handling'
  elif has_path "${paths}" '^docs/agent-skills/'; then
    printf 'clarify agent operating policy'
  elif has_path "${paths}" '^docs/policies/'; then
    printf 'clarify governance policy'
  elif has_path "${paths}" '^docs/workflows/'; then
    printf 'clarify workflow guidance'
  elif has_path "${paths}" '(^README\.md$|^CHANGELOG\.md$|^docs/)'; then
    printf 'update project documentation'
  elif [ "${commit_type}" = "test" ]; then
    printf 'update workflow regression coverage'
  else
    printf 'update %s automation rules' "${scope}"
  fi
}

is_low_signal_subject() {
  local subject="$1"
  case "${subject}" in
    "update workflow automation rules"|"update scripts automation rules"|"update schemas automation rules"|"update engine automation rules")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_release_requested() {
  [ "${requested_mode}" = "governed" ] && return 0
  [ "${selected_mode}" = "governed" ] && return 0
  printf '%s' "${user_prompt}" | grep -qiE 'release|tag|changelog|readme|發版|版本|正式'
}

explicit_release_tag() {
  printf '%s' "${user_prompt}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1
}

request_ai_release_review() {
  local paths="$1"
  local types="$2"
  local next_tag="$3"

  printf 'condition: ambiguous_change_type\n'
  printf 'reason: release_requires_ai_semantic_review\n'
  printf 'requested_release: true\n'
  printf 'suggested_next_tag: %s\n' "${next_tag}"
  printf 'detected_types:\n%s\n' "${types}"
  printf 'changed_paths:\n%s\n' "${paths}"
  printf '\nAI fallback required: inspect git diff, choose an accurate Conventional Commit message, update CHANGELOG.md / README.md if appropriate, create the release tag, and push according to project policy.\n'
  exit 20
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
diff="$(diff_summary)"
types="$(while IFS= read -r path; do infer_type_for_path "${path}"; done <<< "${paths}" | sort -u)"
type_count="$(printf '%s\n' "${types}" | sed '/^$/d' | wc -l | tr -d ' ')"
printf '### Diff Stat\n\n```text\n'
git diff --stat
git diff --cached --stat
printf '```\n\n'
printf 'detected_types:\n%s\n\n' "${types}"

if is_release_requested; then
  release_type="$(highest_impact_type "${types}")"
  if [ -z "${release_type}" ]; then
    release_type="chore"
  fi
  next_tag="$(explicit_release_tag)"
  if [ -z "${next_tag}" ]; then
    next_tag="$(next_version_for_type "${release_type}")"
  fi
  request_ai_release_review "${paths}" "${types}" "${next_tag}"
fi

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
commit_type="$(infer_type_from_diff "${commit_type}" "${diff}")"
subject="$(subject_from_diff "${commit_type}" "${scope}" "${paths}" "${diff}")"
if is_low_signal_subject "${subject}"; then
  printf 'condition: ambiguous_change_type\n'
  printf 'reason: low_signal_commit_subject\n'
  printf 'changed_paths:\n%s\n' "${paths}"
  exit 20
fi
commit_message="${commit_type}(${scope}): ${subject}"
tag_result="not_requested"
next_tag=""

printf 'commit_message: %s\n\n' "${commit_message}"
git_or_fail add -A
git_or_fail commit -m "${commit_message}"
commit_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"

if [ -n "${next_tag}" ]; then
  git_or_fail tag -a "${next_tag}" -m "${next_tag} — ${subject}"
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
