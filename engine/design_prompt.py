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
      [--design-source TYPE] [--design-url URL] [--design-path PATH] \
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

VALID_SOURCES = {"none", "local-design", "claude-design", "figma-mcp", "figma-import-script"}
DEFAULT_DESIGNS_DIR = "~/.cap/designs"


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


_TTY_HANDLE: object | None = None


def _open_tty():
    """Open /dev/tty for interactive read+write, cached for the process.

    We can't rely on sys.stdin / sys.stderr because cap-workflow.sh feeds
    the prompt via a shell pipeline, which leaves sys.stdin pointing at a
    closed pipe even when the user is sitting in front of a real terminal.
    Returns (read_handle, write_handle) or (None, None) if /dev/tty is not
    available (CI / detached sessions).
    """
    global _TTY_HANDLE
    if _TTY_HANDLE is False:
        return None, None
    if _TTY_HANDLE is not None:
        return _TTY_HANDLE  # type: ignore[return-value]
    try:
        read_h = open("/dev/tty", "r", encoding="utf-8")
        write_h = open("/dev/tty", "w", encoding="utf-8")
        _TTY_HANDLE = (read_h, write_h)
        return _TTY_HANDLE
    except OSError:
        _TTY_HANDLE = False  # type: ignore[assignment]
        return None, None


def _is_tty_interactive() -> bool:
    """True when we have any usable TTY (sys streams or /dev/tty fallback)."""
    if sys.stdin.isatty() and sys.stderr.isatty():
        return True
    read_h, write_h = _open_tty()
    return read_h is not None and write_h is not None


def _ask(question: str) -> str:
    """Prompt and read one line, preferring /dev/tty when sys streams are pipes."""
    read_h, write_h = _open_tty()
    if read_h is not None and write_h is not None:
        write_h.write(question)
        write_h.flush()
        line = read_h.readline()
        return line.strip()
    sys.stderr.write(question)
    sys.stderr.flush()
    return sys.stdin.readline().strip()


def _notify(message: str) -> None:
    """Write an informational message to whichever handle the user can see."""
    _, write_h = _open_tty()
    if write_h is not None:
        write_h.write(message)
        write_h.flush()
        return
    sys.stderr.write(message)
    sys.stderr.flush()


def _prompt_for_source(sources: dict) -> str:
    _notify("\n[cap] 是否有設計稿？\n")
    keys = list(sources.keys())
    keys.sort(key=lambda k: 0 if k == "none" else 1)
    for idx, key in enumerate(keys, start=1):
        label = sources[key].get("interactive_prompt") or sources[key].get("label", key)
        _notify(f"  [{idx}] {label}\n")
    while True:
        ans = _ask(f"請選擇 [1-{len(keys)}]（直接 Enter 視為 1）：")
        if ans == "":
            return keys[0]
        if ans.isdigit() and 1 <= int(ans) <= len(keys):
            return keys[int(ans) - 1]
        _notify("無效輸入，請重新選擇。\n")


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
            "design_path": "請填寫本地設計稿 package 目錄（直接 Enter 使用 ~/.cap/designs）：",
            "figma_target": "請填寫 figma_target（file_key / project_name / page_name）：",
            "script_path": "請填寫 figma import script 相對路徑：",
        }.get(required, f"請填寫 {required}：")
        while True:
            value = _ask(prompt_label)
            if required == "design_path" and value == "":
                value = "~/.cap/designs"
            if value:
                fields[required] = value
                break
            _notify("不可為空。\n")
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


def _resolve_design_path(raw_path: str | None) -> Path:
    path = Path(raw_path or DEFAULT_DESIGNS_DIR).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return path.resolve()


def _visible_children(path: Path) -> list[Path]:
    try:
        return sorted(
            [child for child in path.iterdir() if not child.name.startswith(".")],
            key=lambda p: p.name.lower(),
        )
    except OSError:
        return []


def _resolve_default_design_package() -> Path | None:
    designs_dir = _resolve_design_path(DEFAULT_DESIGNS_DIR)
    if not designs_dir.is_dir():
        return None
    children = _visible_children(designs_dir)
    package_dirs = [child for child in children if child.is_dir()]
    loose_files = [child for child in children if child.is_file()]
    if len(package_dirs) == 1 and not loose_files:
        return package_dirs[0]
    if len(package_dirs) == 0 and loose_files:
        return designs_dir
    return None


def _is_designs_library(path: Path) -> bool:
    return path == _resolve_design_path(DEFAULT_DESIGNS_DIR)


def _format_design_tree(root: Path, max_depth: int = 3) -> str:
    if not root.exists():
        return f"{root} (missing)"
    if not root.is_dir():
        return str(root)

    lines = [f"{root.name}/"]
    entries: list[tuple[Path, int]] = []
    for path in sorted(root.rglob("*"), key=lambda p: str(p).lower()):
        rel = path.relative_to(root)
        depth = len(rel.parts)
        if depth > max_depth:
            continue
        entries.append((path, depth))

    for path, depth in entries:
        indent = "  " * depth
        suffix = "/" if path.is_dir() else ""
        lines.append(f"{indent}{path.name}{suffix}")
    return "\n".join(lines)


def _display_design_path(path: Path) -> str:
    home = Path.home().resolve()
    try:
        return "~/" + str(path.resolve().relative_to(home))
    except ValueError:
        try:
            return os.path.relpath(path, Path.cwd())
        except ValueError:
            return str(path)


def _local_design_exists(raw_path: str | None = None) -> bool:
    path = _resolve_design_path(raw_path) if raw_path else (_resolve_default_design_package() or _resolve_design_path(raw_path))
    try:
        return path.is_dir() and any(path.iterdir())
    except OSError:
        return False


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

    auto_design_package = _resolve_default_design_package() if not args.design_path else None

    if selected is None and (args.design_path and _local_design_exists(args.design_path) or auto_design_package is not None):
        selected = "local-design"

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

    default_design_path = ""
    if selected == "local-design":
        if args.design_path and _local_design_exists(args.design_path):
            default_design_path = args.design_path
        elif auto_design_package is not None:
            default_design_path = str(auto_design_package)

    preset = {
        "url": args.design_url or "",
        "design_path": default_design_path,
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

    if selected == "local-design":
        design_path = _resolve_design_path(fields.get("design_path"))
        if _is_designs_library(design_path):
            children = _visible_children(design_path)
            package_dirs = [child for child in children if child.is_dir()]
            if len(package_dirs) > 1:
                names = ", ".join(child.name for child in package_dirs)
                print(
                    "[design_prompt] ~/.cap/designs contains multiple design packages; "
                    f"specify one with --design-path ~/.cap/designs/<name>. Available: {names}",
                    file=sys.stderr,
                )
                return 30
            if len(package_dirs) == 1:
                design_path = package_dirs[0]
        if not design_path.is_dir():
            print(
                f"[design_prompt] local design path not found or not a directory: {design_path}",
                file=sys.stderr,
            )
            return 30
        if not _local_design_exists(str(design_path)):
            print(
                f"[design_prompt] local design path is empty: {design_path}",
                file=sys.stderr,
            )
            return 30
        fields["design_path"] = _display_design_path(design_path)
        fields["design_tree"] = _format_design_tree(design_path)

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
    p.add_argument("--design-path", default=None)
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
