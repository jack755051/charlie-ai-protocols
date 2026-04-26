#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_BRANCH="${CAP_DEFAULT_BRANCH:-main}"
REMOTE_NAME="${CAP_REMOTE_NAME:-origin}"
SKIP_FETCH="${CAP_SKIP_FETCH:-0}"

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

  run_git fetch --tags "${REMOTE_NAME}" --prune
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
  if printf '%s\n' "${paths}" | grep -qE '(^scripts/cap-workflow|^scripts/workflows/version-control-private\.sh$|^scripts/cap-release\.sh$)'; then
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
  fetch_remote 2>/dev/null

  local commit latest_tag current
  commit="$(run_git rev-parse --short HEAD)"
  latest_tag="$(latest_release_tag)"
  current="$(run_git describe --tags --exact-match 2>/dev/null || true)"

  # Current version
  if [ -n "${current}" ]; then
    if [ "${current}" = "${latest_tag}" ]; then
      echo "CAP ${current} (${commit}) — up to date"
    else
      echo "CAP ${current} (${commit}) — latest: ${latest_tag}"
    fi
  else
    echo "CAP ${latest_tag}+dev (${commit}) — on $(run_git branch --show-current || echo 'detached')"
  fi

  # Recent releases
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
  echo "  Usage: cap update <version>"
}

perform_install() {
  make -C "${CAP_ROOT}" install "$@"
}

count_agents() {
  local dir="${CAP_ROOT}/docs/agent-skills"
  find "${dir}" -maxdepth 1 -name '*-agent.md' | wc -l | tr -d ' '
}

count_strategies() {
  local dir="${CAP_ROOT}/docs/agent-skills/strategies"
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

  echo ""
  echo "CAP updated → ${new_ref}"
  echo ""
  printf "  %-14s %s\n" "Agents:" "${agents}"
  printf "  %-14s %s\n" "Strategies:" "${strategies}"
  printf "  %-14s %s\n" "Workflows:" "${workflows}"
  echo ""

  # Show changelog since previous version
  if [ -n "${prev_ref}" ] && [ "${prev_ref}" != "${new_ref}" ]; then
    local log
    log="$(run_git log --oneline "${prev_ref}..${new_ref}" 2>/dev/null || true)"
    if [ -n "${log}" ]; then
      echo "  Changes since ${prev_ref}:"
      echo "${log}" | while IFS= read -r line; do
        echo "    ${line}"
      done
      echo ""
    fi
  fi

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
