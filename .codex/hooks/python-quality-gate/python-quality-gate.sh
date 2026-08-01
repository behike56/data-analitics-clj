#!/usr/bin/env bash
#
# 配布用の軽量 Codex Python quality gate hook。
#
# hook 実装は shell です。検査対象のコードとテスト対象は Python です。
# ruff / mypy / pytest が未導入のプロジェクトでも壊れないように、未導入の
# チェックは skip として扱います。実行できたチェックの失敗、またはチェック後の
# 対象 Python ファイル変更だけを Stop で block します。

set -u

ACTION="${1:-}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="$REPO_ROOT/.codex-hook-state"
STATE_FILE="$STATE_DIR/python-quality-gate.state"
FILES_FILE="$STATE_DIR/python-quality-gate.files"
LOG_FILE="$STATE_DIR/python-quality-gate.log"
STATE_SCHEMA_VERSION=3

CHECK_FORMATTER=0
CHECK_LINT=0
CHECK_TYPECHECK=0
CHECK_TESTS=0
CHECK_STATUS="passed"
RUN_SCOPE_KIND="manual-dirty-python"
TOOL_CMD=()
BLOCK_REASONS=()
RAN_FORMATTER=0
RAN_LINT=0
RAN_TYPECHECK=0
RAN_TESTS=0

usage() {
  printf 'usage: python-quality-gate.sh [run-post-tool|stop|status]\n' >&2
}

main() {
  case "$ACTION" in
    run-post-tool)
      run_post_tool
      ;;
    stop)
      drain_stdin
      run_stop
      ;;
    status)
      run_status
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

run_post_tool() {
  ensure_state_dir

  local hook_input
  hook_input="$(cat || true)"

  local files_tmp
  files_tmp="$(mktemp)"
  build_run_file_list "$hook_input" >"$files_tmp"

  if [[ ! -s "$files_tmp" ]]; then
    : >"$FILES_FILE"
    : >"$LOG_FILE"
    write_state "$(fingerprint_from_list "$files_tmp")"
    printf 'Python quality gate recorded passed. No scoped Python changes were found.\n' >&2
    exit 0
  fi

  : >"$LOG_FILE"
  cp "$files_tmp" "$FILES_FILE"

  local fingerprint
  fingerprint="$(fingerprint_from_list "$files_tmp")"

  CHECK_FORMATTER=0
  CHECK_LINT=0
  CHECK_TYPECHECK=0
  CHECK_TESTS=0

  local projects_tmp
  projects_tmp="$(mktemp)"
  cut -d '|' -f 1 "$files_tmp" | sort -u >"$projects_tmp"

  local project_root
  while IFS= read -r project_root; do
    [[ -n "$project_root" ]] || continue
    run_project_checks "$project_root" "$files_tmp"
  done <"$projects_tmp"

  if [[ "$CHECK_FORMATTER" -ne 0 || "$CHECK_LINT" -ne 0 || "$CHECK_TYPECHECK" -ne 0 || "$CHECK_TESTS" -ne 0 ]]; then
    CHECK_STATUS="failed"
  else
    CHECK_STATUS="passed"
  fi

  write_state "$fingerprint"
  printf 'Python quality gate recorded %s. See %s\n' "$CHECK_STATUS" "$LOG_FILE" >&2
  exit 0
}

run_stop() {
  ensure_state_dir

  local files_tmp
  files_tmp="$(mktemp)"
  build_active_project_file_list >"$files_tmp"

  if [[ ! -s "$files_tmp" ]]; then
    exit 0
  fi

  evaluate_state "$files_tmp"
  if [[ "${#BLOCK_REASONS[@]}" -eq 0 ]]; then
    exit 0
  fi

  emit_block_json "$(continuation_prompt)"
  exit 0
}

run_status() {
  ensure_state_dir

  local files_tmp
  files_tmp="$(mktemp)"
  build_active_project_file_list >"$files_tmp"

  if [[ ! -s "$files_tmp" ]]; then
    printf '{"status":"allow","reasons":[]}\n'
    exit 0
  fi

  evaluate_state "$files_tmp"
  if [[ "${#BLOCK_REASONS[@]}" -eq 0 ]]; then
    printf '{"status":"allow","reasons":[]}\n'
  else
    printf '{"status":"block","reasons":['
    local first=1
    local reason
    for reason in "${BLOCK_REASONS[@]}"; do
      if [[ "$first" -eq 0 ]]; then
        printf ','
      fi
      first=0
      printf '"%s"' "$(printf '%s' "$reason" | json_escape)"
    done
    printf ']}\n'
  fi
}

run_project_checks() {
  local project_root="$1"
  local files_tmp="$2"

  local project_files=()
  local repo_rel
  while IFS='|' read -r root repo_rel; do
    [[ "$root" == "$project_root" ]] || continue
    project_files+=("$(project_relative "$project_root" "$REPO_ROOT/$repo_rel")")
  done <"$files_tmp"

  [[ "${#project_files[@]}" -gt 0 ]] || return 0

  local existing_project_files=()
  local project_file
  for project_file in "${project_files[@]}"; do
    if [[ -f "$project_root/$project_file" ]]; then
      existing_project_files+=("$project_file")
    fi
  done

  local code
  if [[ "${#existing_project_files[@]}" -eq 0 ]]; then
    log_skipped "formatter" "$project_root" "No existing Python files are in scope."
  else
    run_named_check "formatter" "$project_root" ruff format --check "${existing_project_files[@]}"
    code=$?
    update_check_code formatter "$code"
  fi

  if [[ "${#existing_project_files[@]}" -eq 0 ]]; then
    log_skipped "lint" "$project_root" "No existing Python files are in scope."
  else
    run_named_check "lint" "$project_root" ruff check "${existing_project_files[@]}"
    code=$?
    update_check_code lint "$code"
  fi

  local typecheck_targets=()
  local typecheck_target
  while IFS= read -r typecheck_target; do
    [[ -n "$typecheck_target" ]] && typecheck_targets+=("$typecheck_target")
  done < <(typecheck_targets "$project_root" "${existing_project_files[@]}")

  if [[ "${#typecheck_targets[@]}" -eq 0 ]]; then
    log_skipped "typecheck" "$project_root" "No mypy target was found."
  else
    run_named_check "typecheck" "$project_root" mypy "${typecheck_targets[@]}"
    code=$?
    update_check_code typecheck "$code"
  fi

  local test_targets=()
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] && test_targets+=("$target")
  done < <(related_test_targets "$project_root" "${project_files[@]}")

  if [[ "${#test_targets[@]}" -eq 0 ]]; then
    log_skipped "tests" "$project_root" "No related pytest target was found."
  else
    run_named_check "tests" "$project_root" pytest -q "${test_targets[@]}"
    code=$?
    update_check_code tests "$code"
  fi
}

run_named_check() {
  local name="$1"
  local project_root="$2"
  local tool="$3"
  shift 3

  if ! build_tool_command "$project_root" "$tool" "$@"; then
    log_skipped "$name" "$project_root" "$tool is not available."
    return 0
  fi

  mark_check_ran "$name"
  run_command "$name" "$project_root" "${TOOL_CMD[@]}"
}

run_command() {
  local name="$1"
  local project_root="$2"
  shift 2

  local started
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  (
    cd "$project_root" || exit 127
    export UV_CACHE_DIR="${UV_CACHE_DIR:-$(temporary_cache_root)/uv-cache}"
    export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$(temporary_cache_root)/pycache}"
    export UV_NO_PROGRESS="${UV_NO_PROGRESS:-1}"
    export UV_PYTHON_DOWNLOADS="${UV_PYTHON_DOWNLOADS:-never}"
    mkdir -p "$UV_CACHE_DIR" "$PYTHONPYCACHEPREFIX" 2>/dev/null || true

    {
      printf '== %s ==\n' "$name"
      printf 'started_at: %s\n' "$started"
      printf 'cwd: %s\n' "$project_root"
      printf 'command:'
      quote_command "$@"
      printf '\n-- output --\n'
    } >>"$LOG_FILE"

    "$@" >>"$LOG_FILE" 2>&1
    local code=$?
    {
      printf '\nexit_code: %s\n' "$code"
      printf '\n'
    } >>"$LOG_FILE"
    exit "$code"
  )
}

build_tool_command() {
  local project_root="$1"
  local tool="$2"
  shift 2

  TOOL_CMD=()

  if [[ "$tool" == "mypy" || "$tool" == "pytest" ]]; then
    if [[ -x "$project_root/.venv/bin/python" ]]; then
      TOOL_CMD=("$project_root/.venv/bin/python" -m "$tool" "$@")
      return 0
    fi
  fi

  if [[ -x "$project_root/.venv/bin/$tool" ]]; then
    TOOL_CMD=("$project_root/.venv/bin/$tool" "$@")
    return 0
  fi

  local on_path
  on_path="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -n "$on_path" ]]; then
    TOOL_CMD=("$on_path" "$@")
    return 0
  fi

  local uv_bin
  uv_bin="$(command -v uv 2>/dev/null || true)"
  if [[ -n "$uv_bin" && -f "$project_root/pyproject.toml" ]]; then
    TOOL_CMD=("$uv_bin" run --group dev "$tool" "$@")
    return 0
  fi

  return 1
}

related_test_targets() {
  local project_root="$1"
  shift

  local targets_tmp
  targets_tmp="$(mktemp)"
  local fallback_to_tests=0

  local rel_path
  for rel_path in "$@"; do
    case "$rel_path" in
      tests/**/test_*.py|tests/test_*.py)
        if [[ -f "$project_root/$rel_path" ]]; then
          printf '%s\n' "$rel_path" >>"$targets_tmp"
        else
          fallback_to_tests=1
        fi
        ;;
      tests/conftest.py|tests/**/conftest.py|tests/helpers/*.py|tests/helpers/**/*.py)
        fallback_to_tests=1
        ;;
    esac
  done

  if [[ -d "$project_root/tests" ]]; then
    local all_tests_tmp
    all_tests_tmp="$(mktemp)"
    (
      cd "$project_root" || exit 0
      find tests -type f -name 'test_*.py' | sort
    ) >"$all_tests_tmp"

    for rel_path in "$@"; do
      case "$rel_path" in
        tests/*)
          continue
          ;;
      esac

      if [[ ! -f "$project_root/$rel_path" ]]; then
        fallback_to_tests=1
        continue
      fi

      local stem
      stem="$(basename "$rel_path" .py)"
      local module_tail
      module_tail="$(printf '%s' "${rel_path%.py}" | awk -F/ '{ if (NF >= 2) print $(NF-1) "_" $NF; else print $NF }')"

      local test_file
      while IFS= read -r test_file; do
        local base
        base="$(basename "$test_file")"
        case "$base" in
          "test_${stem}.py"|*"$stem"*|*"$module_tail"*)
            printf '%s\n' "$test_file" >>"$targets_tmp"
            ;;
        esac
      done <"$all_tests_tmp"
    done

    if [[ "$fallback_to_tests" -eq 1 || ! -s "$targets_tmp" ]]; then
      printf 'tests\n' >>"$targets_tmp"
    fi
  fi

  sort -u "$targets_tmp"
}

typecheck_targets() {
  local project_root="$1"
  shift

  local targets_tmp
  targets_tmp="$(mktemp)"

  if [[ -d "$project_root/src" ]]; then
    printf 'src\n' >>"$targets_tmp"
  fi

  if [[ -d "$project_root/tests" ]]; then
    printf 'tests\n' >>"$targets_tmp"
  fi

  if [[ ! -s "$targets_tmp" ]]; then
    local rel_path
    for rel_path in "$@"; do
      if [[ -f "$project_root/$rel_path" ]]; then
        printf '%s\n' "$rel_path" >>"$targets_tmp"
      fi
    done
  fi

  sort -u "$targets_tmp"
}

build_run_file_list() {
  local hook_input="$1"

  if [[ -n "$hook_input" ]]; then
    RUN_SCOPE_KIND="post-tool-python-edits"

    local hook_paths_tmp
    hook_paths_tmp="$(mktemp)"
    extract_hook_python_paths "$hook_input" >"$hook_paths_tmp"

    if [[ ! -s "$hook_paths_tmp" ]]; then
      build_active_project_file_list
      return 0
    fi

    local scoped_files_tmp
    scoped_files_tmp="$(mktemp)"
    build_project_file_list_from_paths "$hook_paths_tmp" >"$scoped_files_tmp"

    local active_files_tmp
    active_files_tmp="$(mktemp)"
    build_active_project_file_list >"$active_files_tmp"

    {
      cat "$active_files_tmp"
      cat "$scoped_files_tmp"
    } | sort -u
    return 0
  fi

  RUN_SCOPE_KIND="manual-dirty-python"
  build_all_dirty_project_file_list
}

build_active_project_file_list() {
  build_still_dirty_file_list "$FILES_FILE"
}

build_still_dirty_file_list() {
  local files_file="$1"
  [[ -f "$files_file" ]] || return 0

  while IFS='|' read -r _root rel_path; do
    [[ -n "$rel_path" ]] || continue
    is_dirty_python_path "$rel_path" || continue

    local project_root
    project_root="$(find_project_root "$rel_path" || true)"
    [[ -n "$project_root" ]] || continue
    printf '%s|%s\n' "$project_root" "$rel_path"
  done <"$files_file" | sort -u
}

build_all_dirty_project_file_list() {
  local candidates_tmp
  candidates_tmp="$(mktemp)"

  git -C "$REPO_ROOT" diff --name-only --diff-filter=ACMRTUXBD HEAD -- '*.py' >"$candidates_tmp" 2>/dev/null || true
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -- '*.py' >>"$candidates_tmp" 2>/dev/null || true

  build_project_file_list_from_paths "$candidates_tmp"
}

build_project_file_list_from_paths() {
  local paths_file="$1"

  sort -u "$paths_file" | while IFS= read -r raw_path; do
    local rel_path
    rel_path="$(normalize_repo_rel_path "$raw_path")"
    [[ -n "$rel_path" ]] || continue
    is_ignored_python_path "$rel_path" && continue
    is_dirty_python_path "$rel_path" || continue

    local project_root
    project_root="$(find_project_root "$rel_path" || true)"
    [[ -n "$project_root" ]] || continue
    printf '%s|%s\n' "$project_root" "$rel_path"
  done | sort -u
}

extract_hook_python_paths() {
  local hook_input="$1"
  [[ -n "$hook_input" ]] || return 0

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  local values_tmp
  values_tmp="$(mktemp)"
  printf '%s' "$hook_input" | jq -r '
    def maybe_path:
      if type == "string" then .
      elif type == "object" then .file_path? // .path? // .filename? // .file? // empty
      else empty end;

    (
      .tool_input.file_path?,
      .tool_input.path?,
      .tool_input.filename?,
      .tool_input.file?,
      .tool_input.patch?,
      .tool_input.input?,
      (.tool_input.paths[]? | maybe_path),
      (.tool_input.files[]? | maybe_path),
      (.tool_input.edits[]? | maybe_path)
    )
    | select(type == "string")
  ' >"$values_tmp" 2>/dev/null || true

  while IFS= read -r value; do
    emit_python_path_from_hook_value "$value"
  done <"$values_tmp" | sort -u
}

emit_python_path_from_hook_value() {
  local value="$1"
  local path=""

  case "$value" in
    "*** Add File: "*)
      path="${value#"*** Add File: "}"
      ;;
    "*** Update File: "*)
      path="${value#"*** Update File: "}"
      ;;
    "*** Delete File: "*)
      path="${value#"*** Delete File: "}"
      ;;
    "*** Move to: "*)
      path="${value#"*** Move to: "}"
      ;;
    *.py)
      path="$value"
      ;;
  esac

  path="$(normalize_repo_rel_path "$path")"
  [[ -n "$path" ]] || return 0
  printf '%s\n' "$path"
}

normalize_repo_rel_path() {
  local path="$1"
  path="$(trim_string "$path")"
  [[ -n "$path" ]] || return 0

  case "$path" in
    "$REPO_ROOT"/*)
      path="${path#"$REPO_ROOT"/}"
      ;;
    ./*)
      path="${path#./}"
      ;;
    a/*.py|b/*.py)
      path="${path#?/}"
      ;;
    /*)
      return 0
      ;;
  esac

  case "$path" in
    *.py)
      ;;
    *)
      return 0
      ;;
  esac

  case "$path" in
    ../*|*/../*|.git/*)
      return 0
      ;;
  esac

  printf '%s\n' "$path"
}

trim_string() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

is_dirty_python_path() {
  local rel_path="$1"
  [[ "$rel_path" == *.py ]] || return 1
  [[ -n "$(git -C "$REPO_ROOT" status --porcelain=v1 -- "$rel_path" 2>/dev/null || true)" ]]
}

find_project_root() {
  local rel_path="$1"
  local dir
  dir="$(dirname "$REPO_ROOT/$rel_path")"

  while :; do
    if [[ -f "$dir/pyproject.toml" || -f "$dir/setup.cfg" || -f "$dir/tox.ini" || -f "$dir/pytest.ini" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [[ "$dir" == "$REPO_ROOT" || "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

fingerprint_from_list() {
  local files_tmp="$1"
  {
    printf 'python-quality-gate-shell-v1\n'
    while IFS='|' read -r _root rel_path; do
      printf 'path=%s\n' "$rel_path"
      git -C "$REPO_ROOT" status --porcelain=v1 -- "$rel_path" 2>/dev/null || true
      if [[ -f "$REPO_ROOT/$rel_path" ]]; then
        sha256_file "$REPO_ROOT/$rel_path"
      else
        printf '<missing>\n'
      fi
    done <"$files_tmp"
  } | sha256_stdin
}

evaluate_state() {
  local files_tmp="$1"
  BLOCK_REASONS=()

  local current_fingerprint
  current_fingerprint="$(fingerprint_from_list "$files_tmp")"

  if [[ ! -f "$STATE_FILE" ]]; then
    BLOCK_REASONS+=("code changes exist but no quality gate result was recorded")
    return 0
  fi

  local schema_version
  schema_version="$(state_get schema_version)"
  if [[ "$schema_version" != "$STATE_SCHEMA_VERSION" ]]; then
    BLOCK_REASONS+=("quality gate state schema is stale; rerun the quality gate")
    return 0
  fi

  local recorded_fingerprint
  recorded_fingerprint="$(state_get fingerprint)"
  if [[ "$recorded_fingerprint" != "$current_fingerprint" ]]; then
    BLOCK_REASONS+=("recorded quality gate result is stale for the current Python changes")
  fi

  local status
  status="$(state_get status)"
  if [[ "$status" != "passed" ]]; then
    BLOCK_REASONS+=("quality gate status is not passed")
  fi

  require_zero_check formatter "formatter check failed"
  require_zero_check lint "lint failed"
  require_zero_check typecheck "typecheck failed"
  require_zero_check tests "test failure log exists"
}

require_zero_check() {
  local key="$1"
  local failed_reason="$2"
  local ran
  local value
  ran="$(state_get "ran_${key}")"
  value="$(state_get "$key")"

  if [[ "$ran" != "1" ]]; then
    return 0
  fi

  if [[ "$value" != "0" ]]; then
    BLOCK_REASONS+=("$failed_reason ($key exit code: $value)")
  fi
}

write_state() {
  local fingerprint="$1"
  local tmp
  tmp="$STATE_FILE.tmp"

  {
    printf 'schema_version=%s\n' "$STATE_SCHEMA_VERSION"
    printf 'created_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'repo_root=%s\n' "$REPO_ROOT"
    printf 'scope=%s\n' "$RUN_SCOPE_KIND"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'status=%s\n' "$CHECK_STATUS"
    printf 'formatter=%s\n' "$CHECK_FORMATTER"
    printf 'lint=%s\n' "$CHECK_LINT"
    printf 'typecheck=%s\n' "$CHECK_TYPECHECK"
    printf 'tests=%s\n' "$CHECK_TESTS"
    printf 'ran_formatter=%s\n' "$RAN_FORMATTER"
    printf 'ran_lint=%s\n' "$RAN_LINT"
    printf 'ran_typecheck=%s\n' "$RAN_TYPECHECK"
    printf 'ran_tests=%s\n' "$RAN_TESTS"
    printf 'log_file=%s\n' "$LOG_FILE"
  } >"$tmp"

  mv "$tmp" "$STATE_FILE"
}

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1
}

continuation_prompt() {
  printf 'Python quality gate needs attention. Continue the task before finalizing.\n\n'
  printf 'Reasons:\n'
  local reason
  for reason in "${BLOCK_REASONS[@]}"; do
    printf -- '- %s\n' "$reason"
  done
  printf '\nRequired next steps:\n'
  printf '1. Run `bash .codex/hooks/python-quality-gate/python-quality-gate.sh run-post-tool`.\n'
  printf '2. Fix failed formatter, lint, typecheck, or related pytest checks if any ran.\n'
  printf '3. Re-run the quality gate, then produce the final response.\n\n'
  printf 'Full log: `.codex-hook-state/python-quality-gate.log`\n'
}

emit_block_json() {
  local message="$1"
  local escaped
  escaped="$(printf '%s' "$message" | json_escape)"
  printf '{"decision":"block","reason":"%s","systemMessage":"%s"}\n' "$escaped" "$escaped"
}

json_escape() {
  awk 'BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      if (NR > 1) {
        printf "\\n"
      }
      printf "%s", $0
    }'
}

log_skipped() {
  local name="$1"
  local project_root="$2"
  local reason="$3"
  {
    printf '== %s ==\n' "$name"
    printf 'cwd: %s\n' "$project_root"
    printf 'command: <skipped>\n'
    printf 'skipped: %s\n' "$reason"
    printf 'exit_code: 127\n\n'
  } >>"$LOG_FILE"
}

update_check_code() {
  local key="$1"
  local code="$2"
  [[ "$code" -eq 0 ]] && return 0

  case "$key" in
    formatter)
      [[ "$CHECK_FORMATTER" -eq 0 ]] && CHECK_FORMATTER="$code"
      ;;
    lint)
      [[ "$CHECK_LINT" -eq 0 ]] && CHECK_LINT="$code"
      ;;
    typecheck)
      [[ "$CHECK_TYPECHECK" -eq 0 ]] && CHECK_TYPECHECK="$code"
      ;;
    tests)
      [[ "$CHECK_TESTS" -eq 0 ]] && CHECK_TESTS="$code"
      ;;
  esac
}

mark_check_ran() {
  local key="$1"
  case "$key" in
    formatter)
      RAN_FORMATTER=1
      ;;
    lint)
      RAN_LINT=1
      ;;
    typecheck)
      RAN_TYPECHECK=1
      ;;
    tests)
      RAN_TESTS=1
      ;;
  esac
}

is_ignored_python_path() {
  local rel_path="$1"
  case "$rel_path" in
    .git/*|.mypy_cache/*|.pytest_cache/*|.ruff_cache/*|.tox/*|.venv/*|*/.venv/*|*/__pycache__/*|node_modules/*|*/node_modules/*|.codex-hook-state/*)
      return 0
      ;;
  esac
  return 1
}

project_relative() {
  local project_root="$1"
  local absolute_path="$2"
  printf '%s\n' "${absolute_path#"$project_root"/}"
}

quote_command() {
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  else
    sha256sum "$path" | awk '{ print $1 }'
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    sha256sum | awk '{ print $1 }'
  fi
}

temporary_cache_root() {
  local digest
  digest="$(printf '%s' "$REPO_ROOT" | sha256_stdin | cut -c 1-16)"
  printf '%s/%s\n' "${CODEX_QUALITY_GATE_TMPDIR:-/private/tmp/codex-python-quality-gate}" "$digest"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

drain_stdin() {
  cat >/dev/null 2>&1 || true
}

main "$@"
