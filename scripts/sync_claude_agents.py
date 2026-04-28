#!/usr/bin/env python3
"""將 agent-skills/*-agent.md 轉換為 Claude Code 子代理格式。

來源（唯讀）：agent-skills/*-agent.md（CrewAI 角色定義）
產出：.claude/agents/*.md（Claude Code 子代理，帶 YAML frontmatter）

預設輸出至專案 .claude/agents/（git 不追蹤），可用 --user 切到 ~/.claude/agents/。
00-core-protocol.md 會被 prepend 到每個輸出檔，確保憲法生效。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CORE_PROTOCOL_FILE = "00-core-protocol.md"
AGENT_GLOB = "*-agent.md"

IDENTITY_RE = re.compile(r"^\s*-\s+\*\*你的身分\*\*：(.+?)$", re.MULTILINE)
DESCRIPTION_MAX_LEN = 200


def extract_description(content: str, fallback: str) -> str:
    """從 agent 內容中抓「你的身分」第一句作為 description。"""
    match = IDENTITY_RE.search(content)
    if not match:
        return fallback
    raw = match.group(1).strip()
    # 取第一個句號之前的內容
    for delim in ("。", "！", "？", "."):
        idx = raw.find(delim)
        if idx > 0:
            raw = raw[:idx]
            break
    raw = raw.replace("\n", " ").strip()
    if len(raw) > DESCRIPTION_MAX_LEN:
        raw = raw[: DESCRIPTION_MAX_LEN - 1] + "…"
    return raw or fallback


def yaml_quote(value: str) -> str:
    """以 double-quote 包裝字串並跳脫內部引號與換行。"""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{escaped}"'


def derive_name(stem: str) -> str:
    """01-supervisor-agent → 01-supervisor。"""
    if stem.endswith("-agent"):
        return stem[: -len("-agent")]
    return stem


def build_output(core_preamble: str, agent_content: str, name: str, description: str) -> str:
    frontmatter = (
        "---\n"
        f"name: {name}\n"
        f"description: {yaml_quote(description)}\n"
        "---\n\n"
    )
    body = (
        f"{core_preamble.rstrip()}\n\n---\n\n{agent_content.lstrip()}"
        if core_preamble
        else agent_content.lstrip()
    )
    return frontmatter + body


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="將 agent-skills/*-agent.md 同步為 Claude Code 子代理。"
    )
    parser.add_argument(
        "--user",
        action="store_true",
        help="輸出到 ~/.claude/agents/（使用者層級）；預設為專案 .claude/agents/。",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="僅顯示將寫入的檔案清單，不實際寫檔。",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="覆寫已存在的目標檔（預設會保留手動編輯，跳過已存在檔）。",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    base_dir = Path(__file__).resolve().parents[1]
    prompts_dir = base_dir / "agent-skills"

    if not prompts_dir.exists():
        print(f"❌ 找不到來源目錄：{prompts_dir}", file=sys.stderr)
        return 1

    target_dir = (
        Path.home() / ".claude" / "agents"
        if args.user
        else base_dir / ".claude" / "agents"
    )

    core_path = prompts_dir / CORE_PROTOCOL_FILE
    core_preamble = core_path.read_text(encoding="utf-8") if core_path.exists() else ""
    if core_preamble:
        print(f"📜 已載入全域憲法：{CORE_PROTOCOL_FILE}")
    else:
        print(f"⚠️  未找到 {CORE_PROTOCOL_FILE}，將不注入憲法前置內容。")

    if not args.dry_run:
        target_dir.mkdir(parents=True, exist_ok=True)

    print(f"🎯 目標目錄：{target_dir}")
    print(f"🔍 掃描來源：{prompts_dir}/{AGENT_GLOB}")

    written = 0
    skipped = 0
    agent_files = sorted(prompts_dir.glob(AGENT_GLOB))
    for src in agent_files:
        if src.name == CORE_PROTOCOL_FILE:
            continue

        name = derive_name(src.stem)
        content = src.read_text(encoding="utf-8")
        description = extract_description(content, fallback=f"{name} 角色代理")
        output = build_output(core_preamble, content, name, description)
        target = target_dir / f"{name}.md"

        if target.exists() and not args.force and not args.dry_run:
            print(f"⏭️  跳過（已存在，使用 --force 覆寫）：{target.name}")
            skipped += 1
            continue

        if args.dry_run:
            print(f"🔸 [dry-run] {target.name}  ←  {src.name}  ({description[:40]}…)")
        else:
            target.write_text(output, encoding="utf-8")
            print(f"✅ 已寫入：{target.name}")
        written += 1

    print()
    print(f"📊 處理完成：寫入 {written} 檔，跳過 {skipped} 檔，總來源 {len(agent_files)} 檔。")
    if args.dry_run:
        print("ℹ️  這是 dry-run，未實際寫檔。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
