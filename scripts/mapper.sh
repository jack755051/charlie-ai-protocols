#!/bin/bash

# ==========================================
# Agent Skills Symlink Mapper
# 將 docs/agent-skills/*-agent.md 映射到 .agents/skills/
# SSOT 永遠是 docs/agent-skills/，此腳本只建立 symlink
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
SOURCE_DIR="${PROJECT_ROOT}/docs/agent-skills"
TARGET_DIR="${PROJECT_ROOT}/.agents/skills"

# 確保目標目錄存在
mkdir -p "${TARGET_DIR}"

# 清除舊的 symlink（保留 .gitkeep）
find "${TARGET_DIR}" -type l -delete

count=0
alias_count=0

for src in "${SOURCE_DIR}"/*-agent.md; do
  [ -f "${src}" ] || continue
  filename="$(basename "${src}")"

  # 長名 symlink：07-qa-agent.md（供 factory.py glob *-agent.md）
  ln -s "../../docs/agent-skills/${filename}" "${TARGET_DIR}/${filename}"
  count=$((count + 1))

  # 短名 symlink：qa.md（供 Codex $qa 調用）
  # 解析規則：{number}-{role_key}-agent.md → role_key.md
  short_name="$(echo "${filename}" | sed 's/^[0-9]*-//; s/-agent\.md/.md/')"
  ln -s "../../docs/agent-skills/${filename}" "${TARGET_DIR}/${short_name}"
  alias_count=$((alias_count + 1))
done

echo "✅ 已建立 ${count} 個 agent symlink + ${alias_count} 個短名 alias → .agents/skills/"
ls -l "${TARGET_DIR}" | grep -v total
