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
  bash scripts/cap-release.sh prepare [latest|main|<tag>|<branch>]
  bash scripts/cap-release.sh update [latest|main|<tag>|<branch>]
  bash scripts/cap-release.sh rollback <tag>
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

  local commit latest_tag current

  commit="$(run_git rev-parse --short HEAD)"
  latest_tag="$(latest_release_tag)"
  current="$(run_git describe --tags --exact-match 2>/dev/null || true)"

  if [ -n "${current}" ]; then
    if [ "${current}" = "${latest_tag}" ]; then
      echo "CAP ${current} (${commit}) — up to date"
    else
      echo "CAP ${current} (${commit}) — latest: ${latest_tag}"
    fi
  else
    echo "CAP ${latest_tag}+dev (${commit}) — on $(run_git branch --show-current || echo 'detached')"
  fi
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
    [ "$#" -eq 2 ] || usage
    if ! is_tag "$2"; then
      fetch_remote
    fi
    if ! is_tag "$2"; then
      echo "rollback 只接受既有 tag，例如 v0.4.0。" >&2
      exit 1
    fi
    ensure_git_repo
    prev_ref="$(run_git describe --tags --exact-match 2>/dev/null || run_git rev-parse --short HEAD)"
    prepare_target "$2" >/dev/null
    perform_install >/dev/null 2>&1
    print_update_summary "${prev_ref}" "$2"
    ;;
  *)
    usage
    ;;
esac
