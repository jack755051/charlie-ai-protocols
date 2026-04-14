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

for src in "${SOURCE_DIR}"/*-agent.md; do
  [ -f "${src}" ] || continue
  filename="$(basename "${src}")"
  ln -s "../../docs/agent-skills/${filename}" "${TARGET_DIR}/${filename}"
  count=$((count + 1))
done

echo "✅ 已建立 ${count} 個 symlink → .agents/skills/"
ls -l "${TARGET_DIR}" | grep -v total
