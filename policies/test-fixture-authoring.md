# Test Fixture Authoring Policy (v1.0)

> 本文件定義 CAP shell fixture 的撰寫規範，目標是降低 `set -euo pipefail`、跨平台工具差異與測試 harness 本身造成的偶發失敗。

## 1. 核心原則

- Fixture 應測被測物，不應被 shell pipeline 行為干擾。
- 在 `set -o pipefail` 啟用的 fixture 中，避免使用會讓上游提前收到 `SIGPIPE` 的 pipeline。
- 搜尋檔案內容時，優先讓 `grep` 直接讀檔，而不是 `printf | grep`。
- 若必須搜尋變數內容，避免 `grep -q` 造成 early close；改用 here-string、`case`，或關閉 pipefail 的局部 helper。

## 2. `pipefail + grep -q` 陷阱

在 Bash 啟用 `set -o pipefail` 時，下列 pattern 可能偶發失敗：

```bash
printf '%s' "${large_output}" | grep -qF "needle"
```

原因是 `grep -q` 找到第一個 match 後會提前關閉 pipe，`printf` 仍可能繼續寫入並收到 `SIGPIPE`，pipeline exit code 變成 `141`。這會讓 fixture 誤判為 FAIL，即使 `needle` 實際存在。

## 3. 推薦寫法

### 3.1 搜尋檔案內容

優先使用：

```bash
grep -qF "needle" "${file}"
```

不要使用：

```bash
printf '%s' "$(cat "${file}")" | grep -qF "needle"
```

### 3.2 搜尋短字串變數

可使用 here-string：

```bash
grep -qF "needle" <<<"${output}"
```

或使用 `case`：

```bash
case "${output}" in
  *"needle"*) found=1 ;;
  *) found=0 ;;
esac
```

### 3.3 搜尋大型輸出

若輸出可能很大，先寫入暫存檔再 grep：

```bash
output_file="${SANDBOX}/command.out"
some_command > "${output_file}" 2>&1
grep -qF "needle" "${output_file}"
```

這是最穩定的 fixture pattern，也讓失敗時可印出 `tail` / `sed` 摘要協助 debug。

## 4. Assertion helper 建議

對 `assert_contains` 類 helper，偏好以下形式：

```bash
assert_file_contains() {
  local label="$1"
  local needle="$2"
  local file="$3"

  if grep -qF -- "${needle}" "${file}"; then
    pass
  else
    fail "${label}: missing '${needle}'"
  fi
}
```

若 helper 必須接收字串，建議用 `case` 避開 pipeline：

```bash
assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"

  case "${haystack}" in
    *"${needle}"*) pass ;;
    *) fail "${label}: missing '${needle}'" ;;
  esac
}
```

## 5. 例外

以下情境可保留 pipeline，但要能解釋原因：

- 需要測試 pipeline 本身的行為。
- 輸出很小且 helper 明確暫時停用 `pipefail`。
- 使用的是不會 early-close 的 consumer，例如 `grep` 不帶 `-q` 且完整消費輸入。

若不確定，選擇「寫入暫存檔，再 `grep PATTERN file`」。

## 6. 維護原則

- 新增 fixture 時，若檔案內容可被直接讀取，優先用 `grep PATTERN "${file}"`。
- 修 flaky test 時，先檢查是否有 `printf | grep -q`、`head` / `tail` 提前結束 pipeline、或平台相依工具輸出差異。
- 不要把 fixture harness 的穩定性修正混進產品行為變更，除非該 fixture 是同一個產品變更的 release gate。
