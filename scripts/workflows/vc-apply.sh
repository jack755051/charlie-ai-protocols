#!/usr/bin/env bash
#
# vc-apply.sh — Pipeline step 3: lint envelope, run git ops.
#
# Reads:
#   1. vc_compose 產出的 artifact 檔（路徑由 CAP_WORKFLOW_INPUT_CONTEXT 標示）
#   2. vc_scan 產出的 evidence pack（為了拿 path_tokens / release_intent / latest_tag）
#
# 流程：
#   parse evidence → parse envelope → lint → git ops (commit + optional tag/CHANGELOG/README) → push
#
# 任何 lint failure → exit 40 (git_operation_failed)，halt。
# Sensitive 已由 vc_scan 擋下，這裡不重做 sensitive scan。

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-vc_apply}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"
user_prompt="${CAP_WORKFLOW_USER_PROMPT:-}"
selected_strategy="${CAP_WORKFLOW_SELECTED_STRATEGY:-${CAP_WORKFLOW_SELECTED_MODE:-}}"

# ── 工具：紅字標記 lint 失敗原因，但不影響 stdout 結構 ──
fail_with() {
  local reason="$1"
  shift
  printf 'condition: git_operation_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Shell Apply Report\n\n'
}

# ── 從 input_context 抓 artifact path ──
# input_context 由 step_runtime.resolve_inputs() 產出，格式如：
#   - vc_evidence_pack:
#     - vc_evidence_pack: step=vc_scan mode=full_artifact path=/abs/path/1-vc_scan.md
extract_artifact_path() {
  local context="$1"
  local artifact_name="$2"
  # step_runtime.resolve_inputs 輸出格式：`- <artifact>: step=<x> mode=<y> path=<abs>`
  printf '%s' "${context}" \
    | awk -v want="${artifact_name}" '
        $0 ~ "^[[:space:]]*-[[:space:]]*"want":[[:space:]]*step=" {
          n = split($0, parts, "path=")
          if (n > 1) {
            split(parts[2], tail, /[[:space:]]+/)
            print tail[1]
            exit
          }
        }
        $0 ~ "^[[:space:]]*"want":[[:space:]]*step=" {
          n = split($0, parts, "path=")
          if (n > 1) {
            split(parts[2], tail, /[[:space:]]+/)
            print tail[1]
            exit
          }
        }
      '
}

# 較寬容的萃取：直接從 context 抓所有 path=...，再依 artifact name 推測
fallback_extract_path_by_keyword() {
  local context="$1"
  local keyword="$2"
  printf '%s' "${context}" \
    | grep -oE 'path=[^ ]+' \
    | sed 's/^path=//' \
    | grep -E "${keyword}" \
    | head -n 1
}

# ── parse envelope JSON 區段 ──
# 抓最後一組 <<<COMMIT_ENVELOPE_BEGIN>>>...<<<COMMIT_ENVELOPE_END>>>，
# 因為 Codex stdout 會包含 prompt 回顯，prompt 本身可能含有範例 envelope 文字。
extract_envelope_json() {
  local path="$1"
  awk '
    BEGIN { inside = 0; buf = "" }
    /<<<COMMIT_ENVELOPE_BEGIN>>>/ { inside = 1; buf = ""; next }
    /<<<COMMIT_ENVELOPE_END>>>/   { inside = 0; next }
    inside == 1 { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "${path}"
}

# 也抓 evidence pack 的 path_tokens / release_intent / latest_tag
extract_evidence_field() {
  local path="$1"
  local field="$2"
  awk -v f="${field}" '
    BEGIN { inside = 0 }
    /<<<EVIDENCE_BEGIN>>>/ { inside = 1; next }
    /<<<EVIDENCE_END>>>/   { inside = 0; next }
    inside == 1 && $0 ~ "^"f":" {
      sub("^"f":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "${path}"
}

extract_evidence_list() {
  local path="$1"
  local field="$2"
  awk -v f="${field}" '
    BEGIN { inside = 0; capturing = 0 }
    /<<<EVIDENCE_BEGIN>>>/ { inside = 1; next }
    /<<<EVIDENCE_END>>>/   { inside = 0; next }
    inside == 1 && $0 ~ "^"f":[[:space:]]*$" { capturing = 1; next }
    inside == 1 && capturing == 1 {
      if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:/) { capturing = 0; next }
      if ($0 ~ /^[[:space:]]*-[[:space:]]+/) {
        sub(/^[[:space:]]*-[[:space:]]+/, "")
        print
      }
    }
  ' "${path}"
}

# ── lint：subject ──
FORBIDDEN_LEAD_VERBS_REGEX='^(enforce|sync|refine|unify|streamline|consolidate|clarify|harden|strengthen|establish|introduce|govern|finalize|polish|adjust|tweak|optimize|enhance)\b'

lint_subject() {
  local subject="$1"
  local path_tokens_csv="$2"

  local len="${#subject}"
  if [ "${len}" -lt 10 ]; then
    fail_with "subject_too_short" "subject='${subject}' length=${len}"
  fi
  if [ "${len}" -gt 72 ]; then
    fail_with "subject_too_long" "subject='${subject}' length=${len}"
  fi

  if ! printf '%s' "${subject}" | grep -qE '^[a-z][a-z0-9-]+ '; then
    fail_with "subject_not_lower_verb_first" "subject='${subject}' (require: lowercase verb followed by description)"
  fi

  if printf '%s' "${subject}" | grep -qiE "${FORBIDDEN_LEAD_VERBS_REGEX}"; then
    fail_with "subject_forbidden_lead_verb" "subject='${subject}'" "禁止主動詞清單命中。請改用具體動詞如 add/remove/split/replace/move/extract/wire/gate/lint/parse/validate"
  fi

  # update / improve 後必須接具體名詞（這裡用啟發式：subject 不能只是 'update X' / 'improve X' 這種兩字組合）
  if printf '%s' "${subject}" | grep -qiE '^(update|improve|refactor)\b'; then
    local rest
    rest="$(printf '%s' "${subject}" | sed -E 's/^[a-z]+ //')"
    if [ "${#rest}" -lt 12 ]; then
      fail_with "subject_vague_after_update" "subject='${subject}' (update/improve/refactor 後描述太短，請具體說出做了什麼)"
    fi
  fi

  # 必須命中至少一個 path token（強制 subject 對齊真實變更）
  if [ -z "${path_tokens_csv}" ]; then
    return 0
  fi
  local hit=0
  local IFS=','
  for tok in ${path_tokens_csv}; do
    [ -z "${tok}" ] && continue
    if printf '%s' "${subject}" | grep -qiF "${tok}"; then
      hit=1
      break
    fi
  done
  if [ "${hit}" -eq 0 ]; then
    fail_with "subject_must_reference_changed_path" \
      "subject='${subject}'" \
      "必須引用至少一個 path token（如：${path_tokens_csv}）以確認 subject 對齊真實變更"
  fi
}

lint_tag_annotation() {
  local tag="$1"
  local annotation="$2"
  local path_tokens_csv="$3"

  if ! printf '%s' "${tag}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail_with "tag_format_invalid" "tag='${tag}' (require ^vX.Y.Z$)"
  fi

  local prefix="${tag} — "
  case "${annotation}" in
    "${prefix}"*) ;;
    *) fail_with "tag_annotation_missing_prefix" "annotation='${annotation}'" "必須以 '${prefix}' 開頭" ;;
  esac

  local summary="${annotation#${prefix}}"
  if [ "${#summary}" -lt 12 ]; then
    fail_with "tag_annotation_summary_too_short" "summary='${summary}'"
  fi

  if printf '%s' "${summary}" | grep -qiE "${FORBIDDEN_LEAD_VERBS_REGEX}"; then
    fail_with "tag_annotation_forbidden_lead_verb" "summary='${summary}'"
  fi
  case "${summary}" in
    "Release "*|"release "*) fail_with "tag_annotation_generic" "summary='${summary}'" "嚴禁 'Release vX.Y.Z' 這種泛用句" ;;
  esac

  # summary 也要命中至少一個 path token
  if [ -n "${path_tokens_csv}" ]; then
    local hit=0
    local IFS=','
    for tok in ${path_tokens_csv}; do
      [ -z "${tok}" ] && continue
      if printf '%s' "${summary}" | grep -qiF "${tok}"; then
        hit=1
        break
      fi
    done
    if [ "${hit}" -eq 0 ]; then
      fail_with "tag_annotation_summary_must_reference_changed_path" \
        "summary='${summary}'" \
        "tag annotation summary 必須引用至少一個 path token"
    fi
  fi
}

# ── main ──

print_header

# 1. resolve envelope artifact path
envelope_path="$(extract_artifact_path "${input_context}" "commit_envelope")"
if [ -z "${envelope_path}" ] || [ ! -f "${envelope_path}" ]; then
  envelope_path="$(fallback_extract_path_by_keyword "${input_context}" 'vc_compose|compose')"
fi
if [ -z "${envelope_path}" ] || [ ! -f "${envelope_path}" ]; then
  fail_with "missing_compose_artifact" "input_context did not include commit_envelope path"
fi

# 2. resolve evidence artifact path（取 path_tokens / release_intent / latest_tag）
evidence_path="$(extract_artifact_path "${input_context}" "vc_evidence_pack")"
if [ -z "${evidence_path}" ] || [ ! -f "${evidence_path}" ]; then
  evidence_path="$(fallback_extract_path_by_keyword "${input_context}" 'vc_scan|scan')"
fi

printf 'envelope_path: %s\n' "${envelope_path}"
printf 'evidence_path: %s\n\n' "${evidence_path:-<not-found>}"

# 3. parse envelope JSON via python
envelope_json="$(extract_envelope_json "${envelope_path}")"
if [ -z "${envelope_json}" ]; then
  fail_with "missing_envelope_block" "找不到 <<<COMMIT_ENVELOPE_BEGIN>>>...<<<COMMIT_ENVELOPE_END>>> 區段於 ${envelope_path}"
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail_with "python3_unavailable" "vc-apply 需要 python3 解析 envelope JSON"
fi

# 用 python parse 並驗證必填欄位
parsed="$(printf '%s' "${envelope_json}" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    print(f"PARSE_ERROR::{exc}")
    sys.exit(0)

def need(d, key):
    v = d.get(key)
    if v is None or (isinstance(v, str) and not v.strip()):
        return None
    return v

ct = need(data, "commit_type")
sc = need(data, "scope")
sj = need(data, "subject")
body = data.get("body") or ""
release = data.get("release") or {}
perform = bool(release.get("perform_release", False))
tag = release.get("tag") or ""
ann = release.get("annotation_summary") or ""
section = release.get("changelog_section") or ""
entries = release.get("changelog_entries") or []

if not ct or not sc or not sj:
    print("VALIDATE_ERROR::missing required fields commit_type/scope/subject")
    sys.exit(0)

print("OK")
print(f"commit_type::{ct}")
print(f"scope::{sc}")
print(f"subject::{sj}")
print(f"body::{body}")
print(f"perform_release::{1 if perform else 0}")
print(f"tag::{tag}")
print(f"annotation::{ann}")
print(f"section::{section}")
print(f"entries_count::{len(entries)}")
for i, e in enumerate(entries):
    print(f"entry_{i}::{e}")
' 2>&1)"

case "${parsed}" in
  "PARSE_ERROR::"*) fail_with "envelope_json_parse_error" "${parsed#PARSE_ERROR::}" ;;
  "VALIDATE_ERROR::"*) fail_with "envelope_validate_error" "${parsed#VALIDATE_ERROR::}" ;;
  "OK"*) ;;
  *) fail_with "envelope_unknown_state" "${parsed}" ;;
esac

commit_type=""; scope=""; subject=""; body=""; perform_release=0
tag=""; annotation=""; section=""
entries=()

while IFS= read -r line; do
  case "${line}" in
    "OK") ;;
    "commit_type::"*)    commit_type="${line#commit_type::}" ;;
    "scope::"*)          scope="${line#scope::}" ;;
    "subject::"*)        subject="${line#subject::}" ;;
    "body::"*)           body="${line#body::}" ;;
    "perform_release::"*) perform_release="${line#perform_release::}" ;;
    "tag::"*)            tag="${line#tag::}" ;;
    "annotation::"*)     annotation="${line#annotation::}" ;;
    "section::"*)        section="${line#section::}" ;;
    "entries_count::"*)  : ;;
    "entry_"*)           entries+=("${line#*::}") ;;
  esac
done <<< "${parsed}"

# 4. 收集 path_tokens / release_intent (from evidence)
path_tokens_csv=""
release_intent="false"
latest_tag=""
evidence_strategy="${selected_strategy}"
if [ -n "${evidence_path}" ] && [ -f "${evidence_path}" ]; then
  release_intent="$(extract_evidence_field "${evidence_path}" 'release_intent')"
  latest_tag="$(extract_evidence_field "${evidence_path}" 'latest_tag')"
  evidence_strategy="$(extract_evidence_field "${evidence_path}" 'strategy')"
  tokens="$(extract_evidence_list "${evidence_path}" 'path_tokens')"
  path_tokens_csv="$(printf '%s' "${tokens}" | tr '\n' ',' | sed 's/,$//')"
fi
evidence_strategy="${evidence_strategy:-${selected_strategy}}"

printf 'commit_type=%s\nscope=%s\nsubject=%s\n' "${commit_type}" "${scope}" "${subject}"
printf 'perform_release=%s tag=%s\n' "${perform_release}" "${tag}"
printf 'annotation=%s\n' "${annotation}"
printf 'release_intent_from_scan=%s latest_tag=%s strategy=%s\n' "${release_intent}" "${latest_tag}" "${evidence_strategy:-<unset>}"
printf 'path_tokens=%s\n\n' "${path_tokens_csv}"

# 5. lint
case "${commit_type}" in
  feat|fix|docs|refactor|test|chore|style|perf|build|ci) ;;
  *) fail_with "commit_type_not_conventional" "commit_type='${commit_type}'" ;;
esac

if ! printf '%s' "${scope}" | grep -qE '^[a-z][a-z0-9-]*$'; then
  fail_with "scope_invalid" "scope='${scope}' (require lowercase kebab-case)"
fi

lint_subject "${subject}" "${path_tokens_csv}"

if [ "${evidence_strategy}" = "fast" ] && [ "${perform_release}" = "1" ]; then
  fail_with "fast_strategy_release_blocked" "strategy=fast requires release.perform_release=false"
fi

if [ "${perform_release}" = "1" ]; then
  if [ "${release_intent}" != "true" ]; then
    fail_with "release_not_authorized" \
      "envelope.release.perform_release=true but scan release_intent=${release_intent}" \
      "compose 不得在 scan 未偵測到 release intent 時擅自發版"
  fi
  lint_tag_annotation "${tag}" "${annotation}" "${path_tokens_csv}"
  if [ "${#entries[@]}" -eq 0 ]; then
    fail_with "release_changelog_entries_missing" "release.changelog_entries 必須提供至少一條"
  fi
  for entry in "${entries[@]}"; do
    if [ "${#entry}" -lt 12 ]; then
      fail_with "release_changelog_entry_too_short" "entry='${entry}'"
    fi
    if printf '%s' "${entry}" | grep -qiE '^(update [a-z]+ workflow assets|sync release documentation|release v[0-9]+|update project documentation)$'; then
      fail_with "release_changelog_entry_generic" "entry='${entry}' (低訊號文字)"
    fi
  done
fi

# 6. compose final commit message
commit_message="${commit_type}(${scope}): ${subject}"
if [ -n "${body}" ]; then
  commit_message="${commit_message}

${body}"
fi

printf '### Lint passed\n\n```text\ncommit_message_first_line=%s(%s): %s\n```\n\n' \
  "${commit_type}" "${scope}" "${subject}"

# 7. git ops
git_or_fail() {
  if ! git "$@"; then
    fail_with "git_command_failed" "git $*"
  fi
}

git_or_fail add -A

if ! git diff --cached --quiet; then
  if [ -n "${body}" ]; then
    printf '%s\n\n%s\n' "${commit_type}(${scope}): ${subject}" "${body}" \
      | git_or_fail commit -F -
  else
    git_or_fail commit -m "${commit_type}(${scope}): ${subject}"
  fi
else
  fail_with "nothing_staged" "git add -A 後 staging 仍為空，可能 evidence 與實際 git state 不一致"
fi

commit_hash="$(git rev-parse --short HEAD)"
tag_result="not_requested"
push_result="skipped"

# 8. release path: CHANGELOG / README / annotated tag / push
if [ "${perform_release}" = "1" ]; then
  today="$(date '+%Y-%m-%d')"

  if [ -f CHANGELOG.md ] && ! grep -q "^## \\[${tag}\\]" CHANGELOG.md; then
    tmp="$(mktemp)"
    entries_tmp="$(mktemp)"
    : > "${entries_tmp}"
    for entry in "${entries[@]}"; do
      printf '%s\n' "${entry}" >> "${entries_tmp}"
    done

    # Step A: 在第一個 `## ` 之前插入 `## [tag] - today` 區塊與空 section
    awk -v tag="${tag}" -v today="${today}" -v section="${section:-Changed}" '
      BEGIN { inserted = 0 }
      NR == 1 { print; next }
      inserted == 0 && /^## / {
        print ""
        print "## [" tag "] - " today
        print ""
        print "### " section
        inserted = 1
      }
      { print }
      END {
        if (inserted == 0) {
          print ""
          print "## [" tag "] - " today
          print ""
          print "### " section
        }
      }
    ' CHANGELOG.md > "${tmp}"

    # Step B: 在剛插入的 `### section` 後補上 entries
    awk -v tag="${tag}" -v section="${section:-Changed}" -v entries_file="${entries_tmp}" '
      BEGIN {
        inserted = 0
        n = 0
        while ((getline line < entries_file) > 0) {
          items[n++] = line
        }
        close(entries_file)
        target_section = "### " section
        in_target = 0
      }
      {
        print
        if (!inserted && $0 ~ "^## \\[" tag "\\]") {
          in_target = 1
        }
        if (in_target && !inserted && $0 == target_section) {
          for (i = 0; i < n; i++) print "- " items[i]
          inserted = 1
          in_target = 0
        }
      }
    ' "${tmp}" > CHANGELOG.md
    rm -f "${tmp}" "${entries_tmp}"
  fi

  if [ -f README.md ]; then
    sed -i -E "s/最新已驗證 tag：\`v[0-9]+\\.[0-9]+\\.[0-9]+\`/最新已驗證 tag：\`${tag}\`/g" README.md
  fi

  # 把 CHANGELOG / README 變動 amend 進剛才的 commit
  if ! git diff --quiet -- CHANGELOG.md README.md 2>/dev/null; then
    git_or_fail add CHANGELOG.md README.md
    git_or_fail commit --amend --no-edit
    commit_hash="$(git rev-parse --short HEAD)"
  fi

  git_or_fail tag -a "${tag}" -m "${annotation}"
  tag_result="created:${tag}"
fi

# 9. push (only if upstream configured)
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  if git push; then
    push_result="pushed_upstream"
    if [ "${perform_release}" = "1" ]; then
      if git push origin "${tag}"; then
        tag_result="pushed:${tag}"
      else
        fail_with "git_push_tag_failed" "git push origin ${tag}"
      fi
    fi
  else
    fail_with "git_push_failed" "git push"
  fi
else
  push_result="no_upstream_configured"
fi

printf '\n## 交接摘要\n\n'
printf -- '- agent_id: shell-vc-apply\n'
printf -- '- task_summary: lint commit envelope and execute git ops\n'
printf -- '- output_paths:\n'
printf '  - %s\n' "${CAP_WORKFLOW_OUTPUT_PATH:-stdout}"
printf -- '- result: success\n'
printf -- '- commit_hash: %s\n' "${commit_hash}"
printf -- '- commit_message: %s(%s): %s\n' "${commit_type}" "${scope}" "${subject}"
printf -- '- tag_result: %s\n' "${tag_result}"
printf -- '- push_result: %s\n' "${push_result}"

exit 0
