"""Agent session runner — orchestrates ``ProviderAdapter`` dispatch + session ledger writes.

Programmable Python execution layer additive to the production shell
executor at ``scripts/cap-workflow-exec.sh`` (see P5 baseline memo in
``docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md`` §P5). The shell
executor is the de facto runner for ``cap workflow run``; this module
exists for deterministic tests, future programmable invocation paths,
and as the eventual migration target.

Ledger writes delegate to ``engine.step_runtime.upsert_session`` so
the on-disk shape stays single-sourced (no duplicate schema knowledge).
The runner does NOT introduce new ledger fields; prompt snapshot /
hash, parent / child session relations, and ``cap session inspect``
are scheduled for later P5 batches.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, replace

try:
    from . import step_runtime
    from .provider_adapter import (
        STATUS_CANCELLED,
        STATUS_COMPLETED,
        STATUS_FAILED,
        STATUS_TIMEOUT,
        ProviderAdapter,
        ProviderRequest,
        ProviderResult,
    )
except ImportError:  # pragma: no cover
    import step_runtime  # type: ignore[no-redef]
    from provider_adapter import (  # type: ignore[no-redef]
        STATUS_CANCELLED,
        STATUS_COMPLETED,
        STATUS_FAILED,
        STATUS_TIMEOUT,
        ProviderAdapter,
        ProviderRequest,
        ProviderResult,
    )


# Map ProviderResult.status onto the agent-session.schema.yaml lifecycle enum.
_STATUS_TO_LIFECYCLE = {
    STATUS_COMPLETED: "completed",
    STATUS_FAILED: "failed",
    STATUS_TIMEOUT: "failed",
    STATUS_CANCELLED: "cancelled",
}


@dataclass(frozen=True)
class SessionContext:
    """Workflow context required to write a session ledger entry.

    Mirrors the positional arguments of
    ``step_runtime.upsert_session`` so the runner can pass them
    through without reshaping. Only the fields required for a minimal
    session record are present here; richer fields (prompt snapshot,
    parent_session_id, etc.) are left for later P5 batches.
    """

    sessions_path: str
    run_id: str
    workflow_id: str
    workflow_name: str
    step_id: str
    capability: str
    agent_alias: str
    executor: str
    prompt_file: str = ""
    input_mode: str = ""
    output_path: str = ""
    handoff_path: str = ""


@dataclass(frozen=True)
class RunStepOutcome:
    """Returned to the caller after ``run_step`` completes."""

    session_id: str
    result: ProviderResult
    lifecycle: str
    failure_reason: str | None


class AgentSessionRunner:
    """Programmable session runner that wraps a ``ProviderAdapter`` call.

    Responsibilities:
    1. Generate or accept a ``session_id`` for the call.
    2. Pre-write a ``running`` ledger entry so observers can see a
       session in flight.
    3. Invoke the adapter, catching adapter-internal exceptions as
       failed sessions.
    4. Map ``ProviderResult.status`` to the schema's ``lifecycle``
       enum and write the terminal ledger entry.
    5. Return a structured ``RunStepOutcome`` for the caller.

    The runner is intentionally stateless across calls — each
    ``run_step`` is independent — so the same instance can serve
    concurrent contexts in future scenarios.
    """

    def run_step(
        self,
        adapter: ProviderAdapter,
        request: ProviderRequest,
        context: SessionContext,
    ) -> RunStepOutcome:
        session_id = request.session_id or f"sess_{uuid.uuid4().hex[:12]}"
        if request.session_id != session_id:
            request = replace(request, session_id=session_id)

        self._upsert_lifecycle(
            context, session_id, adapter.name,
            lifecycle="running", result="pending",
            failure_reason="", duration_seconds="",
        )

        try:
            result = adapter.run(request)
        except Exception as exc:
            failure_msg = f"adapter raised {type(exc).__name__}: {exc}"
            self._upsert_lifecycle(
                context, session_id, adapter.name,
                lifecycle="failed", result="failed",
                failure_reason=failure_msg, duration_seconds="",
            )
            synthetic = ProviderResult(
                status=STATUS_FAILED,
                exit_code=-1,
                stdout="",
                stderr=str(exc),
                duration_seconds=0.0,
                failure_reason=failure_msg,
            )
            return RunStepOutcome(
                session_id=session_id,
                result=synthetic,
                lifecycle="failed",
                failure_reason=failure_msg,
            )

        lifecycle = _STATUS_TO_LIFECYCLE.get(result.status, "failed")
        ledger_result = "passed" if lifecycle == "completed" else "failed"
        failure_reason = result.failure_reason or (
            "" if lifecycle == "completed" else result.status
        )

        self._upsert_lifecycle(
            context, session_id, adapter.name,
            lifecycle=lifecycle, result=ledger_result,
            failure_reason=failure_reason or "",
            # step_runtime.upsert_session coerces this via int(); pass an
            # integer-string so sub-second adapter calls round to 0
            # rather than tripping the int() ValueError path that would
            # null the field. Sub-second precision is intentionally
            # discarded — the ledger schema stores integer seconds.
            duration_seconds=str(max(0, int(result.duration_seconds))),
        )

        return RunStepOutcome(
            session_id=session_id,
            result=result,
            lifecycle=lifecycle,
            failure_reason=failure_reason or None,
        )

    @staticmethod
    def _upsert_lifecycle(
        context: SessionContext,
        session_id: str,
        provider_cli: str,
        *,
        lifecycle: str,
        result: str,
        failure_reason: str,
        duration_seconds: str,
    ) -> None:
        step_runtime.upsert_session(
            context.sessions_path,
            context.run_id,
            context.workflow_id,
            context.workflow_name,
            session_id,
            context.step_id,
            context.capability,
            context.agent_alias,
            context.prompt_file,
            provider_cli,
            context.executor,
            lifecycle,
            result,
            context.input_mode,
            context.output_path,
            context.handoff_path,
            failure_reason,
            duration_seconds,
        )
