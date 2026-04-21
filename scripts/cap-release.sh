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
  local exact_tag
  local branch
  local commit
  local latest_tag
  local ref_kind
  local ref_value

  ensure_git_repo

  exact_tag="$(run_git describe --tags --exact-match 2>/dev/null || true)"
  branch="$(run_git branch --show-current)"
  commit="$(run_git rev-parse --short HEAD)"
  latest_tag="$(latest_release_tag)"

  if [ -n "${exact_tag}" ]; then
    ref_kind="tag"
    ref_value="${exact_tag}"
  elif [ -n "${branch}" ]; then
    ref_kind="branch"
    ref_value="${branch}"
  else
    ref_kind="commit"
    ref_value="${commit}"
  fi

  cat <<EOF
cap_root=${CAP_ROOT}
current_kind=${ref_kind}
current_ref=${ref_value}
current_commit=${commit}
default_branch=${DEFAULT_BRANCH}
latest_release_tag=${latest_tag}
EOF
}

perform_install() {
  make -C "${CAP_ROOT}" install
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
    prepare_target "${2:-latest}" >/dev/null
    perform_install
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
    prepare_target "$2" >/dev/null
    perform_install
    ;;
  *)
    usage
    ;;
esac
