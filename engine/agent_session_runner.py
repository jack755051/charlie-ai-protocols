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

import hashlib
import json
import uuid
from dataclasses import dataclass, replace
from pathlib import Path

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
    through without reshaping. ``parent_session_id`` and
    ``spawn_reason`` are optional; when ``parent_session_id`` is
    provided the runner derives ``root_session_id`` automatically by
    following the parent's chain through the ledger.
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
    parent_session_id: str | None = None
    spawn_reason: str | None = None


@dataclass(frozen=True)
class PromptSnapshot:
    """Content-addressed prompt snapshot metadata (P5 #6).

    Returned by ``_write_prompt_snapshot`` and forwarded to
    ``upsert_session`` so the ledger gains ``prompt_hash`` /
    ``prompt_snapshot_path`` / ``prompt_size_bytes`` fields. Multiple
    sessions with identical prompt content share the same on-disk file.
    """

    hash: str
    path: str
    size_bytes: int


def _derive_root_session_id(
    sessions_path: str, parent_session_id: str | None, self_session_id: str
) -> str:
    """Derive ``root_session_id`` for a new session (P5 #7).

    Rules:
    * No ``parent_session_id`` → caller is the root; root = self.
    * Has parent → look up the parent in the ledger and inherit
      ``parent.root_session_id`` (or ``parent.session_id`` if the
      parent itself has no recorded root).
    * Parent not found in ledger (missing file, malformed JSON, or
      parent_session_id absent from sessions[]) → conservative fallback:
      root = parent_session_id. This keeps the runner usable against
      legacy ledgers that pre-date the P5 #7 fields rather than hard
      failing on incomplete history.
    """
    if not parent_session_id:
        return self_session_id

    path = Path(sessions_path)
    if not path.exists():
        return parent_session_id

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return parent_session_id

    for entry in data.get("sessions") or []:
        if entry.get("session_id") == parent_session_id:
            return entry.get("root_session_id") or entry.get("session_id") or parent_session_id
    return parent_session_id


def _write_prompt_snapshot(sessions_path: str, prompt: str) -> PromptSnapshot:
    """Write the prompt to a content-addressed file under the sessions dir.

    Path layout: ``<sessions_dir>/prompts/<sha256[:2]>/<sha256>.txt``.
    Idempotent: if the file already exists (because another session had
    the same prompt content) it is left untouched, achieving dedupe.
    """
    encoded = prompt.encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    sessions_dir = Path(sessions_path).parent
    target_dir = sessions_dir / "prompts" / digest[:2]
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{digest}.txt"
    if not target.exists():
        target.write_text(prompt, encoding="utf-8")
    return PromptSnapshot(hash=digest, path=str(target), size_bytes=len(encoded))


@dataclass(frozen=True)
class RunStepOutcome:
    """Returned to the caller after ``run_step`` completes."""

    session_id: str
    result: ProviderResult
    lifecycle: str
    failure_reason: str | None
    prompt_snapshot: PromptSnapshot | None = None


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

        snapshot = _write_prompt_snapshot(context.sessions_path, request.prompt)
        root_session_id = _derive_root_session_id(
            context.sessions_path, context.parent_session_id, session_id
        )

        self._upsert_lifecycle(
            context, session_id, adapter.name,
            lifecycle="running", result="pending",
            failure_reason="", duration_seconds="",
            snapshot=snapshot,
            parent_session_id=context.parent_session_id,
            root_session_id=root_session_id,
            spawn_reason=context.spawn_reason,
        )

        try:
            result = adapter.run(request)
        except Exception as exc:
            failure_msg = f"adapter raised {type(exc).__name__}: {exc}"
            self._upsert_lifecycle(
                context, session_id, adapter.name,
                lifecycle="failed", result="failed",
                failure_reason=failure_msg, duration_seconds="",
                snapshot=snapshot,
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
                prompt_snapshot=snapshot,
            )

        lifecycle = _STATUS_TO_LIFECYCLE.get(result.status, "failed")
        ledger_result = "passed" if lifecycle == "completed" else "failed"
        failure_reason = result.failure_reason or (
            "" if lifecycle == "completed" else result.status
        )
        # P5 #9: ensure timeout outcomes are always recorded with a
        # "timeout:" prefix even when the adapter forgot to set one,
        # so log / CLI consumers can pattern-match on the prefix
        # rather than re-inspecting result.status.
        if result.status == STATUS_TIMEOUT and not failure_reason.startswith("timeout:"):
            failure_reason = f"timeout: {failure_reason}" if failure_reason else "timeout: provider exceeded request.timeout_seconds"

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
            snapshot=snapshot,
            parent_session_id=context.parent_session_id,
            root_session_id=root_session_id,
            spawn_reason=context.spawn_reason,
        )

        return RunStepOutcome(
            session_id=session_id,
            result=result,
            lifecycle=lifecycle,
            failure_reason=failure_reason or None,
            prompt_snapshot=snapshot,
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
        snapshot: PromptSnapshot | None = None,
        parent_session_id: str | None = None,
        root_session_id: str | None = None,
        spawn_reason: str | None = None,
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
            prompt_hash=snapshot.hash if snapshot else None,
            prompt_snapshot_path=snapshot.path if snapshot else None,
            prompt_size_bytes=snapshot.size_bytes if snapshot else None,
            parent_session_id=parent_session_id,
            root_session_id=root_session_id,
            spawn_reason=spawn_reason,
            # P5 #8: runner is the opt-in caller for lifecycle enforcement.
            # Shell executor still calls upsert_session without this flag
            # so its existing transitions stay accepted as-is.
            enforce_transition=True,
        )
