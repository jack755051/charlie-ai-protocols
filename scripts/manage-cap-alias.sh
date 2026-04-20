#!/bin/bash

set -euo pipefail

MODE="${1:-}"
CAP_ROOT="${2:-}"
CAP_TAG="# CAP - Charlie AI Protocols"

detect_shell_rc() {
  if [ -n "${CAP_SHELL_RC:-}" ]; then
    printf '%s\n' "${CAP_SHELL_RC}"
    return
  fi

  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"

  case "${shell_name}" in
    zsh)
      printf '%s\n' "${HOME}/.zshrc"
      return
      ;;
    bash)
      for rc_file in "${HOME}/.bash_profile" "${HOME}/.bashrc" "${HOME}/.profile"; do
        if [ -f "${rc_file}" ]; then
          printf '%s\n' "${rc_file}"
          return
        fi
      done
      printf '%s\n' "${HOME}/.bashrc"
      return
      ;;
  esac

  for rc_file in "${HOME}/.zshrc" "${HOME}/.bash_profile" "${HOME}/.bashrc" "${HOME}/.profile"; do
    if [ -f "${rc_file}" ]; then
      printf '%s\n' "${rc_file}"
      return
    fi
  done

  printf '%s\n' "${HOME}/.profile"
}

rewrite_rc_without_cap_alias() {
  local rc_file="$1"
  local tmp_file

  mkdir -p "$(dirname "${rc_file}")"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/cap-rc.XXXXXX")"

  if [ -f "${rc_file}" ]; then
    awk -v cap_tag="${CAP_TAG}" '
      $0 == cap_tag { next }
      $0 ~ /^alias cap=/ { next }
      { print }
    ' "${rc_file}" > "${tmp_file}"
  fi

  mv "${tmp_file}" "${rc_file}"
}

install_alias() {
  local rc_file="$1"

  if [ -z "${CAP_ROOT}" ]; then
    echo "Usage: bash scripts/manage-cap-alias.sh install <cap-root>" >&2
    exit 1
  fi

  rewrite_rc_without_cap_alias "${rc_file}"
  {
    echo ""
    echo "${CAP_TAG}"
    printf "alias cap='make -C \"%s\"'\n" "${CAP_ROOT}"
  } >> "${rc_file}"

  echo "✅ 已註冊 cap alias → ${rc_file}"
  echo "👉 請執行 source ${rc_file} 或開新終端機生效"
}

uninstall_alias() {
  local rc_file="$1"

  rewrite_rc_without_cap_alias "${rc_file}"

  echo "✅ 已從 ${rc_file} 移除 cap alias"
  echo "👉 當前終端仍有殘留，請執行 unalias cap 或開新終端機。"
}

case "${MODE}" in
  detect)
    detect_shell_rc
    ;;
  install)
    install_alias "$(detect_shell_rc)"
    ;;
  uninstall)
    uninstall_alias "$(detect_shell_rc)"
    ;;
  *)
    echo "Usage: bash scripts/manage-cap-alias.sh <detect|install|uninstall> [cap-root]" >&2
    exit 1
    ;;
esac
