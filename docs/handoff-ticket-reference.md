# Handoff Ticket 概念參考 (v1)

> **狀態：概念參考文件。** 本檔案定義任務交接單的欄位語意，供 agent prompt 引用。
> Engine 尚未實例化此結構；實際交接由 task_scoped_compiler 與 executor 的 runtime-state 處理。
> 原路徑：`schemas/handoff-ticket.schema.yaml`

schema_version: 1

fields:

  # ── 必填欄位 ──

  target_capability:
    type: string
    required: true
    description: 此任務所需的 capability 名稱（對應 capabilities.yaml）

  task_objective:
    type: string
    required: true
    description: 精確描述任務範圍

  workflow_context:
    type: object
    required: false
    fields:
      workflow_id:
        type: string
      phase:
        type: integer
      step_id:
        type: string
      step_name:
        type: string
      upstream_steps:
        type: string[]
      route_back_to:
        type: string
        description: 失敗或修復後應回流的 step id

  rules_to_load:
    type: string[]
    required: true
    description: 應掛載的 agent-skills 與 strategy 路徑清單

  acceptance_criteria:
    type: string[]
    required: false
    description: 本次任務的完成條件；通常由 workflow step.done_when 映射而來

  dispatch_control:
    type: object
    required: false
    fields:
      dispatch_reason:
        type: string
        description: 為何將本次任務派給此 capability / agent
      selected_by:
        type: string
        description: 例如 01-Supervisor
      retry_count:
        type: integer
      escalation_to:
        type: string

  # ── 技術約束 ──

  tech_constraints:
    type: string
    required: false
    description: 技術約束與遺留守護（例如：必須沿用 resquest 拼寫）

  # ── 紀錄模式（由 workflow 決定，非 agent 自行判斷）──

  record_mode:
    type: object
    required: false
    fields:
      run_mode:
        type: string
        enum: [orchestration, standalone]
        description: 編排模式或獨立呼叫
      task_scope:
        type: string
        enum: [module, adhoc]
        description: 模組任務或臨時任務
      record_level:
        type: string
        enum: [trace_only, full_log]
        description: 紀錄層級

  # ── 設計交付模式 ──

  design_delivery:
    type: object
    required: false
    fields:
      design_output_mode:
        type: string
        enum: [assets_only, assets_plus_figma]
      figma_sync_mode:
        type: string
        enum: [none, mcp, import_script]
      figma_target:
        type: string
        description: file_key / project_name / page_name

  # ── 交接 Context（上游產物路徑）──

  context_payload:
    type: object
    required: false
    fields:
      prd_path:
        type: string
      tech_plan_path:
        type: string
      ba_spec_path:
        type: string
      api_spec_path:
        type: string
      schema_ssot_path:
        type: string
      ui_spec_path:
        type: string
      design_assets_paths:
        type: string[]
      analytics_spec_path:
        type: string
      lighthouse_report_path:
        type: string
      figma_sync_report_path:
        type: string

  governance:
    type: object
    required: false
    fields:
      watcher_required:
        type: boolean
      security_required:
        type: boolean
      qa_required:
        type: boolean
      logger_required:
        type: boolean
      governance_mode:
        type: string
        enum: [always_on, milestone_gate, final_only]
      record_mode_hint:
        type: string
        enum: [full_log, milestone_log, final_only]

  artifact_manifest:
    type: object[]
    required: false
    description: 本 step 明確依賴或產出的 artifact 清單
    item_fields:
      name:
        type: string
      path:
        type: string
      source_step:
        type: string
      version:
        type: string

  # ── Agent 交接產出（由完成任務的 agent 填寫）──

  handoff_output:
    type: object
    required: false
    description: Agent 完成任務後應填寫的交接摘要
    fields:
      agent_id:
        type: string
        description: "例如：04-Frontend"
      task_summary:
        type: string
      output_paths:
        type: string[]
      result:
        type: string
        enum: [success, failure, needs_data]
