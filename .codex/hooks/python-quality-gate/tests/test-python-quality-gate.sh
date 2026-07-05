#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../python-quality-gate.sh"

PASS=0
FAIL=0
TMP_ROOT="${TMPDIR:-/private/tmp}/codex-python-quality-gate-tests.$$"

mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local desc="$3"
  case "$haystack" in
    *"$needle"*)
      ok "$desc"
      ;;
    *)
      not_ok "$desc"
      printf '  expected to contain: %s\n' "$needle"
      printf '  actual: %s\n' "$haystack"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local desc="$3"
  case "$haystack" in
    *"$needle"*)
      not_ok "$desc"
      printf '  expected not to contain: %s\n' "$needle"
      printf '  actual: %s\n' "$haystack"
      ;;
    *)
      ok "$desc"
      ;;
  esac
}

assert_empty() {
  local value="$1"
  local desc="$2"
  if [[ -z "$value" ]]; then
    ok "$desc"
  else
    not_ok "$desc"
    printf '  actual: %s\n' "$value"
  fi
}

new_repo() {
  local repo="$TMP_ROOT/repo-$1"
  mkdir -p "$repo/src/example" "$repo/tests"
  (
    cd "$repo" || exit 1
    git init >/dev/null
    printf '[project]\nname = "example"\nversion = "0.1.0"\n' >pyproject.toml
    printf 'def value():\n    return 1\n' >src/example/feature.py
    printf 'from example.feature import value\n\n\ndef test_value():\n    assert value() == 1\n' >tests/test_feature.py
  )
  printf '%s\n' "$repo"
}

commit_repo() {
  local repo="$1"
  (
    cd "$repo" || exit 1
    git add . >/dev/null
    git -c user.name='Test User' -c user.email='test@example.com' -c commit.gpgsign=false commit -m initial >/dev/null
  )
}

post_edit_input() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"
}

post_patch_input() {
  printf '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\\n*** %s File: %s\\n*** End Patch\\n"}}' "$1" "$2"
}

fake_tools() {
  local bin_dir="$1"
  local pytest_code="$2"
  mkdir -p "$bin_dir"

  make_fake_tool "$bin_dir/ruff" 0
  make_fake_tool "$bin_dir/mypy" 0
  make_fake_tool "$bin_dir/pytest" "$pytest_code"
}

make_fake_tool() {
  local path="$1"
  local code="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "fake %s %%s\\n" "$*" >&2\n' "$(basename "$path")"
    printf 'exit %s\n' "$code"
  } >"$path"
  chmod +x "$path"
}

test_missing_state_blocks() {
  local repo
  repo="$(new_repo missing-state)"
  mkdir -p "$repo/.codex-hook-state"
  printf '%s|src/example/feature.py\n' "$repo" >"$repo/.codex-hook-state/python-quality-gate.files"

  local output
  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_contains "$output" '"decision":"block"' "stop blocks when code changed without quality result"
  assert_contains "$output" 'no quality gate result' "stop explains missing quality result"
}

test_passed_gate_allows_stop() {
  local repo bin_dir output
  repo="$(new_repo passed)"
  bin_dir="$TMP_ROOT/bin-passed"
  fake_tools "$bin_dir" 0

  output="$(cd "$repo" && PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool 2>&1)"
  assert_contains "$output" 'recorded passed' "post-tool records passed state"

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_empty "$output" "stop allows fresh green quality result"
}

test_stale_state_blocks() {
  local repo bin_dir output
  repo="$(new_repo stale)"
  bin_dir="$TMP_ROOT/bin-stale"
  fake_tools "$bin_dir" 0

  (cd "$repo" && PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)
  printf 'def value():\n    return 2\n' >"$repo/src/example/feature.py"

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_contains "$output" 'stale' "stop blocks stale quality result"
}

test_failed_tests_block() {
  local repo bin_dir output
  repo="$(new_repo failed-tests)"
  bin_dir="$TMP_ROOT/bin-failed-tests"
  fake_tools "$bin_dir" 1

  (cd "$repo" && PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_contains "$output" 'test failure log exists' "stop blocks failed pytest result"
}

test_missing_tools_do_not_block_distribution_default() {
  local repo output
  repo="$(new_repo missing-tools)"

  output="$(cd "$repo" && PATH="/usr/bin:/bin" bash "$HOOK" run-post-tool 2>&1)"
  assert_contains "$output" 'recorded passed' "missing tools are skipped for common distribution"

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_empty "$output" "stop allows skipped checks when no tool is available"
}

test_scoped_post_tool_ignores_unrelated_dirty_python() {
  local repo bin_dir output
  repo="$(new_repo scoped-unrelated)"
  bin_dir="$TMP_ROOT/bin-scoped-unrelated"
  fake_tools "$bin_dir" 0

  output="$(cd "$repo" && post_edit_input src/example/feature.py | PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool 2>&1)"
  assert_contains "$output" 'recorded passed' "post-tool records scoped Python edit"

  printf 'def unrelated():\n    return 99\n' >"$repo/src/example/unrelated.py"

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_empty "$output" "stop ignores unrelated dirty Python outside active scope"
}

test_consecutive_post_tool_merges_scope_and_blocks_stale_file() {
  local repo bin_dir output
  repo="$(new_repo scoped-merge)"
  bin_dir="$TMP_ROOT/bin-scoped-merge"
  fake_tools "$bin_dir" 0

  (cd "$repo" && post_edit_input src/example/feature.py | PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)
  printf 'def other():\n    return 2\n' >"$repo/src/example/other.py"
  (cd "$repo" && post_edit_input src/example/other.py | PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)

  printf 'def value():\n    return 3\n' >"$repo/src/example/feature.py"

  output="$(cd "$repo" && printf '{}' | bash "$HOOK" stop)"
  assert_contains "$output" 'stale' "stop blocks stale result for merged active scope"
}

test_manual_run_post_tool_keeps_all_dirty_python_scope() {
  local repo bin_dir files
  repo="$(new_repo manual-all-dirty)"
  bin_dir="$TMP_ROOT/bin-manual-all-dirty"
  fake_tools "$bin_dir" 0
  printf 'def unrelated():\n    return 99\n' >"$repo/src/example/unrelated.py"

  (cd "$repo" && PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)

  files="$(cat "$repo/.codex-hook-state/python-quality-gate.files")"
  assert_contains "$files" 'src/example/feature.py' "manual post-tool includes existing dirty Python"
  assert_contains "$files" 'src/example/unrelated.py' "manual post-tool includes unrelated dirty Python"
}

test_deleted_python_file_runs_project_checks_without_deleted_formatter_target() {
  local repo bin_dir log
  repo="$(new_repo deleted-python)"
  commit_repo "$repo"
  bin_dir="$TMP_ROOT/bin-deleted-python"
  fake_tools "$bin_dir" 0

  rm "$repo/src/example/feature.py"
  (cd "$repo" && post_patch_input Delete src/example/feature.py | PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)

  log="$(cat "$repo/.codex-hook-state/python-quality-gate.log")"
  assert_not_contains "$log" 'ruff format --check src/example/feature.py' "formatter does not receive deleted Python file"
  assert_not_contains "$log" 'ruff check src/example/feature.py' "lint does not receive deleted Python file"
  assert_contains "$log" '== typecheck ==' "typecheck section is recorded for deleted Python file"
  assert_contains "$log" 'fake pytest -q tests' "tests fallback to tests for deleted Python file"
}

test_test_helper_change_falls_back_to_all_tests() {
  local repo bin_dir log
  repo="$(new_repo helper-fallback)"
  mkdir -p "$repo/tests/helpers"
  printf 'def fake():\n    return 1\n' >"$repo/tests/helpers/fakes.py"
  bin_dir="$TMP_ROOT/bin-helper-fallback"
  fake_tools "$bin_dir" 0

  (cd "$repo" && post_edit_input tests/helpers/fakes.py | PATH="$bin_dir:$PATH" bash "$HOOK" run-post-tool >/dev/null 2>&1)

  log="$(cat "$repo/.codex-hook-state/python-quality-gate.log")"
  assert_contains "$log" 'fake pytest -q tests' "test helper changes fall back to full tests"
}

test_missing_state_blocks
test_passed_gate_allows_stop
test_stale_state_blocks
test_failed_tests_block
test_missing_tools_do_not_block_distribution_default
test_scoped_post_tool_ignores_unrelated_dirty_python
test_consecutive_post_tool_merges_scope_and_blocks_stale_file
test_manual_run_post_tool_keeps_all_dirty_python_scope
test_deleted_python_file_runs_project_checks_without_deleted_formatter_target
test_test_helper_change_falls_back_to_all_tests

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
