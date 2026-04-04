#!/bin/bash

# 確保在專案根目錄執行 (假設 protocols 掛載在 docs/skills)
PROTOCOLS_DIR="docs/skills"
TARGET_FILE=".cursorrules"

if [ "$1" == "nextjs" ]; then
    echo "🤖 正在為 Next.js 專案初始化 AI 規則..."
    
    # 1. 寫入總起手式
    echo "# Charlie's AI Protocols (Next.js Edition)" > $TARGET_FILE
    echo "你是一位資深架構師，請嚴格遵守以下所有規則：" >> $TARGET_FILE
    echo "" >> $TARGET_FILE
    
    # 2. 組合檔案
    cat $PROTOCOLS_DIR/01-general-engine.md >> $TARGET_FILE
    cat $PROTOCOLS_DIR/frontend/02-frontend-standard.md >> $TARGET_FILE
    cat $PROTOCOLS_DIR/frontend/strategies/nextjs-app-router.md >> $TARGET_FILE
    
    echo "✅ 成功產出 .cursorrules！AI 已準備就緒。"

elif [ "$1" == "cpp" ]; then
    echo "🤖 正在為 C++ 韌體專案初始化 AI 規則..."
    # 未來你可以把 C++ 的規則加在這裡
    # cat $PROTOCOLS_DIR/01-general-engine.md >> $TARGET_FILE
    # cat $PROTOCOLS_DIR/hardware/02-embedded-standard.md >> $TARGET_FILE
else
    echo "❌ 錯誤：請提供專案類型。例如：sh docs/skills/init-ai.sh nextjs"
fi