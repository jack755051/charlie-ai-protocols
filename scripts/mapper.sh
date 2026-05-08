#!/bin/bash

# ==========================================
# Agent Skills Sync Mapper
#
# 用法：
#   bash mapper.sh              本地模式（.agents/skills/，相對路徑）
#   bash mapper.sh --global     全域模式（~/.agents/skills/，絕對路徑）
#   bash mapper.sh --uninstall  移除全域安裝
#
# SSOT 永遠是 agent-skills/，此腳本預設建立 symlink；
# 若當前環境不支援 symlink，才 fallback 為 copy。
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${PROJECT_ROOT}/agent-skills"
MANAGED_FILE_NAME=".cap-managed"

MODE="${1:---local}"

resolve_short_name() {
  local filename="$1"

  case "${filename}" in
    02a-ba-agent.md)
      echo "ba.md"
      ;;
    02b-dba-api-agent.md)
      echo "dba.md"
      ;;
    *)
      echo "${filename}" | sed -E 's/^[0-9]+[a-z]*-//; s/-agent\.md$/.md/'
      ;;
  esac
}

managed_file_path() {
  local dir="$1"
  printf '%s/%s\n' "${dir}" "${MANAGED_FILE_NAME}"
}

clear_managed_entries() {
  local dir="$1"
  local managed_file

  managed_file="$(managed_file_path "${dir}")"

  if [ -f "${managed_file}" ]; then
    while IFS= read -r entry; do
      [ -n "${entry}" ] || continue
      rm -f "${dir}/${entry}"
    done < "${managed_file}"
    rm -f "${managed_file}"
  fi
}

clear_repo_symlinks() {
  local dir="$1"

  [ -d "${dir}" ] || return

  find "${dir}" -maxdepth 1 -type l | while read -r link; do
    target="$(readlink "${link}")"
    if [[ "${target}" == "${PROJECT_ROOT}"* ]]; then
      rm -f "${link}"
    fi
  done
}

prepare_managed_file() {
  local dir="$1"
  : > "$(managed_file_path "${dir}")"
}

register_managed_entry() {
  local dir="$1"
  local entry="$2"
  printf '%s\n' "${entry}" >> "$(managed_file_path "${dir}")"
}

detect_link_mode() {
  local target_dir="$1"
  local requested_mode="${CAP_LINK_MODE:-auto}"
  local probe_source="${target_dir}/.cap-link-probe-source"
  local probe_link="${target_dir}/.cap-link-probe-link"

  case "${requested_mode}" in
    symlink)
      printf 'symlink\n'
      return
      ;;
    copy)
      printf 'copy\n'
      return
      ;;
    auto)
      ;;
    *)
      echo "❌ Error: unknown CAP_LINK_MODE='${requested_mode}'. Accepted values: auto|symlink|copy" >&2
      exit 1
      ;;
  esac

  rm -f "${probe_source}" "${probe_link}"
  : > "${probe_source}"

  if ln -s "$(basename "${probe_source}")" "${probe_link}" 2>/dev/null; then
    rm -f "${probe_source}" "${probe_link}"
    printf 'symlink\n'
    return
  fi

  rm -f "${probe_source}" "${probe_link}"
  printf 'copy\n'
}

materialize_entry() {
  local source_path="$1"
  local link_target="$2"
  local destination_path="$3"
  local link_mode="$4"

  rm -f "${destination_path}"

  if [ "${link_mode}" = "symlink" ]; then
    ln -s "${link_target}" "${destination_path}"
  else
    cp "${source_path}" "${destination_path}"
  fi
}

# ----------------------------------------------------------
# 移除全域安裝
# ----------------------------------------------------------
if [ "${MODE}" = "--uninstall" ]; then
  echo "🗑  Removing global install..."

  # --- Codex：移除 ~/.agents/skills/ 中由本 Repo 產生的項目 ---
  if [ -d "${HOME}/.agents/skills" ]; then
    clear_managed_entries "${HOME}/.agents/skills"
    clear_repo_symlinks "${HOME}/.agents/skills"
    rmdir "${HOME}/.agents/skills" 2>/dev/null || true
    rmdir "${HOME}/.agents" 2>/dev/null || true
  fi

  # --- Codex：移除 ~/.codex/AGENTS.md ---
  if [ -f "${HOME}/.codex/AGENTS.md" ] && grep -q "charlie-ai-protocols" "${HOME}/.codex/AGENTS.md" 2>/dev/null; then
    rm "${HOME}/.codex/AGENTS.md"
    rmdir "${HOME}/.codex" 2>/dev/null || true
  fi

  # --- Claude Code：移除 ~/.claude/rules/ 中由本 Repo 產生的項目 ---
  if [ -d "${HOME}/.claude/rules" ]; then
    clear_managed_entries "${HOME}/.claude/rules"
    clear_repo_symlinks "${HOME}/.claude/rules"
  fi

  # --- Claude Code：移除 ~/.claude/CLAUDE.md（僅當內容是本腳本產生的）---
  #
  # Heuristic：檔內含 "charlie-ai-protocols" 字串視為舊 mapper 自動產生
  # 的全域檔；P0b Provider Isolation 後 mapper.sh 不再寫此檔，這條 cleanup
  # 邏輯保留是為了讓既有用戶跑 ``make uninstall && make install`` 時可以
  # 正確清除舊安裝痕跡。**警告**：若使用者在舊 auto-gen 檔上手動加了個人
  # section（如 ## Behavioral Guardrails），同樣會被刪除 — 升級前請先備份。
  if [ -f "${HOME}/.claude/CLAUDE.md" ] && grep -q "charlie-ai-protocols" "${HOME}/.claude/CLAUDE.md" 2>/dev/null; then
    echo "⚠ Detected legacy auto-generated ~/.claude/CLAUDE.md (carries the charlie-ai-protocols marker)."
    echo "   It will be removed. If you added personal sections to this file, please back it up first:"
    echo "   cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.backup"
    rm "${HOME}/.claude/CLAUDE.md"
    echo "   ✓ Removed the legacy global CLAUDE.md (no longer auto-written since v0.22.x)"
  fi

  echo "✅ Global install removed (Codex + Claude Code rules)."
  echo "ℹ Since v0.22.x, mapper.sh no longer maintains ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md."
  echo "  Project rules are now loaded from the repo-local CLAUDE.md / AGENTS.md (only inside the project directory)."
  exit 0
fi

# ----------------------------------------------------------
# 決定目標路徑與同步模式
# ----------------------------------------------------------
if [ "${MODE}" = "--global" ]; then
  TARGET_DIR="${HOME}/.agents/skills"
  CODEX_DIR="${HOME}/.codex"
  USE_ABSOLUTE=true
  echo "🌐 Global mode: target → ${TARGET_DIR}"
else
  TARGET_DIR="${PROJECT_ROOT}/.agents/skills"
  USE_ABSOLUTE=false
  echo "📁 Local mode: target → ${TARGET_DIR}"
fi

# 確保目標目錄存在
mkdir -p "${TARGET_DIR}"

# 清除舊的受管項目（本地模式清全部；全域模式只清指向本 Repo 或舊 manifest）
if [ "${USE_ABSOLUTE}" = true ]; then
  clear_managed_entries "${TARGET_DIR}"
  clear_repo_symlinks "${TARGET_DIR}"
else
  clear_managed_entries "${TARGET_DIR}"
  find "${TARGET_DIR}" -type l -delete
fi

LINK_MODE="$(detect_link_mode "${TARGET_DIR}")"
prepare_managed_file "${TARGET_DIR}"

if [ "${LINK_MODE}" = "symlink" ]; then
  echo "🔗 Syncing Agent Skills using symlink mode"
else
  echo "📄 Syncing Agent Skills using copy mode (current environment does not support symlinks)"
fi

# ----------------------------------------------------------
# 建立 Agent Skills 同步入口
# ----------------------------------------------------------
count=0
alias_count=0

for src in "${SOURCE_DIR}"/*-agent.md; do
  [ -f "${src}" ] || continue
  filename="$(basename "${src}")"

  # 決定映射來源路徑
  if [ "${USE_ABSOLUTE}" = true ]; then
    link_target="${SOURCE_DIR}/${filename}"
  else
    link_target="../../agent-skills/${filename}"
  fi

  # 長名 entry：07-qa-agent.md（供 factory.py glob *-agent.md）
  materialize_entry "${src}" "${link_target}" "${TARGET_DIR}/${filename}" "${LINK_MODE}"
  register_managed_entry "${TARGET_DIR}" "${filename}"
  count=$((count + 1))

  # 短名 entry：qa.md（供 Codex $qa 調用）
  short_name="$(resolve_short_name "${filename}")"
  materialize_entry "${src}" "${link_target}" "${TARGET_DIR}/${short_name}" "${LINK_MODE}"
  register_managed_entry "${TARGET_DIR}" "${short_name}"
  alias_count=$((alias_count + 1))
done

echo "✅ Synced ${count} agent entries + ${alias_count} short-name aliases → ${TARGET_DIR}/"

# ----------------------------------------------------------
# 全域模式：同步 agent skill rules 到 ~/.claude/rules/
# ----------------------------------------------------------
#
# P0b Provider Isolation (v0.22.x): mapper.sh **不再**寫入
# ~/.claude/CLAUDE.md 與 ~/.codex/AGENTS.md。理由：
#
#   1. 全域檔會強塞 CAP 專案憲法到「每個」claude/codex session，
#      不論 user 在哪個目錄；違反 Provider Isolation 原則。
#   2. 全域 ~/.claude/CLAUDE.md 是 user-owned；installer 不該覆寫
#      使用者自己的全域規則（如 Karpathy guidelines、個人 guardrails）。
#   3. 專案規則應該透過 repo-local CLAUDE.md / AGENTS.md 載入 —
#      claude / codex 進專案目錄時自動讀，不在專案外觸發。
#
# 仍會同步的：~/.claude/rules/*-agent.md symlink（被動 reference，
# 不會自動載入；user 主動 @import 才生效，零副作用）。詳見
# docs/cap/ARCHITECTURE.md §Provider Isolation。
if [ "${USE_ABSOLUTE}" = true ]; then
  # ==============================================================
  # Claude Code：同步 agents 到 ~/.claude/rules/
  # ==============================================================
  mkdir -p "${HOME}/.claude/rules"

  # 先清除舊的受管項目
  clear_managed_entries "${HOME}/.claude/rules"
  clear_repo_symlinks "${HOME}/.claude/rules"
  RULE_LINK_MODE="$(detect_link_mode "${HOME}/.claude/rules")"
  prepare_managed_file "${HOME}/.claude/rules"

  rule_count=0
  for src in "${SOURCE_DIR}"/*-agent.md; do
    [ -f "${src}" ] || continue
    filename="$(basename "${src}")"
    materialize_entry "${src}" "${src}" "${HOME}/.claude/rules/${filename}" "${RULE_LINK_MODE}"
    register_managed_entry "${HOME}/.claude/rules" "${filename}"
    rule_count=$((rule_count + 1))
  done

  if [ "${RULE_LINK_MODE}" = "symlink" ]; then
    echo "✅ Synced ${rule_count} agent rules via symlink mode → ~/.claude/rules/"
  else
    echo "✅ Synced ${rule_count} agent rules via copy mode → ~/.claude/rules/"
  fi
fi

# 詳細列表僅在 --verbose 時顯示
if [ "${VERBOSE:-}" = true ]; then
  ls -l "${TARGET_DIR}" | grep -v total
fi
