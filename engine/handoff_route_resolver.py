"""handoff_route_resolver — P6 #8 ticket-level failure routing resolver.

This module decides *what the runtime should do when a step fails* by
reading the failed step's Type C handoff ticket (per
``schemas/handoff-ticket.schema.yaml`` ``failure_routing`` block).

It is intentionally separate from
``engine.supervisor_envelope.resolve_failure_routing`` — that resolver
operates on the supervisor *envelope* (capability_graph.nodes), while
this one operates on a single *ticket*. The runtime consumes the
per-ticket version because each step's ticket already encodes the
routing decision the supervisor wanted at dispatch time.

Scope (per P6 #8 selection): only ``halt`` and ``route_back_to`` are
honoured. ``retry`` and ``escalate_user`` are explicitly downgraded to
``halt_unsupported`` to keep the control-flow surface minimal; they
will be addressed in a follow-up ticket.

Public API:
    * :func:`resolve_handoff_routing` — pure function callers can
      embed in tests / dry-runs.
    * :func:`resolve_handoff_routing_cli` — argparse-friendly entry
      used by ``engine/step_runtime.py`` ``resolve-handoff-routing``
      subcommand.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_MAX_RETRIES = 1


@dataclass(frozen=True)
class RoutingDecision:
    """Resolver verdict consumed by cap-workflow-exec.sh.

    ``action`` is the only field the shell wrapper needs to branch on:
    ``halt`` keeps the existing behaviour, ``route_back_to`` instructs
    the runtime to jump back to ``target_step``. Other fields exist for
    auditability (logged into ``runtime-state.route_history[]`` and
    ``workflow.log``).
    """

    action: str  # "halt" | "route_back_to"
    reason: str  # short verdict tag, see RESOLVER_REASONS below
    target_step: str | None = None
    remaining_retries: int | None = None
    max_retries: int | None = None


# Verdict tags surfaced to callers / logs. Stable strings so shell
# wrappers can pattern-match without re-parsing.
RESOLVER_REASONS: tuple[str, ...] = (
    "no_routing",            # no failure_routing or on_fail == "halt"
    "unsupported_action",    # on_fail == "retry" / "escalate_user"
    "missing_target",        # on_fail == "route_back_to" but no route_back_to_step
    "invalid_target",        # target not in plan_step_ids
    "max_retries_exhausted", # visit_counts[target] >= max_retries
    "ok",                    # action == route_back_to, target valid
)


def _coerce_int(value: Any, default: int) -> int:
    """Permissive integer coercion for ticket-supplied numbers.

    Accept either bare ints (the schema declares ``type: integer``) or
    numeric strings (manual edits / fixture drift). Falls back to
    ``default`` on any other shape so the resolver never crashes on
    malformed tickets — schema validation is the gate's job (P6 #3),
    not ours.
    """
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return default
    return default


def resolve_handoff_routing(
    ticket: dict[str, Any],
    plan_step_ids: list[str],
    visit_counts: dict[str, int] | None = None,
    max_retries_default: int = DEFAULT_MAX_RETRIES,
) -> RoutingDecision:
    """Decide the failure-handling action for a single failed step.

    Args:
        ticket: Parsed Type C ticket JSON (the ``failure_routing``
            block is the only part this resolver reads).
        plan_step_ids: Flattened list of step ids in the active
            workflow plan, used to validate ``route_back_to_step``.
        visit_counts: Per-step visit counter for the current run.
            Each key is a step_id; value is how many times the runtime
            has *already entered* that step. Pass ``None`` for the
            first failure (treated as empty dict).
        max_retries_default: Fallback bound when the ticket does not
            declare ``failure_routing.max_retries``.

    Returns:
        A :class:`RoutingDecision` whose ``action`` is either
        ``"halt"`` or ``"route_back_to"``. Halt verdicts include a
        diagnostic ``reason`` so the runtime can surface why the
        route_back was rejected (handy in audit trails).

    Notes:
        * Pure function — no I/O, no side-effects on ``visit_counts``.
        * Caller is responsible for incrementing ``visit_counts`` after
          a successful jump (this resolver is consulted *before* the
          jump, so the count it reads is the count for the failed run).
    """
    visits = visit_counts or {}
    routing = ticket.get("failure_routing")
    if not isinstance(routing, dict):
        return RoutingDecision(action="halt", reason="no_routing")

    on_fail = routing.get("on_fail")
    if on_fail in (None, "halt"):
        return RoutingDecision(action="halt", reason="no_routing")

    if on_fail in ("retry", "escalate_user"):
        # P6 #8 selection: only halt + route_back_to are wired through.
        # retry / escalate_user fall through to halt with a distinct
        # reason so audit logs distinguish "ticket asked for retry but
        # runtime does not honour it yet" from "ticket said halt".
        return RoutingDecision(action="halt", reason="unsupported_action")

    if on_fail != "route_back_to":
        # Defensive: schema validation (P6 #3) should already enforce
        # the enum, but treat unknown values as halt rather than
        # raising — the resolver is happy-path-only per P6 baseline.
        return RoutingDecision(action="halt", reason="unsupported_action")

    target = routing.get("route_back_to_step")
    if not isinstance(target, str) or not target:
        return RoutingDecision(action="halt", reason="missing_target")

    if target not in plan_step_ids:
        return RoutingDecision(action="halt", reason="invalid_target")

    max_retries = _coerce_int(routing.get("max_retries"), max_retries_default)
    if max_retries < 0:
        max_retries = max_retries_default
    visited = _coerce_int(visits.get(target), 0)
    if visited >= max_retries:
        return RoutingDecision(
            action="halt",
            reason="max_retries_exhausted",
            target_step=target,
            remaining_retries=0,
            max_retries=max_retries,
        )

    return RoutingDecision(
        action="route_back_to",
        reason="ok",
        target_step=target,
        remaining_retries=max(0, max_retries - visited - 1),
        max_retries=max_retries,
    )


def _parse_visits(raw: str | None) -> dict[str, int]:
    """Parse ``--visits step1=2,step2=0`` into a dict.

    Empty / missing input yields an empty dict (no visits yet).
    Malformed entries are silently skipped — the CLI is consumed by a
    shell wrapper that already gates input shape; we choose tolerance
    over crashes so a stray comma does not nuke a real failure path.
    """
    if not raw:
        return {}
    out: dict[str, int] = {}
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        key, _, value = chunk.partition("=")
        key = key.strip()
        if not key:
            continue
        try:
            out[key] = int(value.strip())
        except ValueError:
            continue
    return out


def _format_decision_line(decision: RoutingDecision) -> str:
    """Render the single-line stdout contract used by cap-workflow-exec.sh.

    Format: ``action=<a>;target=<t>;reason=<r>;remaining=<n>``.
    ``target`` and ``remaining`` are emitted as empty strings when
    absent so the shell parser sees a stable column count.
    """
    target = decision.target_step or ""
    remaining = (
        str(decision.remaining_retries)
        if decision.remaining_retries is not None
        else ""
    )
    return (
        f"action={decision.action};target={target};"
        f"reason={decision.reason};remaining={remaining}"
    )


def resolve_handoff_routing_cli(
    ticket_path: str,
    plan_steps: str,
    visits: str | None,
    max_retries: int,
) -> None:
    """CLI entry — load ticket, resolve, print one line, exit.

    Exit code policy:
      * exit 0 — a decision was made (halt OR route_back_to). Halt is
                 a valid verdict, not an error.
      * exit 1 — operational failure: ticket missing, JSON parse
                 error. Mirrors P6 #3 / #4 missing_artifact semantics.
    """
    p = Path(ticket_path)
    if not p.exists():
        print(
            f"action=halt;target=;reason=missing_artifact;detail=ticket not found: {ticket_path}"
        )
        sys.exit(1)
    try:
        ticket = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"action=halt;target=;reason=parse_error;detail=ticket JSON invalid: {exc}")
        sys.exit(1)
    except OSError as exc:  # pragma: no cover — defensive read guard
        print(f"action=halt;target=;reason=parse_error;detail=ticket read failed: {exc}")
        sys.exit(1)

    plan_ids = [s.strip() for s in plan_steps.split(",") if s.strip()]
    visit_counts = _parse_visits(visits)
    decision = resolve_handoff_routing(
        ticket,
        plan_ids,
        visit_counts=visit_counts,
        max_retries_default=max_retries,
    )
    print(_format_decision_line(decision))
    sys.exit(0)
