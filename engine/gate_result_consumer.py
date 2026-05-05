"""gate_result_consumer — P8 #6 Fail-route handling consumer.

The first concrete **consumer** of the gate-result envelope contract
defined by P8 #1 (validate-gate-result) and produced by P8 #2-#5
(watcher / security / qa / logger runners). Translates a single
envelope into a runtime routing decision the caller (cap-workflow-exec
shell wrapper, future Python orchestrator) can act on.

Boundary:

* This module **does not** halt the workflow itself. It computes a
  ``GateConsumeDecision`` and emits a single stdout line; the
  controller (cap-workflow-exec.sh hook, or a future Python
  AgentSessionRunner integration) reads the line and applies the
  decision to its own loop. Keeping the consumer side-effect-free
  (other than optional audit-trail writes) lets the same module
  serve shell, Python, and CrewAI runtimes without refactor.
* The action set is intentionally narrower than the schema enum in
  v1: ``halt`` / ``route_back`` / ``escalate`` are fully supported;
  ``retry`` is parsed but mapped to a ``retry_unsupported`` decision
  with a conservative halt because retry semantics overlap P8 #8
  (rerun failed gate). When P8 #8 lands, this module gains a
  retry-aware codepath without breaking the contract here.
* ``none`` (producer chose not to recommend) maps to
  ``defer_to_workflow_yaml``; the controller is expected to consult
  its own YAML ``on_fail`` block.
* For ``fail`` / ``blocked`` verdicts where ``fail_routing`` is
  absent or malformed, the consumer defaults to **conservative
  halt** with ``needs_supervisor=True``. We never silently lose a
  failure signal because of producer omission.

Decision contract (consumer → controller):

* ``proceed`` — verdict was pass / warn (or none-action with no
  active failure). Controller continues normal step succession.
* ``halt`` — workflow MUST halt. Set by:
    - Explicit ``fail_routing.action=halt``
    - ``retry`` (unsupported in v1) — folded into halt with
      ``notes=["retry_unsupported"]`` for triage
    - Any ``fail`` / ``blocked`` envelope without usable fail_routing
* ``route_back`` — controller reroutes to ``route_back_to_step``.
  Step id is mandatory; if missing despite the producer requesting
  it, the consumer downgrades to halt.
* ``escalate`` — workflow halts AND ``needs_supervisor=True`` so
  the controller surfaces a human-decision marker rather than a
  silent fail.
* ``defer_to_workflow_yaml`` — fall through to workflow YAML
  ``on_fail`` semantics. Controller decides whether to proceed,
  halt, or reroute based on its own configuration. The consumer
  declines to make a decision so YAML stays the SSOT for that case.

Schema validation:

The consumer **always** runs the gate-result envelope through
:func:`gate_runner_common.validate_gate_result_payload` before
deriving a decision. A schema-invalid envelope is treated as a
hard failure (exit 41 in the CLI wrapper); we never act on
malformed governance state.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from . import gate_runner_common as common
except ImportError:  # pragma: no cover — direct-script fallback
    import gate_runner_common as common  # type: ignore[no-redef]


# ─────────────────────────────────────────────────────────
# Decision dataclass
# ─────────────────────────────────────────────────────────


# All decision actions the consumer can emit. ``proceed`` and
# ``defer_to_workflow_yaml`` are non-blocking; everything else is
# either halt-equivalent or routes the workflow elsewhere.
DECISION_ACTIONS = (
    "proceed",
    "halt",
    "route_back",
    "escalate",
    "retry_unsupported",
    "defer_to_workflow_yaml",
)


# P8 #7 halt-on-risk: risk levels that force halt regardless of
# verdict or fail_routing recommendation. ``critical`` is for
# explicit hard-failures (secret leak, IDOR, schema-broken SSOT);
# ``high`` is for findings that the producer flagged as worth
# escalating but where automated routing would be unsafe (e.g.,
# auto route_back of a high-risk security finding could land it
# back into the same pipeline that emitted the leak in the first
# place). Anything below high is allowed to proceed through the
# normal verdict ladder.
HALT_ON_RISK_LEVELS = ("high", "critical")


@dataclass
class GateConsumeDecision:
    """Runtime routing decision derived from one gate-result envelope.

    The caller-controller is expected to:

    * read ``decision`` first; ``proceed`` and
      ``defer_to_workflow_yaml`` are no-ops at this layer.
    * for ``halt`` / ``escalate`` / ``retry_unsupported``: stop
      forward progress, surface ``reason`` plus
      ``needs_supervisor`` to the operator.
    * for ``route_back``: jump to ``route_back_to_step`` (always
      populated when decision is ``route_back``; the consumer
      enforces this invariant by downgrading to halt otherwise).
    * include ``source_gate_id`` / ``source_step_id`` in any audit
      trail so a routing decision can be linked back to the
      gate-result file that produced it.
    """

    decision: str
    result: str
    risk_level: str
    reason: str
    route_back_to_step: str | None
    needs_supervisor: bool
    source_gate_id: str
    source_step_id: str
    source_run_id: str
    source_workflow_id: str
    source_gate_type: str
    notes: list[str] = field(default_factory=list)


# ─────────────────────────────────────────────────────────
# Pure decision logic
# ─────────────────────────────────────────────────────────


def derive_decision(envelope: dict[str, Any]) -> GateConsumeDecision:
    """Translate a validated envelope into a runtime decision.

    Precondition: caller has already run
    :func:`gate_runner_common.validate_gate_result_payload` and
    confirmed an empty error list. Behaviour on a schema-invalid
    envelope is undefined; the CLI wrapper enforces this guard
    before calling derive_decision.

    Decision matrix (in order of evaluation):

      0. **halt-on-risk policy (P8 #7)** — if ``risk_level`` is in
         ``HALT_ON_RISK_LEVELS`` (currently ``high`` / ``critical``),
         halt regardless of result or fail_routing.action.
         ``needs_supervisor=True``. This is the **first** check so a
         critical/high envelope cannot be auto-routed (route_back) or
         auto-escalated (escalate) past supervisor review. Even
         ``pass`` / ``warn`` halts when risk is high+ — a clean run
         that nonetheless flagged residual risk must surface to a
         human before the pipeline keeps moving.
      1. result == 'pass' / 'warn'  → proceed
      2. result == 'fail' / 'blocked' AND fail_routing missing
         → conservative halt (needs_supervisor=True)
      3. fail_routing.action == 'halt'      → halt
      4. fail_routing.action == 'route_back':
          - route_back_to_step present → route_back
          - route_back_to_step missing → halt (conservative downgrade)
      5. fail_routing.action == 'escalate'  → escalate (needs_supervisor=True)
      6. fail_routing.action == 'retry'     → retry_unsupported (halt-equivalent)
      7. fail_routing.action == 'none'      → defer_to_workflow_yaml
      8. unknown action (defensive guard)   → halt + notes
    """
    result = envelope.get("result", "<absent>")
    risk_level = envelope.get("risk_level", "<absent>")
    fail_routing = envelope.get("fail_routing")

    common_fields: dict[str, Any] = {
        "result": result,
        "risk_level": risk_level,
        "source_gate_id": envelope.get("gate_id", "<unknown>"),
        "source_step_id": envelope.get("step_id", "<unknown>"),
        "source_run_id": envelope.get("run_id", "<unknown>"),
        "source_workflow_id": envelope.get("workflow_id", "<unknown>"),
        "source_gate_type": envelope.get("gate_type", "<unknown>"),
    }

    # ── 0. halt-on-risk policy (P8 #7) ────────────────────────────
    # high / critical risk forces halt no matter what verdict or
    # fail_routing recommendation says. This is the LAST line of
    # defense for governance: even a 'pass' verdict that happens to
    # carry a critical risk flag (e.g., the producer aggregated a
    # critical residual without enough findings to fail) cannot
    # proceed without a supervisor signing off. Equally, a fail
    # routed for retry/route_back/none with high+ risk gets halted
    # so high-risk findings cannot self-heal through automation.
    if risk_level in HALT_ON_RISK_LEVELS:
        return _halt_on_risk_decision(
            result=result,
            risk_level=risk_level,
            fail_routing=fail_routing,
            common_fields=common_fields,
        )

    # ── 1. pass / warn → proceed ──────────────────────────────────
    if result in ("pass", "warn"):
        reason = (
            f"verdict={result}; downstream unrestricted by gate result"
        )
        return GateConsumeDecision(
            decision="proceed",
            reason=reason,
            route_back_to_step=None,
            needs_supervisor=False,
            **common_fields,
        )

    # From here on the result is fail / blocked (or unexpected — same
    # treatment, since we never want to silently let an unknown verdict
    # through). Producer is expected to populate fail_routing for these
    # cases; if absent, conservative halt.
    if not isinstance(fail_routing, dict):
        return GateConsumeDecision(
            decision="halt",
            reason=(
                f"verdict={result} but fail_routing absent; conservative "
                "halt — supervisor must inspect missing routing recommendation"
            ),
            route_back_to_step=None,
            needs_supervisor=True,
            notes=["fail_routing_absent"],
            **common_fields,
        )

    action = fail_routing.get("action")
    fr_reason = fail_routing.get("reason") or "(no producer reason)"
    fr_route_back = fail_routing.get("route_back_to_step")

    if action == "halt":
        return GateConsumeDecision(
            decision="halt",
            reason=fr_reason,
            route_back_to_step=None,
            needs_supervisor=False,
            **common_fields,
        )

    if action == "route_back":
        if not fr_route_back:
            return GateConsumeDecision(
                decision="halt",
                reason=(
                    "fail_routing.action=route_back but "
                    "route_back_to_step missing; conservative halt — "
                    "producer must declare a target step"
                ),
                route_back_to_step=None,
                needs_supervisor=True,
                notes=["route_back_target_missing"],
                **common_fields,
            )
        return GateConsumeDecision(
            decision="route_back",
            reason=fr_reason,
            route_back_to_step=fr_route_back,
            needs_supervisor=False,
            **common_fields,
        )

    if action == "escalate":
        return GateConsumeDecision(
            decision="escalate",
            reason=fr_reason,
            route_back_to_step=None,
            needs_supervisor=True,
            **common_fields,
        )

    if action == "retry":
        # P8 #6 v1 explicitly does NOT support retry — the control
        # surface overlaps P8 #8 (rerun failed gate) which has its
        # own CLI / state machine. Map to conservative halt with a
        # well-known note so triage can identify the case.
        return GateConsumeDecision(
            decision="retry_unsupported",
            reason=(
                "fail_routing.action=retry not supported by P8 #6 v1 "
                "(overlaps P8 #8 rerun-failed-gate); halting with "
                "needs_supervisor for explicit rerun decision"
            ),
            route_back_to_step=None,
            needs_supervisor=True,
            notes=["retry_unsupported"],
            **common_fields,
        )

    if action == "none":
        # Producer explicitly declined to recommend; controller falls
        # back to its own workflow YAML on_fail. We do NOT halt here
        # because that would override the YAML SSOT.
        return GateConsumeDecision(
            decision="defer_to_workflow_yaml",
            reason=(
                "fail_routing.action=none — producer declined to "
                "recommend; defer to workflow YAML on_fail"
            ),
            route_back_to_step=None,
            needs_supervisor=False,
            notes=["deferred"],
            **common_fields,
        )

    # Defensive: unknown action despite schema validation (shouldn't
    # happen but we never want governance to silently drop a verdict).
    return GateConsumeDecision(
        decision="halt",
        reason=(
            f"unknown fail_routing.action={action!r}; conservative "
            "halt — supervisor must inspect"
        ),
        route_back_to_step=None,
        needs_supervisor=True,
        notes=[f"unknown_action:{action!r}"],
        **common_fields,
    )


def _halt_on_risk_decision(
    *,
    result: str,
    risk_level: str,
    fail_routing: Any,
    common_fields: dict[str, Any],
) -> GateConsumeDecision:
    """Build a halt decision for the P8 #7 halt-on-risk policy.

    Reason text is constructed to preserve full audit context:

      * State the policy trigger explicitly (``halt_on_risk policy:
        risk_level=<lvl> requires halt regardless of verdict=<v>``)
        so a log reader can immediately spot why the halt fired.
      * If a producer fail_routing was present and recommended a
        non-halt action, surface that the policy **overrode** that
        recommendation; this matters when triaging why a route_back
        / escalate / retry / none recommendation didn't take effect.
      * If the producer recorded its own ``reason`` in fail_routing,
        include it verbatim so the human-readable rationale survives.
      * If the verdict is fail / blocked but fail_routing is absent
        entirely (the conservative-halt edge case from P8 #6 v1),
        include the ``fail_routing absent`` substring so existing
        triage tools that grep for that phrase still find it.

    Notes list captures structured tags:

      * ``halt_on_risk`` — always present; primary tag.
      * ``overrode_action:<action>`` — when policy supplanted a
        producer fail_routing.action other than halt.
      * ``fail_routing_absent`` — when fail/blocked envelope had no
        fail_routing at all.
    """
    parts = [
        f"halt_on_risk policy: risk_level={risk_level} requires halt "
        f"regardless of verdict={result}"
    ]
    notes: list[str] = ["halt_on_risk"]

    if isinstance(fail_routing, dict):
        action = fail_routing.get("action")
        producer_reason = fail_routing.get("reason")
        if action and action != "halt":
            parts.append(f"overrides producer fail_routing.action={action}")
            notes.append(f"overrode_action:{action}")
        if producer_reason:
            parts.append(f"producer note: {producer_reason}")
    elif result in ("fail", "blocked"):
        # No fail_routing despite a non-clean verdict — would have hit
        # the P8 #6 conservative-halt branch anyway, but tag here for
        # consistent audit semantics.
        parts.append("fail_routing absent on fail/blocked verdict")
        notes.append("fail_routing_absent")

    return GateConsumeDecision(
        decision="halt",
        reason="; ".join(parts),
        route_back_to_step=None,
        needs_supervisor=True,
        notes=notes,
        **common_fields,
    )


# ─────────────────────────────────────────────────────────
# Audit-trail writers
# ─────────────────────────────────────────────────────────


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def append_workflow_log(
    log_path: Path,
    decision: GateConsumeDecision,
) -> None:
    """Append a single human-readable line to workflow.log.

    Format mirrors the existing trace style used elsewhere in the
    runtime so an operator skimming the log can spot governance
    decisions without parsing JSON.
    """
    line = (
        f"[{_now_iso()}] gate-decision "
        f"gate={decision.source_gate_id} "
        f"step={decision.source_step_id} "
        f"verdict={decision.result} "
        f"decision={decision.decision} "
        f"needs_supervisor={'true' if decision.needs_supervisor else 'false'} "
        f"reason={decision.reason!r}"
    )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def append_route_history(
    history_path: Path,
    decision: GateConsumeDecision,
    *,
    source_gate_result_path: str,
) -> None:
    """Append one JSON line to route-history.jsonl.

    Each line is a complete decision record; consumers can stream
    the file to reconstruct the routing trail without re-reading
    each gate-result envelope. Schema is intentionally informal in
    v1; if a downstream consumer (P10 promote / publish) needs a
    formal contract, it can be schema-fied later without breaking
    this writer.
    """
    record = {
        "timestamp": _now_iso(),
        "decision": decision.decision,
        "result": decision.result,
        "risk_level": decision.risk_level,
        "reason": decision.reason,
        "route_back_to_step": decision.route_back_to_step,
        "needs_supervisor": decision.needs_supervisor,
        "notes": list(decision.notes),
        "source_gate_id": decision.source_gate_id,
        "source_gate_type": decision.source_gate_type,
        "source_step_id": decision.source_step_id,
        "source_run_id": decision.source_run_id,
        "source_workflow_id": decision.source_workflow_id,
        "source_gate_result_path": source_gate_result_path,
        "consumer_version": 1,
    }
    history_path.parent.mkdir(parents=True, exist_ok=True)
    with history_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


# ─────────────────────────────────────────────────────────
# CLI helper (called by step_runtime.py)
# ─────────────────────────────────────────────────────────


def _format_stdout_line(decision: GateConsumeDecision) -> str:
    """Single-line stdout payload for shell wrappers to grep.

    Format keeps the same ``key=value;key=value`` shape used by
    sibling validators so cap-workflow-exec.sh can parse it without
    JSON tooling. Reason is wrapped in quotes if it contains
    semicolons or whitespace to keep parsing safe.
    """
    reason = decision.reason
    if any(ch in reason for ch in ";\n"):
        reason = reason.replace("\n", " ").replace(";", ",")
    return (
        f"decision={decision.decision};"
        f"result={decision.result};"
        f"risk={decision.risk_level};"
        f"route_back_to_step={decision.route_back_to_step or 'none'};"
        f"needs_supervisor={'true' if decision.needs_supervisor else 'false'};"
        f"source_gate_id={decision.source_gate_id};"
        f"source_step_id={decision.source_step_id};"
        f"reason={reason}"
    )


def consume_gate_result_cli(
    *,
    result_path: str,
    workflow_log_path: str | None,
    route_history_path: str | None,
) -> None:
    """CLI entry point — load + validate + decide + audit + emit.

    Exit code policy:
      * exit 0  — decision emitted (regardless of the decision).
                  Controller reads stdout to learn what to do.
      * exit 41 — schema validation failed
                  (``schema_validation_failed`` per
                  ``policies/workflow-executor-exit-codes.md``).
                  Same code as sibling validators so shell wrappers
                  can treat governance schema fail uniformly.
      * exit 1  — operational error (missing artifact, JSON parse).

    Stdout is **always** the single-line decision payload on
    success; on failure, stdout carries a ``reason=...`` line
    matching the validate-gate-result wrapper convention.
    """
    p = Path(result_path)
    if not p.exists():
        print(f"reason=missing_artifact;detail=gate-result not found: {result_path}")
        sys.exit(1)

    try:
        envelope = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"reason=parse_error;detail=gate-result JSON invalid: {exc}")
        sys.exit(1)
    except OSError as exc:  # pragma: no cover — defensive read guard
        print(f"reason=parse_error;detail=gate-result read failed: {exc}")
        sys.exit(1)

    schema_errors = common.validate_gate_result_payload(envelope)
    if schema_errors:
        joined = " | ".join(schema_errors)
        print(f"reason=gate_result_schema_invalid;detail={joined}")
        sys.exit(41)

    decision = derive_decision(envelope)

    if workflow_log_path:
        try:
            append_workflow_log(Path(workflow_log_path), decision)
        except OSError as exc:
            # Log failure is non-fatal: we still emit the decision so
            # the controller can act. Surface as a stderr-only note so
            # stdout stays the canonical decision channel.
            print(
                f"reason=workflow_log_write_failed;detail={exc}",
                file=sys.stderr,
            )

    if route_history_path:
        try:
            append_route_history(
                Path(route_history_path),
                decision,
                source_gate_result_path=str(p.resolve()),
            )
        except OSError as exc:
            print(
                f"reason=route_history_write_failed;detail={exc}",
                file=sys.stderr,
            )

    print(_format_stdout_line(decision))
    sys.exit(0)
