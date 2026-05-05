#!/bin/bash

set -euo pipefail

MODE="${1:-}"
CAP_ROOT="${2:-}"
CAP_TAG="# CAP - Charlie AI Protocols"
CAP_BLOCK_START="# CAP - Charlie AI Protocols [start]"
CAP_BLOCK_END="# CAP - Charlie AI Protocols [end]"
# P0b Provider Isolation (v0.22.x): native CLI wrapping is now opt-in. The
# previous default (1) silently re-routed bare ``claude`` / ``codex`` through
# cap-entry.sh, which forced the project_id resolver to fire even outside any
# CAP project (e.g. running ``claude`` in ``$HOME``). To restore CAP-managed
# trace recording, run:  ``CAP_WRAP_NATIVE_CLI=1 make install``  — the wrapper
# block then re-installs ``codex()`` / ``claude()`` shell functions. Without
# the env override only ``cap()`` is registered; ``cap claude`` / ``cap codex``
# remain the supported CAP-managed entry points (cap-entry.sh:93-100).
WRAP_NATIVE_CLI="${CAP_WRAP_NATIVE_CLI:-0}"

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
    awk -v cap_tag="${CAP_TAG}" -v block_start="${CAP_BLOCK_START}" -v block_end="${CAP_BLOCK_END}" '
      $0 == block_start { skip=1; next }
      $0 == block_end { skip=0; next }
      skip { next }
      $0 == cap_tag { next }
      $0 ~ /^alias cap=/ { next }
      $0 ~ /^alias codex=/ { next }
      $0 ~ /^alias claude=/ { next }
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
    echo "${CAP_BLOCK_START}"
    cat <<EOF
unalias cap 2>/dev/null || true
unalias codex 2>/dev/null || true
unalias claude 2>/dev/null || true
cap() {
  bash "${CAP_ROOT}/scripts/cap-entry.sh" "\$@"
}
EOF
    if [ "${WRAP_NATIVE_CLI}" = "1" ]; then
      cat <<EOF
codex() {
  bash "${CAP_ROOT}/scripts/cap-entry.sh" codex "\$@"
}
claude() {
  bash "${CAP_ROOT}/scripts/cap-entry.sh" claude "\$@"
}
EOF
    fi
    echo "${CAP_BLOCK_END}"
  } >> "${rc_file}"

  echo "✅ 已註冊 CAP shell wrapper → ${rc_file}"
  if [ "${WRAP_NATIVE_CLI}" = "1" ]; then
    echo "   ✓ codex / claude 將透過 CAP wrapper 啟動並自動記錄 session trace"
    echo "   ⚠ 注意：裸 codex / claude 將被 CAP 接管，project_id resolver 會於每次呼叫時執行"
  else
    echo "   ✓ 裸 codex / claude 維持原生 provider 行為（不經 CAP）"
    echo "   ✓ CAP-managed session 請走 cap codex / cap claude"
    echo "   ℹ 若需要回到舊行為（CAP 包裹原生 CLI 並記錄 trace），改用 CAP_WRAP_NATIVE_CLI=1 make install"
  fi
  echo "👉 請執行 source ${rc_file} 或開新終端機生效"
}

uninstall_alias() {
  local rc_file="$1"

  rewrite_rc_without_cap_alias "${rc_file}"

  echo "✅ 已從 ${rc_file} 移除 CAP shell wrapper"
  echo "👉 當前終端仍有殘留，請開新終端機或重新 source ${rc_file}。"
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
