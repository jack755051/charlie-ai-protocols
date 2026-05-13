"""AI step result parser (v0.26.0).

Reads an AI sub-agent step's captured stdout (markdown) and extracts the
``result:`` line from its handoff summary, returning a normalized state
enum the workflow runtime can branch on.

Authoritative spec: ``docs/cap/AI-STEP-RESULT-CONTRACT.md``.

Why this module exists: bug #12 from the 2026-05-10 component-repo
dogfood — pre-v0.26.0, ``cap-workflow-exec.sh`` treated non-empty stdout
as step success. AI agents detected runtime constraints (read-only
filesystem, missing inputs, schema fence violations), self-reported
``blocked_*`` / ``FAIL_BLOCKED_*`` / ``needs_data`` in their markdown
body, but the runtime never parsed those reports and rolled the run up
to ``final_state=completed``. The parser closes that gap.

Invariants:

* **Read-only**: never modifies the input file; never writes anywhere.
* **Last occurrence wins**: agents may mention ``result:`` in upstream
  reasoning tables earlier in the file; only the final handoff-summary
  occurrence is authoritative.
* **Outside-fence first**: ``result:`` lines inside JSON / generic
  fenced code blocks are skipped — the constitution / task constitution
  fences legitimately carry result-shaped fields. As a compatibility
  fallback, the parser accepts ``result:`` inside a final YAML handoff
  block only when it appears after a handoff-summary heading and no
  outside-fence result line exists.
* **Unknown is failed**: any value that does not match the declared
  alias table (case-insensitive, substring-tolerant for the
  ``blocked_*`` family) normalizes to ``unknown``, which the workflow
  treats as failed.
"""
from __future__ import annotations

import re
from pathlib import Path

# Normalized state enum. Anything outside this set is a parser bug.
STATE_SUCCESS = "success"
STATE_FAILED = "failed"
STATE_BLOCKED = "blocked"
STATE_NEEDS_DATA = "needs_data"
STATE_UNKNOWN = "unknown"

_VALID_STATES = frozenset(
    {STATE_SUCCESS, STATE_FAILED, STATE_BLOCKED, STATE_NEEDS_DATA, STATE_UNKNOWN}
)

# Strict alias maps (case-insensitive). Values are matched after lower-casing
# the raw AI output, so registrants here use lowercase too.
_SUCCESS_ALIASES = frozenset({
    "success", "ok", "成功", "completed", "done", "pass", "passed",
})
_FAILED_ALIASES = frozenset({
    "failed", "failure", "fail", "error",
})
_NEEDS_DATA_ALIASES = frozenset({
    "needs_data", "needs-data", "requires_data", "incomplete", "missing_inputs",
})
# Blocked is permissive — the spec calls out substring-tolerance for
# ``blocked_*``, ``FAIL_BLOCKED*``, ``[BLOCK]``, and ``read_only`` /
# ``read-only`` because dogfood AI runs emitted long compound forms like
# ``FAIL_BLOCKED_READ_ONLY_UPSTREAM_IMPLEMENTATION_MISSING``.
#
# Note on cleaning order: ``normalize_value`` strips outer brackets
# before matching, so ``[BLOCK]`` → ``block``. Both ``block`` and
# ``blocked`` are exact matches; the prefix list covers compound
# forms.
_BLOCKED_PREFIXES = ("blocked_", "blocked-", "fail_blocked", "blocked", "[block]")
_BLOCKED_SUBSTRINGS = ("read_only", "read-only", "readonly")
_BLOCKED_EXACT = frozenset({"blocked", "block"})

# Regex matching a result line. The alternation in the colon class
# covers ASCII (:), CJK fullwidth (：), and any leading bullet / spacing.
# Group 1 is the raw value. Trailing text after the value (a comment,
# parenthetical) is consumed but ignored.
_RESULT_LINE = re.compile(
    r"""^
    \s*                                         # leading whitespace
    (?:[-*]\s+)?                                # optional bullet
    \s*\**\s*                                   # optional bold markers
    result                                      # literal keyword
    \s*\**\s*                                   # optional bold close markers
    \s*[:：]\s*                                 # ASCII or CJK colon
    \*?\*?                                      # optional bold start
    `?                                          # optional backtick
    (?P<value>[^\s`,]+)                         # the value (no whitespace / backtick / comma)
    """,
    re.VERBOSE | re.IGNORECASE,
)

# Fence-bound regions where ``result:`` lines should NOT be picked up
# (constitution JSON fences, generic ```...``` code blocks).
_FENCE_OPEN = re.compile(
    r"^(?:<<<[A-Z_]+_BEGIN>>>|```[a-zA-Z0-9_-]*)\s*$"
)
_FENCE_CLOSE = re.compile(
    r"^(?:<<<[A-Z_]+_END>>>|```)\s*$"
)
_MARKDOWN_CODE_FENCE_OPEN = re.compile(r"^```(?P<lang>[a-zA-Z0-9_-]*)\s*$")
_HANDOFF_HEADING = re.compile(
    r"^\s*#{1,6}\s+.*(?:交接摘要|handoff(?:\s+summary)?)",
    re.IGNORECASE,
)


def normalize_value(raw: str) -> str:
    """Map an AI-emitted ``result:`` value to a normalized state.

    Returns one of ``STATE_SUCCESS`` / ``STATE_FAILED`` / ``STATE_BLOCKED``
    / ``STATE_NEEDS_DATA`` / ``STATE_UNKNOWN``.
    """
    cleaned = raw.strip().strip("`").strip("'\"").strip("[]").lower()
    # Some agents wrap the value in markdown emphasis (`**success**`).
    cleaned = cleaned.strip("*")

    if cleaned in _SUCCESS_ALIASES:
        return STATE_SUCCESS
    if cleaned in _FAILED_ALIASES:
        return STATE_FAILED
    if cleaned in _NEEDS_DATA_ALIASES:
        return STATE_NEEDS_DATA

    # Blocked family — permissive by spec.
    if cleaned in _BLOCKED_EXACT:
        return STATE_BLOCKED
    for prefix in _BLOCKED_PREFIXES:
        if cleaned.startswith(prefix):
            return STATE_BLOCKED
    for sub in _BLOCKED_SUBSTRINGS:
        if sub in cleaned:
            return STATE_BLOCKED

    return STATE_UNKNOWN


def parse_step_result(file_path: str | Path) -> dict:
    """Parse a step output file and return the normalized result info.

    Returns a dict with keys:

    * ``state`` — one of the five normalized values.
    * ``raw_value`` — the original value as captured from the markdown
      (empty string when no ``result:`` line was found).
    * ``line_number`` — 1-based line number of the authoritative
      ``result:`` line (0 when absent).
    * ``reason`` — short human-readable explanation of how the state
      was decided; for ``unknown`` includes the raw_value to help the
      operator see what the AI emitted.

    Read-only — never writes the file.
    """
    path = Path(file_path)
    if not path.is_file():
        return {
            "state": STATE_UNKNOWN,
            "raw_value": "",
            "line_number": 0,
            "reason": f"step output file not found: {path}",
        }

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {
            "state": STATE_UNKNOWN,
            "raw_value": "",
            "line_number": 0,
            "reason": f"could not read step output file: {exc.__class__.__name__}",
        }

    # Walk lines tracking fence depth so result: inside JSON / generic
    # code fences is skipped. Last match outside fences wins. A narrowly
    # scoped compatibility path captures result: from YAML handoff
    # fences after a "handoff summary" heading, because dogfood showed
    # Claude/Codex often format the entire Type D handoff as fenced YAML.
    fence_depth = 0
    fence_lang = ""
    seen_handoff_heading = False
    last_match: tuple[int, str] | None = None  # (line_number, raw_value)
    last_handoff_yaml_match: tuple[int, str] | None = None

    for idx, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if fence_depth > 0:
            if (
                seen_handoff_heading
                and fence_depth == 1
                and fence_lang in {"yaml", "yml"}
            ):
                m = _RESULT_LINE.match(line)
                if m:
                    last_handoff_yaml_match = (idx, m.group("value"))
            if _FENCE_CLOSE.match(stripped):
                fence_depth -= 1
                if fence_depth == 0:
                    fence_lang = ""
            continue
        code_fence = _MARKDOWN_CODE_FENCE_OPEN.match(stripped)
        if code_fence:
            fence_depth += 1
            fence_lang = code_fence.group("lang").lower()
            continue
        if _FENCE_OPEN.match(stripped):
            fence_depth += 1
            fence_lang = ""
            continue
        if _HANDOFF_HEADING.match(line):
            seen_handoff_heading = True

        m = _RESULT_LINE.match(line)
        if m:
            last_match = (idx, m.group("value"))

    if last_match is None:
        if last_handoff_yaml_match is None:
            return {
                "state": STATE_UNKNOWN,
                "raw_value": "",
                "line_number": 0,
                "reason": "no result: line found outside JSON / code fences",
            }
        last_match = last_handoff_yaml_match
        match_source = "fenced YAML handoff block"
    else:
        match_source = "outside code fences"

    line_number, raw = last_match
    state = normalize_value(raw)
    if state == STATE_UNKNOWN:
        reason = (
            f"result value '{raw}' (line {line_number}) does not match any "
            "alias in docs/cap/AI-STEP-RESULT-CONTRACT.md; treating as failed"
        )
    else:
        reason = (
            f"normalized from raw value '{raw}' on line {line_number} "
            f"({match_source})"
        )

    return {
        "state": state,
        "raw_value": raw,
        "line_number": line_number,
        "reason": reason,
    }
