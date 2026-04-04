#!/bin/bash

# 從腳本所在位置定位 protocols 目錄，讓 submodule 與本 repo root 兩種執行方式都可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTOCOLS_DIR="$SCRIPT_DIR"
TARGET_FILE=".cursorrules"

write_rules() {
    local edition_name="$1"
    local strategy_file="$2"

    if [ ! -f "$PROTOCOLS_DIR/01-general-engine.md" ] || \
       [ ! -f "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" ] || \
       [ ! -f "$strategy_file" ]; then
        echo "❌ 錯誤：找不到規則檔，請確認 init-ai.sh 位於 charlie-ai-protocols 目錄內。"
        exit 1
    fi

    echo "# Charlie's AI Protocols (${edition_name})" > "$TARGET_FILE"
    echo "你是一位資深架構師，請嚴格遵守以下所有規則：" >> "$TARGET_FILE"
    echo "" >> "$TARGET_FILE"

    cat "$PROTOCOLS_DIR/01-general-engine.md" >> "$TARGET_FILE"
    cat "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" >> "$TARGET_FILE"
    cat "$strategy_file" >> "$TARGET_FILE"
}

if [ "$1" == "nextjs" ]; then
    echo "🤖 正在為 Next.js 專案初始化 AI 規則..."
    write_rules "Next.js Edition" "$PROTOCOLS_DIR/frontend/strategies/nextjs-app-router.md"
    echo "✅ 成功產出 .cursorrules！AI 已準備就緒。"

elif [ "$1" == "angular" ]; then
    echo "🤖 正在為 Angular 企業級專案初始化 AI 規則..."
    write_rules "Angular Edition" "$PROTOCOLS_DIR/frontend/strategies/angular-enterprise.md"
    echo "✅ 成功產出 .cursorrules！Angular 專家已就緒。"

elif [ "$1" == "nuxt" ]; then
    echo "🤖 正在為 Nuxt 專案初始化 AI 規則..."
    write_rules "Nuxt Composition Edition" "$PROTOCOLS_DIR/frontend/strategies/nuxt-composition.md"
    echo "✅ 成功產出 .cursorrules！Nuxt 專家已就緒。"

elif [ "$1" == "cpp" ]; then
    echo "🤖 正在為 C++ 韌體專案初始化 AI 規則..."
    # 未來你可以把 C++ 的規則加在這裡
    # cat $PROTOCOLS_DIR/01-general-engine.md >> $TARGET_FILE
    # cat $PROTOCOLS_DIR/hardware/02-embedded-standard.md >> $TARGET_FILE
else
    echo "❌ 錯誤：請提供專案類型。例如：bash docs/skills/init-ai.sh nextjs"
    echo "可用類型：nextjs | angular | nuxt | cpp"
fi
