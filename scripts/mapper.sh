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
      echo "❌ 錯誤：未知的 CAP_LINK_MODE='${requested_mode}'，只接受 auto|symlink|copy" >&2
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
  echo "🗑  正在移除全域安裝..."

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
  if [ -f "${HOME}/.claude/CLAUDE.md" ] && grep -q "charlie-ai-protocols" "${HOME}/.claude/CLAUDE.md" 2>/dev/null; then
    rm "${HOME}/.claude/CLAUDE.md"
  fi

  echo "✅ 全域安裝已移除（Codex + Claude Code）。"
  exit 0
fi

# ----------------------------------------------------------
# 決定目標路徑與同步模式
# ----------------------------------------------------------
if [ "${MODE}" = "--global" ]; then
  TARGET_DIR="${HOME}/.agents/skills"
  CODEX_DIR="${HOME}/.codex"
  USE_ABSOLUTE=true
  echo "🌐 全域模式：目標 → ${TARGET_DIR}"
else
  TARGET_DIR="${PROJECT_ROOT}/.agents/skills"
  USE_ABSOLUTE=false
  echo "📁 本地模式：目標 → ${TARGET_DIR}"
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
  echo "🔗 使用 symlink 模式同步 Agent Skills"
else
  echo "📄 使用 copy 模式同步 Agent Skills（目前環境不支援 symlink）"
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

echo "✅ 已同步 ${count} 個 agent entry + ${alias_count} 個短名 alias → ${TARGET_DIR}/"

# ----------------------------------------------------------
# 全域模式：額外產生 ~/.codex/AGENTS.md
# ----------------------------------------------------------
if [ "${USE_ABSOLUTE}" = true ]; then
  # ==============================================================
  # Codex：產生全域 ~/.codex/AGENTS.md
  # ==============================================================
  mkdir -p "${CODEX_DIR}"
  cat > "${CODEX_DIR}/AGENTS.md" << AGENTS_EOF
# Charlie's AI Protocols — Global Scope

> Auto-generated by charlie-ai-protocols/scripts/mapper.sh --global
> Source: ${PROJECT_ROOT}

## Core Protocol

All agents must follow the global constitution:
${SOURCE_DIR}/00-core-protocol.md

## Git Workflow

${PROJECT_ROOT}/policies/git-workflow.md

## Conventions

- All communication with the user must be in **Traditional Chinese (繁體中文)**.
- Commit messages follow Conventional Commits: \`<type>(<scope>): <subject>\`.
AGENTS_EOF

  echo "✅ 已產生 Codex 全域指令檔 → ${CODEX_DIR}/AGENTS.md"

  # ==============================================================
  # Claude Code：產生全域 ~/.claude/CLAUDE.md（使用 @ 匯入）
  # ==============================================================
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/CLAUDE.md" << CLAUDE_EOF
# Charlie's AI Protocols — Global Scope

> Auto-generated by charlie-ai-protocols/scripts/mapper.sh --global
> Source: ${PROJECT_ROOT}

## Core Protocol

@${SOURCE_DIR}/00-core-protocol.md

## Git Workflow

@${PROJECT_ROOT}/policies/git-workflow.md

## Conventions

- All communication with the user must be in **Traditional Chinese (繁體中文)**.
- Commit messages follow Conventional Commits: \`<type>(<scope>): <subject>\`.
CLAUDE_EOF

  echo "✅ 已產生 Claude Code 全域指令檔 → ~/.claude/CLAUDE.md"

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
    echo "✅ 已以 symlink 模式同步 ${rule_count} 個 agent 規則 → ~/.claude/rules/"
  else
    echo "✅ 已以 copy 模式同步 ${rule_count} 個 agent 規則 → ~/.claude/rules/"
  fi
fi

# 詳細列表僅在 --verbose 時顯示
if [ "${VERBOSE:-}" = true ]; then
  ls -l "${TARGET_DIR}" | grep -v total
fi
