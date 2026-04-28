#!/usr/bin/env python3
"""design_prompt — Augment a cap workflow prompt with design-source metadata.

Two roles:
  1. detect    — given a prompt and CLI flags, decide whether augmentation is
                 needed (skip when prompt already contains a known design URL,
                 when --no-design is set, or when stdin is non-TTY without
                 explicit flags).
  2. augment   — interactively (or via flags) ask the user for a design source,
                 then append the matching ritual block from
                 schemas/design-source-templates.yaml to the prompt.

Only invoked by cap CLI for planning-type workflows
(project-constitution, project-constitution-reconcile). Other workflows skip
this helper entirely.

Exit codes:
  0  success — augmented prompt printed to stdout
  10 skip    — no augmentation needed; original prompt printed to stdout unchanged
  20 cancel  — user aborted at interactive prompt; caller should halt the run
  30 invalid — bad flag combination or missing required field

Usage:
  python design_prompt.py augment \
      --templates schemas/design-source-templates.yaml \
      --workflow-id project-constitution \
      [--design-source TYPE] [--design-url URL] \
      [--design-figma-target NAME] [--design-script PATH] \
      [--no-design] \
      --prompt-stdin
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

import yaml


PLANNING_WORKFLOWS = {
    "project-constitution",
    "project-constitution-reconcile",
}

VALID_SOURCES = {"none", "claude-design", "figma-mcp", "figma-import-script"}


def _load_templates(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def _prompt_already_has_design_url(prompt: str, detection_patterns: dict) -> str | None:
    """Return the matched source key if prompt already mentions a known URL."""
    for source_key, patterns in detection_patterns.items():
        for pattern in patterns:
            if re.search(pattern, prompt):
                return source_key
    return None


def _is_tty_interactive() -> bool:
    return sys.stdin.isatty() and sys.stderr.isatty()


def _ask(question: str) -> str:
    sys.stderr.write(question)
    sys.stderr.flush()
    return sys.stdin.readline().strip()


def _prompt_for_source(sources: dict) -> str:
    sys.stderr.write("\n[cap] 是否有設計稿？\n")
    keys = list(sources.keys())
    keys.sort(key=lambda k: 0 if k == "none" else 1)
    for idx, key in enumerate(keys, start=1):
        label = sources[key].get("interactive_prompt") or sources[key].get("label", key)
        sys.stderr.write(f"  [{idx}] {label}\n")
    while True:
        ans = _ask(f"請選擇 [1-{len(keys)}]（直接 Enter 視為 1）：")
        if ans == "":
            return keys[0]
        if ans.isdigit() and 1 <= int(ans) <= len(keys):
            return keys[int(ans) - 1]
        sys.stderr.write("無效輸入，請重新選擇。\n")


def _collect_required_fields(source: dict, preset: dict[str, str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for required in source.get("requires", []):
        if required == "none":
            continue
        if required in preset and preset[required]:
            fields[required] = preset[required]
            continue
        prompt_label = {
            "url": "請貼上設計檔 URL：",
            "figma_target": "請填寫 figma_target（file_key / project_name / page_name）：",
            "script_path": "請填寫 figma import script 相對路徑：",
        }.get(required, f"請填寫 {required}：")
        while True:
            value = _ask(prompt_label)
            if value:
                fields[required] = value
                break
            sys.stderr.write("不可為空。\n")
    return fields


def _render_block(template: str, fields: dict[str, str]) -> str:
    output = template
    for key, value in fields.items():
        output = output.replace("{" + key + "}", value)
    return output


def _augment(prompt: str, ritual: str) -> str:
    if not ritual.strip():
        return prompt
    if prompt.endswith("\n"):
        return f"{prompt}\n{ritual.strip()}\n"
    return f"{prompt}\n\n{ritual.strip()}\n"


def cmd_augment(args: argparse.Namespace) -> int:
    if args.workflow_id not in PLANNING_WORKFLOWS:
        sys.stdout.write(args.prompt or "")
        return 10

    templates_path = Path(args.templates)
    if not templates_path.is_file():
        print(f"[design_prompt] templates not found: {templates_path}", file=sys.stderr)
        sys.stdout.write(args.prompt or "")
        return 10

    templates = _load_templates(templates_path)
    sources = templates.get("sources") or {}
    detection_patterns = templates.get("detection_patterns") or {}

    prompt = args.prompt or ""

    if args.no_design:
        sys.stdout.write(prompt)
        return 10

    matched = _prompt_already_has_design_url(prompt, detection_patterns)
    if matched:
        sys.stderr.write(
            f"[cap] 偵測到 prompt 已含 {matched} 連結，跳過設計來源詢問。\n"
        )
        sys.stdout.write(prompt)
        return 10

    selected: str | None = args.design_source
    if selected and selected not in VALID_SOURCES:
        print(
            f"[design_prompt] invalid --design-source: {selected}; expected one of {sorted(VALID_SOURCES)}",
            file=sys.stderr,
        )
        return 30

    if selected is None and not _is_tty_interactive():
        sys.stderr.write(
            "[cap] 非互動環境且未指定 --design-source / --no-design；預設無設計稿。\n"
        )
        sys.stdout.write(prompt)
        return 10

    if selected is None:
        try:
            selected = _prompt_for_source(sources)
        except (KeyboardInterrupt, EOFError):
            sys.stderr.write("\n[cap] 使用者中止互動。\n")
            return 20

    if selected not in sources:
        print(
            f"[design_prompt] source not in templates: {selected}",
            file=sys.stderr,
        )
        return 30

    source_def = sources[selected] or {}

    if selected == "none":
        sys.stdout.write(prompt)
        return 10

    preset = {
        "url": args.design_url or "",
        "figma_target": args.design_figma_target or "",
        "script_path": args.design_script or "",
    }

    if not _is_tty_interactive():
        # Non-interactive path: every required field must come from flags;
        # we cannot prompt the user. Halt with a precise error per missing
        # field instead of falling through to readline (which would block
        # forever on a closed pipe).
        for required in source_def.get("requires", []):
            if required == "none":
                continue
            if not preset.get(required):
                print(
                    f"[design_prompt] non-interactive: --design-source={selected} 需要 --design-{required.replace('_', '-')}",
                    file=sys.stderr,
                )
                return 30

    try:
        fields = _collect_required_fields(source_def, preset)
    except (KeyboardInterrupt, EOFError):
        sys.stderr.write("\n[cap] 使用者中止互動。\n")
        return 20

    ritual = _render_block(source_def.get("appended_block", "") or "", fields)
    augmented = _augment(prompt, ritual)
    sys.stdout.write(augmented)
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    """Lightweight sanity check used by tests / smoke."""
    templates_path = Path(args.templates)
    if not templates_path.is_file():
        print(f"missing: {templates_path}", file=sys.stderr)
        return 30
    templates = _load_templates(templates_path)
    sources = templates.get("sources") or {}
    missing = sorted(VALID_SOURCES - set(sources.keys()))
    if missing:
        print(f"sources missing in template: {missing}", file=sys.stderr)
        return 30
    print("OK")
    return 0


def _read_prompt(args: argparse.Namespace) -> str:
    if args.prompt_stdin:
        return sys.stdin.read()
    return args.prompt or ""


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="design_prompt")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("augment", help="Augment prompt with design-source metadata")
    p.add_argument("--templates", required=True)
    p.add_argument("--workflow-id", required=True)
    p.add_argument("--design-source", default=None)
    p.add_argument("--design-url", default=None)
    p.add_argument("--design-figma-target", default=None)
    p.add_argument("--design-script", default=None)
    p.add_argument("--no-design", action="store_true")
    p.add_argument("--prompt", default=None)
    p.add_argument("--prompt-stdin", action="store_true")
    p.set_defaults(func=cmd_augment)

    p2 = sub.add_parser("check", help="Validate template file shape")
    p2.add_argument("--templates", required=True)
    p2.set_defaults(func=cmd_check)

    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()
    if args.cmd == "augment":
        args.prompt = _read_prompt(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
