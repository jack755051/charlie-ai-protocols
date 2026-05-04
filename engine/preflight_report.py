"""Preflight report builder.

Produces a machine-readable workflow execution-readiness summary after
the compile pipeline's validation + policy gates pass. The artifact is
returned as the ``preflight_report`` key on
``engine.task_scoped_compiler.TaskScopedWorkflowCompiler.compile_task`` /
``compile_task_from_envelope`` and is rendered by
``cap workflow run-task --dry-run``.

Schema: ``schemas/preflight-report.schema.yaml`` (8 required top-level
fields including ``schema_version: 1``).

Scope boundary: this builder runs only after the policy gates accept
the binding. Blocked / schema-failed cases halt earlier via the
existing exception classes (``BindingPolicyError`` /
``CompiledWorkflowSchemaError`` / ``BindingReportSchemaError`` /
``WorkflowSourcePolicyError``) and never reach this builder. So
``is_executable: true`` and ``blocking_reasons: []`` are the steady-state
values today; the contract reserves ``false`` and a populated reasons
list for future scenarios where partial state is inspected.
"""

from __future__ import annotations

from typing import Any


def build_preflight_report(compiled_workflow: dict, binding: dict) -> dict:
    """Construct a preflight report dict from a passed compile bundle.

    Inputs are the post-policy-gate ``compiled_workflow`` (already validated
    by ``ensure_valid_compiled_workflow``) and ``binding`` report (already
    validated by ``ensure_valid_binding_report`` and accepted by
    ``ensure_binding_status_executable``). Caller guarantees both have
    cleared their respective gates; the builder does not re-validate.
    """
    summary = binding.get("summary") or {}
    binding_status = binding.get("binding_status", "ready")

    warnings = _collect_warnings(binding, summary)

    return {
        "schema_version": 1,
        "workflow_id": compiled_workflow["workflow_id"],
        "binding_status": binding_status,
        "is_executable": True,
        "gates": {
            "compiled_workflow_schema": "passed",
            "binding_report_schema": "passed",
            "binding_policy": "passed",
            "source_root_policy": "passed",
        },
        "unresolved_summary": {
            "total_steps": int(summary.get("total_steps", 0)),
            "resolved_steps": int(summary.get("resolved_steps", 0)),
            "fallback_steps": int(summary.get("fallback_steps", 0)),
            "unresolved_optional_steps": int(
                summary.get("unresolved_optional_steps", 0)
            ),
        },
        "warnings": warnings,
        "blocking_reasons": [],
    }


def _collect_warnings(binding: dict, summary: dict) -> list[str]:
    warnings: list[str] = []

    fallback_steps = int(summary.get("fallback_steps", 0))
    if fallback_steps > 0:
        warnings.append(
            f"{fallback_steps} step(s) bound to a fallback skill; review before run"
        )

    optional_unresolved = int(summary.get("unresolved_optional_steps", 0))
    if optional_unresolved > 0:
        warnings.append(
            f"{optional_unresolved} optional step(s) unresolved; will be skipped or downgraded at run"
        )

    for step in binding.get("steps") or []:
        status = step.get("resolution_status")
        if status == "fallback_available":
            warnings.append(
                f"step '{step.get('step_id', '<unknown>')}' uses fallback skill "
                f"'{step.get('selected_skill_id', '<unknown>')}'"
            )
        elif status == "optional_unresolved":
            warnings.append(
                f"optional step '{step.get('step_id', '<unknown>')}' has no skill binding"
            )

    return warnings
