"""ProviderAdapter contract + baseline adapters.

Programmable Python execution layer additive to the production shell
executor at ``scripts/cap-workflow-exec.sh`` (see P5 baseline memo in
``docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md`` §P5). Production step
execution stays in shell; these adapters are for deterministic tests,
future programmatic invocation paths, and as the migration target for
later batches.

Scope (this module, P5 #1 + #3):

* ``ProviderRequest`` / ``ProviderResult`` immutable dataclasses define
  the call shape.
* ``ProviderAdapter`` abstract base.
* ``FakeAdapter`` for deterministic tests (no subprocess).
* ``ShellAdapter`` for ``subprocess.run`` wrapping; mirrors
  ``scripts/cap-workflow-exec.sh:run_shell_step``'s shape.

Out of scope here: Codex / Claude adapters (P5 later batches), prompt
snapshot / hash, parent / child session relation, ``cap session
inspect`` CLI. Production execution path is intentionally left alone.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Callable

STATUS_COMPLETED = "completed"
STATUS_FAILED = "failed"
STATUS_TIMEOUT = "timeout"
STATUS_CANCELLED = "cancelled"

PROVIDER_STATUS_VALUES = (
    STATUS_COMPLETED,
    STATUS_FAILED,
    STATUS_TIMEOUT,
    STATUS_CANCELLED,
)


@dataclass(frozen=True)
class ProviderRequest:
    """Input to a single ``ProviderAdapter.run()`` call.

    ``session_id`` and ``step_id`` are required so the adapter and any
    downstream tracing can attribute the call back to the workflow
    context. ``prompt`` is the rendered prompt text (not a file path).
    ``timeout_seconds`` is consumed by adapters that wrap a subprocess;
    adapters without a notion of timeout (e.g. ``FakeAdapter``) ignore
    it. ``env`` is merged onto ``os.environ`` when present so callers
    can override specific vars without losing the shell environment.
    """

    session_id: str
    step_id: str
    prompt: str
    timeout_seconds: float | None = None
    env: dict[str, str] | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ProviderResult:
    """Output of a single ``ProviderAdapter.run()`` call.

    ``status`` is one of ``PROVIDER_STATUS_VALUES`` and is the
    deterministic terminal state callers should branch on. ``exit_code``
    reflects the underlying process when applicable (``-1`` for
    timeout / adapter-internal failures). ``provider_session_id`` is
    reserved for adapters that wrap a provider with a native session
    id; it stays ``None`` for adapters that have no such concept
    (``FakeAdapter``, ``ShellAdapter``).
    """

    status: str
    exit_code: int
    stdout: str
    stderr: str
    duration_seconds: float
    provider_session_id: str | None = None
    artifacts: list[dict] = field(default_factory=list)
    failure_reason: str | None = None


class ProviderAdapter(ABC):
    """Abstract contract for any provider that runs a step's prompt."""

    name: str = "abstract"

    @abstractmethod
    def run(self, request: ProviderRequest) -> ProviderResult:
        """Execute the request and return a ``ProviderResult``.

        Implementations must NOT raise on operational failure (non-zero
        exit, timeout, etc.); they should return a ``ProviderResult``
        with the matching status. They MAY raise on programming errors
        (e.g. invalid request shape); ``AgentSessionRunner`` catches
        those and records a failed session.
        """


class FakeAdapter(ProviderAdapter):
    """Deterministic test adapter.

    Initialize with either a fixed ``ProviderResult`` or a callable
    ``(ProviderRequest) -> ProviderResult`` for per-request branching.
    Useful for asserting runner / ledger behavior without spawning any
    subprocess.
    """

    name = "fake"

    def __init__(
        self,
        result: ProviderResult | Callable[[ProviderRequest], ProviderResult],
    ) -> None:
        self._result = result

    def run(self, request: ProviderRequest) -> ProviderResult:
        if callable(self._result):
            return self._result(request)
        return self._result


def _resolve_provider_binary(name: str, env_var: str) -> str | None:
    """Resolve a provider CLI binary path.

    Precedence: explicit env override (used by tests to point at a fake
    binary), then PATH lookup. Returns None when neither resolves so
    the caller can record a deterministic ``failed`` ProviderResult
    rather than letting subprocess raise FileNotFoundError on launch.
    """
    override = os.environ.get(env_var)
    if override:
        return override
    return shutil.which(name)


def _strip_codex_preamble(raw: str) -> str:
    """Strip Codex CLI banner / transcript and keep only the last assistant block.

    Mirrors the awk logic in
    ``scripts/cap-workflow-exec.sh:strip_codex_preamble`` line-for-line:
    on each ``assistant`` or ``codex`` marker line the buffer resets so
    only the final response block is retained, and the stripped result
    drops the marker itself. Returns ``""`` when no marker is found so
    the caller can fall back to the raw output (mirrors the shell's
    ``|| printf '%s\\n' "${raw}"`` fallback).
    """
    lines = raw.splitlines(keepends=True)
    found = False
    buf: list[str] = []
    for line in lines:
        stripped = line.rstrip("\n")
        if stripped in ("assistant", "codex"):
            found = True
            buf = []
            continue
        if found:
            buf.append(line)
    if not found:
        return ""
    return "".join(buf)


class CodexAdapter(ProviderAdapter):
    """Codex CLI provider adapter (P5 #3).

    Mirrors ``scripts/cap-workflow-exec.sh:run_step_codex`` semantics:
    invokes ``codex exec [--skip-git-repo-check] <prompt>`` and applies
    the same preamble strip so callers receive the cleaned assistant
    response on stdout. stderr is captured separately (the shell version
    merges stdout+stderr via ``2>&1``; the Python contract keeps them
    apart so consumers can inspect each stream).

    Binary resolution: ``CAP_CODEX_BIN`` env override first (used by
    tests to point at a fake binary), then PATH lookup. Missing binary
    surfaces as ``ProviderResult(status=failed, exit_code=-1)`` with a
    deterministic ``failure_reason`` rather than raising
    FileNotFoundError, so the runner records a clean failed session.

    Timeout / non-zero exit / completion all follow the established
    ``ShellAdapter`` shape — ``status=timeout, exit_code=-1`` on
    ``subprocess.TimeoutExpired`` (with the ``timeout:`` failure_reason
    prefix per P5 #9), ``status=failed`` on non-zero, ``status=completed``
    on exit 0.

    Production execution remains in shell (see P5 baseline §1); this
    adapter is for deterministic tests with a fake codex binary, future
    programmatic invocation paths, and as the eventual migration target.
    """

    name = "codex"

    def __init__(self, *, skip_git_repo_check: bool = True) -> None:
        self.skip_git_repo_check = skip_git_repo_check

    def run(self, request: ProviderRequest) -> ProviderResult:
        binary = _resolve_provider_binary("codex", "CAP_CODEX_BIN")
        if binary is None:
            return ProviderResult(
                status=STATUS_FAILED,
                exit_code=-1,
                stdout="",
                stderr="",
                duration_seconds=0.0,
                failure_reason=(
                    "codex binary not found "
                    "(set CAP_CODEX_BIN or install codex on PATH)"
                ),
            )

        cmd: list[str] = [binary, "exec"]
        if self.skip_git_repo_check:
            cmd.append("--skip-git-repo-check")
        cmd.append(request.prompt)

        merged_env = None
        if request.env is not None:
            merged_env = {**os.environ, **request.env}

        timeout = request.timeout_seconds
        started = time.monotonic()
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=merged_env,
            )
        except subprocess.TimeoutExpired as exc:
            elapsed = time.monotonic() - started
            return ProviderResult(
                status=STATUS_TIMEOUT,
                exit_code=-1,
                stdout=exc.stdout or "",
                stderr=exc.stderr or "",
                duration_seconds=elapsed,
                failure_reason=f"timeout: codex command exceeded {timeout}s",
            )
        except (FileNotFoundError, PermissionError) as exc:
            # Env override pointed at a non-existent / non-executable path.
            # Surface as a deterministic failed result rather than re-raising
            # so AgentSessionRunner records a clean failed session.
            elapsed = time.monotonic() - started
            return ProviderResult(
                status=STATUS_FAILED,
                exit_code=-1,
                stdout="",
                stderr="",
                duration_seconds=elapsed,
                failure_reason=f"codex binary unavailable: {exc}",
            )

        elapsed = time.monotonic() - started
        # Apply preamble strip; fall back to raw stdout when no marker is
        # present (mirrors shell `|| printf '%s\n' "${raw}"`).
        cleaned = _strip_codex_preamble(proc.stdout) or proc.stdout

        if proc.returncode == 0:
            return ProviderResult(
                status=STATUS_COMPLETED,
                exit_code=proc.returncode,
                stdout=cleaned,
                stderr=proc.stderr,
                duration_seconds=elapsed,
            )
        return ProviderResult(
            status=STATUS_FAILED,
            exit_code=proc.returncode,
            stdout=cleaned,
            stderr=proc.stderr,
            duration_seconds=elapsed,
            failure_reason=f"codex exited {proc.returncode}",
        )


class ClaudeAdapter(ProviderAdapter):
    """Claude CLI provider adapter (P5 #4).

    Mirrors ``scripts/cap-workflow-exec.sh:run_step_claude`` semantics:
    invokes ``claude -p <prompt>`` and returns stdout / stderr / exit
    code untouched. No preamble strip is needed because the ``-p`` mode
    emits the assistant response directly without banner / transcript
    noise (unlike Codex). stderr is captured separately (the shell
    version merges via ``2>&1``).

    Binary resolution: ``CAP_CLAUDE_BIN`` env override first (used by
    tests to point at a fake binary), then PATH lookup. Missing binary
    surfaces as ``ProviderResult(status=failed, exit_code=-1)`` with a
    deterministic ``failure_reason`` rather than raising
    FileNotFoundError, mirroring CodexAdapter so AgentSessionRunner
    records a clean failed session.

    Timeout / non-zero exit / completion all follow the established
    ShellAdapter / CodexAdapter shape and the P5 #9 ``timeout:`` prefix
    convention.

    Production execution remains in shell (P5 baseline §1); this
    adapter is for deterministic tests with a fake claude binary,
    future programmatic invocation paths, and as the eventual
    migration target.
    """

    name = "claude"

    def run(self, request: ProviderRequest) -> ProviderResult:
        binary = _resolve_provider_binary("claude", "CAP_CLAUDE_BIN")
        if binary is None:
            return ProviderResult(
                status=STATUS_FAILED,
                exit_code=-1,
                stdout="",
                stderr="",
                duration_seconds=0.0,
                failure_reason=(
                    "claude binary not found "
                    "(set CAP_CLAUDE_BIN or install claude on PATH)"
                ),
            )

        cmd = [binary, "-p", request.prompt]

        merged_env = None
        if request.env is not None:
            merged_env = {**os.environ, **request.env}

        timeout = request.timeout_seconds
        started = time.monotonic()
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=merged_env,
            )
        except subprocess.TimeoutExpired as exc:
            elapsed = time.monotonic() - started
            return ProviderResult(
                status=STATUS_TIMEOUT,
                exit_code=-1,
                stdout=exc.stdout or "",
                stderr=exc.stderr or "",
                duration_seconds=elapsed,
                failure_reason=f"timeout: claude command exceeded {timeout}s",
            )
        except (FileNotFoundError, PermissionError) as exc:
            # Env override pointed at a non-existent / non-executable path.
            # Surface as a deterministic failed result rather than re-raising
            # so AgentSessionRunner records a clean failed session (mirrors
            # CodexAdapter behaviour for the same condition).
            elapsed = time.monotonic() - started
            return ProviderResult(
                status=STATUS_FAILED,
                exit_code=-1,
                stdout="",
                stderr="",
                duration_seconds=elapsed,
                failure_reason=f"claude binary unavailable: {exc}",
            )

        elapsed = time.monotonic() - started
        if proc.returncode == 0:
            return ProviderResult(
                status=STATUS_COMPLETED,
                exit_code=proc.returncode,
                stdout=proc.stdout,
                stderr=proc.stderr,
                duration_seconds=elapsed,
            )
        return ProviderResult(
            status=STATUS_FAILED,
            exit_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            duration_seconds=elapsed,
            failure_reason=f"claude exited {proc.returncode}",
        )


class ShellAdapter(ProviderAdapter):
    """Run the prompt as a shell command via ``subprocess.run``.

    The request's ``prompt`` field is interpreted as a shell command
    string and executed via ``/bin/bash -c``. ``stdout`` and ``stderr``
    are captured separately. Timeout surfaces as
    ``ProviderResult(status='timeout', exit_code=-1)`` rather than
    raising, so callers always get a structured outcome.

    This is intentionally a thin wrapper: it does NOT replicate the
    shell executor's signal handling, background-process orchestration,
    stall-watchdog, or progress streaming. Production execution stays
    in ``scripts/cap-workflow-exec.sh`` per the P5 baseline memo;
    ``ShellAdapter`` is for deterministic tests and the eventual
    migration contract.
    """

    name = "shell"

    def run(self, request: ProviderRequest) -> ProviderResult:
        merged_env = None
        if request.env is not None:
            merged_env = {**os.environ, **request.env}

        timeout = request.timeout_seconds
        started = time.monotonic()
        try:
            proc = subprocess.run(
                ["/bin/bash", "-c", request.prompt],
                capture_output=True,
                text=True,
                timeout=timeout,
                env=merged_env,
            )
        except subprocess.TimeoutExpired as exc:
            elapsed = time.monotonic() - started
            return ProviderResult(
                status=STATUS_TIMEOUT,
                exit_code=-1,
                stdout=exc.stdout or "",
                stderr=exc.stderr or "",
                duration_seconds=elapsed,
                # P5 #9: standardized "timeout: ..." prefix so CLI / dry-run /
                # log consumers can branch on the failure family without
                # re-checking the status field separately.
                failure_reason=f"timeout: shell command exceeded {timeout}s",
            )

        elapsed = time.monotonic() - started
        if proc.returncode == 0:
            return ProviderResult(
                status=STATUS_COMPLETED,
                exit_code=proc.returncode,
                stdout=proc.stdout,
                stderr=proc.stderr,
                duration_seconds=elapsed,
            )
        return ProviderResult(
            status=STATUS_FAILED,
            exit_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            duration_seconds=elapsed,
            failure_reason=f"shell command exited {proc.returncode}",
        )
