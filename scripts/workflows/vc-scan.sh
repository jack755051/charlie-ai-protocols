#!/usr/bin/env bash
#
# vc-scan.sh — Pipeline step 1: scan + guard + evidence pack.
# 不做語意推斷、不寫 commit message。
# Exit code contract: policies/workflow-executor-exit-codes.md
#
# Stdout 包含：
#   - 人類可讀的 scan report
#   - 結構化 evidence pack (YAML in <<<EVIDENCE_BEGIN>>> ... <<<EVIDENCE_END>>>)
#
# 環境變數：
#   CAP_WORKFLOW_STEP_ID         — runtime 注入（預設 vc_scan）
#   CAP_WORKFLOW_USER_PROMPT     — 使用者原始指令，用於偵測 release intent
#   CAP_WORKFLOW_SELECTED_STRATEGY — fast / governed / strict
#   CAP_WORKFLOW_SELECTED_MODE     — legacy alias for selected strategy
#   VC_SCAN_DIFF_LINES           — diff_excerpt 取前 N 行（預設 240）

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-vc_scan}"
user_prompt="${CAP_WORKFLOW_USER_PROMPT:-}"
selected_strategy="${CAP_WORKFLOW_SELECTED_STRATEGY:-${CAP_WORKFLOW_SELECTED_MODE:-}}"
diff_lines="${VC_SCAN_DIFF_LINES:-240}"

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Shell Scan Report\n\n'
}

emit_yaml_str() {
  # 把任意字串轉成 YAML literal block 內容（前置 4 空格、保留換行）。
  local prefix="$1"
  shift
  if [ "$#" -eq 0 ]; then
    printf '%s |\n' "${prefix}"
    return
  fi
  printf '%s |\n' "${prefix}"
  printf '%s\n' "$@" | sed 's/^/    /'
}

detect_sensitive_files() {
  git status --short \
    | awk '{print $NF}' \
    | grep -E '(^|/)(\.env(\..*)?|credentials\.json|id_rsa|id_ed25519|.*\.pem|.*\.key)$' \
    || true
}

changed_paths() {
  git status --short | while IFS= read -r line; do
    code="${line:0:2}"
    path="${line:3}"
    if printf '%s' "${path}" | grep -q ' -> '; then
      path="${path##* -> }"
    fi
    if [ "${code}" = "??" ] && [ -d "${path}" ]; then
      git ls-files --others --exclude-standard -- "${path}"
    else
      printf '%s\n' "${path}"
    fi
  done
}

infer_type_for_path() {
  local path="$1"
  case "${path}" in
    docs/*|*.md) printf 'docs\n' ;;
    test/*|tests/*|*test*|*spec*) printf 'test\n' ;;
    scripts/*|engine/*|schemas/*|Makefile|*.sh|*.py|*.yaml|*.yml|*.json) printf 'feat\n' ;;
    *) printf 'chore\n' ;;
  esac
}

# 把 changed paths 拆成 token 集合，供 compose 引用、apply lint。
# 規則：取最後三層的 basename + 中間目錄段，切掉副檔名。
extract_path_tokens() {
  local paths="$1"
  printf '%s\n' "${paths}" | awk '
    function emit_token(t,    cleaned) {
      if (length(t) < 3) return
      cleaned = t
      gsub(/\.[a-z]+$/, "", cleaned)
      if (length(cleaned) < 3) return
      print cleaned
    }
    {
      n = split($0, parts, "/")
      for (i = 1; i <= n; i++) {
        emit_token(parts[i])
      }
      # 也把 basename 不去掉副檔名版本送出，便於 compose 直接命名（如 README.md）
      if (n > 0) print parts[n]
    }
  ' | sort -u | sed '/^$/d'
}

# 偵測使用者意圖是否為發版。grep 命中字面後仍要排除「版本控制」這種非發版用語。
detect_release_intent() {
  local prompt="$1"
  local stripped
  if [ -z "${prompt}" ]; then
    printf 'false\n'
    return
  fi
  stripped="$(printf '%s' "${prompt}" | sed -e 's/版本控制//g' -e 's/版控//g')"
  if printf '%s' "${stripped}" | grep -qiE 'release|tag|changelog|readme|發版|正式發布|發行'; then
    printf 'true\n'
    return
  fi
  if printf '%s' "${stripped}" | grep -qE '版本|正式'; then
    printf 'true\n'
    return
  fi
  printf 'false\n'
}

extract_explicit_tag() {
  local prompt="$1"
  printf '%s' "${prompt}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1
}

next_version_candidate() {
  local types="$1"
  local latest version major minor patch bump
  latest="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  version="${latest#v}"
  if ! printf '%s' "${version}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    version="0.0.0"
  fi
  IFS=. read -r major minor patch <<EOF
${version}
EOF

  bump="patch"
  if printf '%s\n' "${types}" | grep -qx 'feat'; then
    bump="minor"
  elif printf '%s\n' "${types}" | grep -qx 'fix'; then
    bump="patch"
  fi

  case "${bump}" in
    minor) minor=$((minor + 1)); patch=0 ;;
    *)     patch=$((patch + 1)) ;;
  esac
  printf 'v%s.%s.%s\n' "${major}" "${minor}" "${patch}"
}

# ── main ──

print_header

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'condition: policy_blocked\nreason: not_inside_git_work_tree\n'
  exit 30
fi

branch="$(git branch --show-current 2>/dev/null || true)"
if [ -z "${branch}" ]; then
  printf 'condition: policy_blocked\nreason: detached_head\n'
  exit 30
fi

status="$(git status --short)"
head_short="$(git rev-parse --short HEAD 2>/dev/null || true)"
latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"

printf 'branch: %s\n' "${branch}"
printf 'head: %s\n' "${head_short}"
printf 'latest_tag: %s\n\n' "${latest_tag:-<none>}"
printf '### Git Status\n\n```text\n%s\n```\n\n' "${status}"

if [ -z "${status}" ]; then
  printf 'condition: no_changes\nresult: nothing_to_commit\n'
  exit 10
fi

sensitive="$(detect_sensitive_files)"
if [ -n "${sensitive}" ]; then
  printf 'condition: sensitive_file_risk\n'
  printf 'matched_paths:\n%s\n' "${sensitive}"
  exit 50
fi

paths="$(changed_paths)"
types="$(printf '%s\n' "${paths}" | while IFS= read -r path; do
  [ -n "${path}" ] && infer_type_for_path "${path}"
done | sort -u | sed '/^$/d')"

path_tokens="$(extract_path_tokens "${paths}")"
release_intent="$(detect_release_intent "${user_prompt}")"
explicit_tag="$(extract_explicit_tag "${user_prompt}")"
next_tag="${explicit_tag:-$(next_version_candidate "${types}")}"

# diff stat + excerpt
diff_stat="$(git diff --stat 2>/dev/null; git diff --cached --stat 2>/dev/null)"
# 取 diff 前 N 行；對 untracked file，補一份內容 dump（避免 compose 看不到新檔內容）。
diff_excerpt_main="$(
  git diff --unified=2 2>/dev/null
  git diff --cached --unified=2 2>/dev/null
  git ls-files --others --exclude-standard | while IFS= read -r p; do
    [ -f "${p}" ] || continue
    if grep -Iq . "${p}" 2>/dev/null; then
      printf 'diff --git a/%s b/%s\n--- /dev/null\n+++ b/%s\n' "${p}" "${p}" "${p}"
      sed -n '1,160p' "${p}" | sed 's/^/+/'
    fi
  done
)"
diff_excerpt="$(printf '%s\n' "${diff_excerpt_main}" | sed -n "1,${diff_lines}p")"

printf '### Diff Stat\n\n```text\n%s\n```\n\n' "${diff_stat}"
printf '### Detected Types\n\n```text\n%s\n```\n\n' "${types}"
printf '### Release Intent\n\n```text\nrelease_intent=%s explicit_tag=%s next_tag_candidate=%s mode=%s\n```\n\n' \
  "${release_intent}" "${explicit_tag:-<none>}" "${next_tag}" "${selected_strategy:-<unset>}"

printf '<<<EVIDENCE_BEGIN>>>\n'
printf 'schema_version: 1\n'
printf 'branch: "%s"\n' "${branch}"
printf 'head: "%s"\n' "${head_short}"
printf 'latest_tag: "%s"\n' "${latest_tag}"
printf 'strategy: "%s"\n' "${selected_strategy}"
printf 'mode: "%s"\n' "${selected_strategy}"
printf 'release_intent: %s\n' "${release_intent}"
printf 'explicit_tag: "%s"\n' "${explicit_tag}"
printf 'next_tag_candidate: "%s"\n' "${next_tag}"
printf 'detected_types:\n'
printf '%s\n' "${types}" | sed 's/^/  - /'
printf 'changed_paths:\n'
printf '%s\n' "${paths}" | sed 's/^/  - /'
printf 'path_tokens:\n'
printf '%s\n' "${path_tokens}" | sed 's/^/  - /'
emit_yaml_str 'diff_stat:' "${diff_stat}"
emit_yaml_str 'diff_excerpt:' "${diff_excerpt}"
printf 'user_prompt: |\n'
printf '%s\n' "${user_prompt}" | sed 's/^/  /'
printf '<<<EVIDENCE_END>>>\n'

printf '\n## 交接摘要\n\n'
printf -- '- agent_id: shell-vc-scan\n'
printf -- '- task_summary: scan repo state and emit evidence pack for compose step\n'
printf -- '- output_paths:\n'
printf '  - %s\n' "${CAP_WORKFLOW_OUTPUT_PATH:-stdout}"
printf -- '- result: success\n'
printf -- '- release_intent: %s\n' "${release_intent}"
printf -- '- next_tag_candidate: %s\n' "${next_tag}"

exit 0
