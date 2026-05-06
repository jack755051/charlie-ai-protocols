#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_BRANCH="${CAP_DEFAULT_BRANCH:-main}"
REMOTE_NAME="${CAP_REMOTE_NAME:-origin}"
SKIP_FETCH="${CAP_SKIP_FETCH:-0}"
FORCE_TAG_SYNC="${CAP_FORCE_TAG_SYNC:-0}"

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-release.sh version
  bash scripts/cap-release.sh release-check [--all|--recent N]
  bash scripts/cap-release.sh prepare [latest|main|<tag>|<branch>]
  bash scripts/cap-release.sh update [latest|main|<tag>|<branch>]
EOF
  exit 1
}

run_git() {
  git -C "${CAP_ROOT}" "$@"
}

ensure_git_repo() {
  run_git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "目前 CAP_ROOT 不是 git repository：${CAP_ROOT}" >&2
    exit 1
  }
}

ensure_clean_worktree() {
  local status
  status="$(run_git status --short)"
  if [ -n "${status}" ]; then
    echo "偵測到未提交變更，為避免切版覆蓋現況，請先清理工作樹後再執行。" >&2
    exit 1
  fi
}

fetch_remote() {
  if [ "${SKIP_FETCH}" = "1" ]; then
    return
  fi

  local output
  if ! output="$(run_git fetch --no-tags "${REMOTE_NAME}" --prune 2>&1)"; then
    printf '%s\n' "${output}" >&2
    cat >&2 <<EOF

cap update 無法同步 ${REMOTE_NAME} 分支 metadata。
請確認遠端名稱與網路狀態，或用 CAP_REMOTE_NAME 指定正確 remote。
EOF
    return 1
  fi

  if output="$(run_git fetch --tags "${REMOTE_NAME}" --prune 2>&1)"; then
    return
  fi

  if [ "${FORCE_TAG_SYNC}" = "1" ]; then
    run_git fetch --force --tags "${REMOTE_NAME}" --prune
    return
  fi

  printf '%s\n' "${output}" >&2
  cat >&2 <<EOF

cap update 無法同步 release tags，因為本機 tag 與 ${REMOTE_NAME} 上的同名 tag 不一致。
若你確認要以遠端 release tag 為準，請執行：

  CAP_FORCE_TAG_SYNC=1 cap update

只想檢視本機版本、不碰遠端 metadata 時，請執行：

  CAP_SKIP_FETCH=1 cap version
EOF
  return 1
}

fetch_remote_best_effort() {
  if [ "${SKIP_FETCH}" = "1" ]; then
    printf 'skipped\n'
    return
  fi

  if fetch_remote >/dev/null 2>&1; then
    printf 'fresh\n'
  else
    printf 'cache\n'
  fi
}

latest_release_tag() {
  run_git tag --list 'v*' --sort=-version:refname | head -n 1
}

is_generic_release_summary() {
  local tag="$1"
  local summary="$2"
  [ "${summary}" = "Release ${tag}" ] && return 0
  [ "${summary}" = "${tag}" ] && return 0
  return 1
}

is_low_signal_release_summary() {
  local summary="$1"
  printf '%s' "${summary}" | grep -qiE '^(feat|fix|docs|test|chore|refactor)\((docs|workflow|schemas|scripts|engine)\): update .* (assets|automation rules|documentation)$' && return 0
  printf '%s' "${summary}" | grep -qiE '^update .* (assets|automation rules|documentation)$' && return 0
  printf '%s' "${summary}" | grep -qiE '^sync release documentation$' && return 0
  return 1
}

infer_release_summary_from_paths() {
  local tag="$1"
  local paths
  paths="$(run_git diff-tree --no-commit-id --name-only -r "${tag}" 2>/dev/null || true)"

  if printf '%s\n' "${paths}" | grep -qE '(^docs/cap/IMPLEMENTATION-ROADMAP\.md$|^docs/CAP-IMPLEMENTATION-ROADMAP\.md$|^schemas/project-constitution\.schema\.yaml$|^schemas/agent-session\.schema\.yaml$|^engine/step_runtime\.py$)'; then
    printf 'add CAP platform roadmap and agent session runtime records'
    return
  fi
  if printf '%s\n' "${paths}" | grep -qE '(^scripts/cap-workflow|^scripts/workflows/vc-(scan|apply)\.sh$|^scripts/cap-release\.sh$)'; then
    printf 'tighten governed release fallback and version summaries'
    return
  fi
  if printf '%s\n' "${paths}" | grep -qE '^schemas/workflows/'; then
    printf 'update workflow contract behavior'
    return
  fi
  if printf '%s\n' "${paths}" | grep -qE '^docs/'; then
    printf 'update CAP documentation'
    return
  fi
  printf 'release metadata needs semantic repair'
}

changelog_entry_for_tag() {
  local tag="$1"
  if ! [ -f "${CAP_ROOT}/CHANGELOG.md" ]; then
    return
  fi
  awk -v tag="${tag}" '
    $0 ~ "^## \\[" tag "\\]" { in_section=1; next }
    in_section && /^## \[/ { exit }
    in_section && /^-/ {
      line=$0
      sub(/^-+[[:space:]]*/, "", line)
      print line
      exit
    }
  ' "${CAP_ROOT}/CHANGELOG.md"
}

print_cap_logo() {
  cat <<'EOF'
   ______ ___     ____
  / ____//   |   / __ \
 / /    / /| |  / /_/ /
/ /___ / ___ | / ____/
\____//_/  |_|/_/
EOF
}

change_category_for_subject() {
  local subject="$1"
  case "${subject}" in
    feat\(*|feat:*) printf 'features' ;;
    fix\(*|fix:*) printf 'bug_fixes' ;;
    docs\(*|docs:*) printf 'documentation' ;;
    *) printf 'other' ;;
  esac
}

format_change_subject() {
  local subject="$1"
  local scope summary
  scope="$(printf '%s' "${subject}" | sed -n -E 's/^[a-z]+\(([^)]+)\)!?:.*/\1/p')"
  summary="$(printf '%s' "${subject}" | sed -E 's/^[a-z]+(\([^)]+\))?!?:[[:space:]]*//')"

  if [ -n "${scope}" ]; then
    printf '%-14s %s' "[${scope}]" "${summary}"
  else
    printf '%-14s %s' "" "${summary}"
  fi
}

print_change_section() {
  local title="$1"
  local category="$2"
  local range="$3"
  local entries printed

  entries="$(run_git log --reverse --format='%h%x09%s' "${range}" 2>/dev/null || true)"
  if [ -z "${entries}" ]; then
    return
  fi

  printed=0
  echo "${entries}" | while IFS="$(printf '\t')" read -r hash subject; do
    if [ "$(change_category_for_subject "${subject}")" != "${category}" ]; then
      continue
    fi

    if [ "${printed}" -eq 0 ]; then
      printf '\n%s:\n\n' "${title}"
      printed=1
    fi
    printf ' - %-7s %s\n' "${hash}" "$(format_change_subject "${subject}")"
  done
}

print_visual_change_summary() {
  local prev_ref="$1"
  local new_ref="$2"

  if [ -z "${prev_ref}" ] || [ "${prev_ref}" = "${new_ref}" ]; then
    return
  fi

  local range
  range="${prev_ref}..${new_ref}"
  if ! run_git rev-list --quiet "${range}" >/dev/null 2>&1; then
    return
  fi
  if [ -z "$(run_git log --format='%h' "${range}" 2>/dev/null | head -n 1)" ]; then
    return
  fi

  print_change_section "Features" "features" "${range}"
  print_change_section "Bug fixes" "bug_fixes" "${range}"
  print_change_section "Documentation" "documentation" "${range}"
  print_change_section "Other changes" "other" "${range}"
  echo ""
}

release_check_tags() {
  local mode="${1:-recent}"
  local count="${2:-10}"

  case "${mode}" in
    all)
      run_git tag --list 'v*' --sort=-version:refname
      ;;
    recent)
      run_git tag --list 'v*' --sort=-version:refname | head -n "${count}"
      ;;
    *)
      echo "未知 release-check 模式：${mode}" >&2
      exit 1
      ;;
  esac
}

check_release_metadata() {
  ensure_git_repo

  local mode="recent"
  local count="10"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)
        mode="all"
        shift
        ;;
      --recent)
        mode="recent"
        count="${2:-10}"
        shift 2
        ;;
      *)
        echo "Usage: cap release-check [--all|--recent N]" >&2
        exit 1
        ;;
    esac
  done

  local tags
  tags="$(release_check_tags "${mode}" "${count}")"
  if [ -z "${tags}" ]; then
    echo "release-check: no v* tags found"
    return 0
  fi

  local issue_count=0
  echo "RELEASE METADATA CHECK"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "${tags}" | while IFS= read -r tag; do
    local annotation commit_subject changelog_entry tag_issues
    annotation="$(run_git tag -l --format='%(contents:subject)' "${tag}" 2>/dev/null)"
    commit_subject="$(run_git log -1 --format='%s' "${tag}" 2>/dev/null)"
    changelog_entry="$(changelog_entry_for_tag "${tag}")"
    tag_issues=0

    if [ -z "${annotation}" ]; then
      printf 'FAIL %-10s missing annotated tag message\n' "${tag}"
      tag_issues=$((tag_issues + 1))
    elif is_generic_release_summary "${tag}" "${annotation}" || is_low_signal_release_summary "${annotation}"; then
      printf 'FAIL %-10s low-signal tag annotation: %s\n' "${tag}" "${annotation}"
      tag_issues=$((tag_issues + 1))
    fi

    if is_low_signal_release_summary "${commit_subject}"; then
      printf 'FAIL %-10s low-signal commit subject: %s\n' "${tag}" "${commit_subject}"
      tag_issues=$((tag_issues + 1))
    fi

    if [ -z "${changelog_entry}" ]; then
      printf 'FAIL %-10s missing CHANGELOG entry\n' "${tag}"
      tag_issues=$((tag_issues + 1))
    elif is_low_signal_release_summary "${changelog_entry}"; then
      printf 'FAIL %-10s low-signal CHANGELOG entry: %s\n' "${tag}" "${changelog_entry}"
      tag_issues=$((tag_issues + 1))
    fi

    if [ "${tag_issues}" -eq 0 ]; then
      printf 'PASS %-10s %s\n' "${tag}" "${annotation:-${commit_subject}}"
    fi

    if [ "${tag_issues}" -gt 0 ]; then
      issue_count=$((issue_count + tag_issues))
    fi
    printf '%s\n' "${issue_count}" > "${CAP_ROOT}/.release-check-count.tmp"
  done

  if [ -f "${CAP_ROOT}/.release-check-count.tmp" ]; then
    issue_count="$(cat "${CAP_ROOT}/.release-check-count.tmp")"
    rm -f "${CAP_ROOT}/.release-check-count.tmp"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ "${issue_count}" -gt 0 ]; then
    echo "release-check: failed (${issue_count} issue(s))"
    return 1
  fi
  echo "release-check: passed"
}

resolve_target() {
  local target="${1:-latest}"

  case "${target}" in
    latest)
      target="$(latest_release_tag)"
      if [ -z "${target}" ]; then
        echo "找不到任何 release tag（v*）。" >&2
        exit 1
      fi
      printf '%s\n' "${target}"
      return
      ;;
    main)
      printf '%s\n' "${DEFAULT_BRANCH}"
      return
      ;;
  esac

  printf '%s\n' "${target}"
}

is_tag() {
  run_git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1
}

is_local_branch() {
  run_git show-ref --verify --quiet "refs/heads/$1"
}

is_remote_branch() {
  run_git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/$1"
}

checkout_target() {
  local target="$1"

  if is_tag "${target}"; then
    run_git checkout --detach "refs/tags/${target}"
    return
  fi

  if is_local_branch "${target}"; then
    run_git checkout "${target}"
  elif is_remote_branch "${target}"; then
    run_git checkout -B "${target}" "${REMOTE_NAME}/${target}"
  else
    echo "找不到指定版本或分支：${target}" >&2
    exit 1
  fi

  if is_remote_branch "${target}"; then
    run_git pull --ff-only "${REMOTE_NAME}" "${target}"
  fi
}

prepare_target() {
  local requested="${1:-latest}"
  local resolved

  ensure_git_repo
  ensure_clean_worktree
  fetch_remote
  resolved="$(resolve_target "${requested}")"
  checkout_target "${resolved}"
  printf '%s\n' "${resolved}"
}

show_version() {
  ensure_git_repo
  local metadata_status
  metadata_status="$(fetch_remote_best_effort)"

  local commit latest_tag current
  commit="$(run_git rev-parse --short HEAD)"
  latest_tag="$(latest_release_tag)"
  current="$(run_git describe --tags --exact-match 2>/dev/null || true)"

  echo "CAP VERSION"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ -n "${current}" ]; then
    if [ "${current}" = "${latest_tag}" ]; then
      echo "CAP ${current} (${commit}) — up to date"
    else
      echo "CAP ${current} (${commit}) — latest: ${latest_tag}"
    fi
  else
    echo "CAP ${latest_tag}+dev (${commit}) — on $(run_git branch --show-current || echo 'detached')"
  fi

  local tags
  tags="$(run_git tag --list 'v*' --sort=-version:refname | head -n 5)"
  if [ -z "${tags}" ]; then
    return
  fi

  echo ""
  printf "  %-12s %-12s %s\n" "VERSION" "DATE" "CHANGES"
  printf "  %-12s %-12s %s\n" "───────────" "──────────" "──────────────────────────────────────────"

  echo "${tags}" | while IFS= read -r tag; do
    local date summary marker
    date="$(run_git log -1 --format='%cs' "${tag}" 2>/dev/null)"
    summary="$(run_git tag -l --format='%(contents:subject)' "${tag}" 2>/dev/null)"
    # If no annotated tag message, or if annotation is generic, use the commit message.
    if [ -z "${summary}" ] || is_generic_release_summary "${tag}" "${summary}" || is_low_signal_release_summary "${summary}"; then
      summary="$(run_git log -1 --format='%s' "${tag}" 2>/dev/null)"
    fi
    if is_low_signal_release_summary "${summary}"; then
      summary="$(infer_release_summary_from_paths "${tag}")"
    fi
    # Mark current version
    marker=""
    if [ "${tag}" = "${current}" ]; then
      marker=" ←"
    fi
    printf "  %-12s %-12s %s%s\n" "${tag}" "${date}" "${summary}" "${marker}"
  done

  echo ""
  case "${metadata_status}" in
    fresh)
      echo "  Remote metadata: fresh"
      ;;
    skipped)
      echo "  Remote metadata: skipped"
      ;;
    *)
      echo "  Remote metadata: local cache"
      ;;
  esac
  echo "  Usage: cap update <version>"
}

perform_install() {
  make -C "${CAP_ROOT}" install "$@"
}

count_agents() {
  local dir="${CAP_ROOT}/agent-skills"
  find "${dir}" -maxdepth 1 -name '*-agent.md' | wc -l | tr -d ' '
}

count_strategies() {
  local dir="${CAP_ROOT}/agent-skills/strategies"
  [ -d "${dir}" ] && find "${dir}" -name '*.md' | wc -l | tr -d ' ' || echo "0"
}

count_workflows() {
  local dir="${CAP_ROOT}/schemas/workflows"
  find "${dir}" -maxdepth 1 -name '*.yaml' -o -name '*.yml' 2>/dev/null | wc -l | tr -d ' '
}

print_update_summary() {
  local prev_ref="$1"
  local new_ref="$2"

  local agents strategies workflows
  agents="$(count_agents)"
  strategies="$(count_strategies)"
  workflows="$(count_workflows)"

  echo "Updating Charlie's AI Protocols"
  echo "${new_ref}"
  print_visual_change_summary "${prev_ref}" "${new_ref}"
  echo "You can see the changelog at docs/cap/RELEASE-NOTES.md"
  print_cap_logo
  echo ""
  echo "Hooray! CAP has been updated!"
  echo ""
  printf "  %-14s %s\n" "Agents:" "${agents}"
  printf "  %-14s %s\n" "Strategies:" "${strategies}"
  printf "  %-14s %s\n" "Workflows:" "${workflows}"
  echo ""
  echo "  Run 'source ~/.zshrc' or open a new terminal to apply."
}

case "${1:-}" in
  version)
    [ "$#" -eq 1 ] || usage
    show_version
    ;;
  release-check|check)
    shift || true
    check_release_metadata "$@"
    ;;
  prepare)
    [ "$#" -le 2 ] || usage
    prepare_target "${2:-latest}" >/dev/null
    ;;
  update)
    [ "$#" -le 2 ] || usage
    ensure_git_repo
    prev_ref="$(run_git describe --tags --exact-match 2>/dev/null || run_git rev-parse --short HEAD)"
    prepare_target "${2:-latest}" >/dev/null
    new_ref="$(run_git describe --tags --exact-match 2>/dev/null || run_git rev-parse --short HEAD)"
    perform_install >/dev/null 2>&1
    print_update_summary "${prev_ref}" "${new_ref}"
    ;;
  rollback)
    # Hidden alias — delegates to update for backward compatibility
    [ "$#" -eq 2 ] || usage
    exec "$0" update "$2"
    ;;
  *)
    usage
    ;;
esac
