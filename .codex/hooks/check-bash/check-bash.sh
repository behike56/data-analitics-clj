#!/usr/bin/env bash
#
# Bash 安全性を補強する Codex 共通 PreToolUse hook。
#
# allowlist や default deny は実装しません。Codex の sandbox、approval_policy、
# .rules を主たる権限レイヤーとし、このスクリプトは静的な execpolicy rule を
# すり抜けやすい Bash パターンだけをブロックします。

set -u

CHECK_BASH_LOG="${CHECK_BASH_LOG:-${HOME}/.codex/logs/bash-audit.log}"
CHECK_BASH_DEBUG="${CHECK_BASH_DEBUG:-0}"
CHECK_BASH_DRY_RUN="${CHECK_BASH_DRY_RUN:-0}"

COMMAND=""
CWD=""

debug() {
  [[ "$CHECK_BASH_DEBUG" == "1" ]] || return 0
  printf '[check-bash] %s\n' "$*" >&2
}

log_event() {
  local decision="$1"
  local detail="$2"
  local command="$3"
  local log_dir

  log_dir="$(dirname "$CHECK_BASH_LOG")"
  mkdir -p "$log_dir" 2>/dev/null || true
  {
    printf '%s\t%s\t%s\tcmd=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$decision" "$detail" "$command" >>"$CHECK_BASH_LOG"
  } 2>/dev/null || true
  debug "$decision: $detail"
}

emit_deny() {
  local reason="$1"
  local decision="deny"

  if [[ "$CHECK_BASH_DRY_RUN" == "1" ]]; then
    log_event "dry-run" "would-deny: $reason" "$COMMAND"
    return 0
  fi

  log_event "$decision" "$reason" "$COMMAND"
  jq -cn \
    --arg reason "$reason" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  exit 0
}

contains_match() {
  local text="$1"
  local pattern="$2"
  printf '%s\n' "$text" | grep -Eiq -- "$pattern"
}

trim_text() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

normalize_path() {
  local base="$1"
  local path="$2"
  local combined=""
  local old_ifs=""
  local part=""
  local parts=()
  local stack=()

  case "$path" in
    /*)
      combined="$path"
      ;;
    *)
      combined="${base%/}/$path"
      ;;
  esac

  old_ifs="$IFS"
  IFS='/'
  read -r -a parts <<<"$combined"
  IFS="$old_ifs"

  for part in "${parts[@]}"; do
    case "$part" in
      ""|".")
        ;;
      "..")
        if [[ ${#stack[@]} -gt 0 ]]; then
          stack=("${stack[@]:0:${#stack[@]}-1}")
        fi
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  if [[ ${#stack[@]} -eq 0 ]]; then
    printf '/'
    return 0
  fi

  printf '/%s' "${stack[@]}" | sed 's# /#/#g'
}

is_forbidden_output_path() {
  local path="$1"

  case "$path" in
    */.env|*/.env.*|*/secrets/*|*/credentials/*|*/.aws/credentials|*/.ssh/id_*|*.pem|*.key|*.p12|*.pfx|*.jks)
      return 0
      ;;
    */.claude/settings.json|*/.claude/settings.local.json)
      return 0
      ;;
    */.claude/hooks|*/.claude/hooks/*|*/.claude/rules|*/.claude/rules/*)
      return 0
      ;;
    */.codex/hooks.json|*/.codex/config.toml|*/.codex/settings.json|*/.codex/settings.local.json)
      return 0
      ;;
    */.codex/hooks|*/.codex/hooks/*|*/.codex/rules|*/.codex/rules/*|*/.codex/skills|*/.codex/skills/*)
      return 0
      ;;
  esac

  return 1
}

validate_redirect_target() {
  local target="$1"
  local base="$2"
  local normalized=""

  [[ -n "$target" ]] || return 1
  [[ "$target" =~ [[:space:]] ]] && return 1
  [[ "$target" =~ [\*\?\[] ]] && return 1

  case "$target" in
    *[\$\'\"\`\;\&\|\<\>\(\)\{\}]*|~*)
      return 1
      ;;
  esac

  normalized="$(normalize_path "$base" "$target")"
  if is_forbidden_output_path "$normalized"; then
    return 1
  fi

  return 0
}

check_redirects() {
  local command="$1"
  local cwd="$2"
  local rest="$command"
  local matched=""
  local token=""

  while [[ "$rest" =~ (^|[^0-9])(\>\>|\>)[[:space:]]*([^[:space:];&|<>]+) ]]; do
    matched="${BASH_REMATCH[0]}"
    token="${BASH_REMATCH[3]}"
    if ! validate_redirect_target "$token" "$cwd"; then
      emit_deny "Output redirection to protected or non-literal paths is blocked."
    fi
    rest="${rest#*"$matched"}"
  done
}

check_deny_patterns() {
  local command="$1"
  local security_target='([^[:space:]]*/)?\.(claude|codex)/(settings(\.local)?\.json|hooks\.json|config\.toml|hooks(/|$)|rules(/|$)|skills(/|$))'
  local secret_readers='(cat|less|more|head|tail|bat|awk|sed|xxd|od|hexdump|strings|grep|rg|tac|nl|cut|sort)'

  # Shell 構文のうち、静的 permission rule をすり抜けやすい展開・分岐・バックグラウンド実行を止める。
  if contains_match "$command" '\$\(|`'; then
    emit_deny "Command substitution is blocked. Run a single command without shell expansion."
  fi

  if contains_match "$command" '(^|[^|])\|\|([^|]|$)'; then
    emit_deny "Logical OR shell chaining is blocked."
  fi

  if contains_match "$command" '(^|[^&])&([^&]|$)'; then
    emit_deny "Background execution with & is blocked."
  fi

  # Claude/Codex の設定・hook・rules・skills を Bash 経由で自己改変する経路を止める。
  if contains_match "$command" '(^|[^a-zA-Z_])(tee|cp|mv|install|truncate)[[:space:]][^|;&]*["'\'']?'"${security_target}"; then
    emit_deny "Bash file mutation targeting assistant configuration is blocked."
  fi

  if contains_match "$command" '(^|[^a-zA-Z_])dd[[:space:]][^|;&]*of=["'\'']?'"${security_target}"; then
    emit_deny "dd writes to assistant configuration are blocked."
  fi

  if contains_match "$command" '(^|[^a-zA-Z_])(sed|perl)[[:space:]][^|;&]*(-i|-pi)[^|;&]*["'\'']?'"${security_target}"; then
    emit_deny "In-place edits to assistant configuration from Bash are blocked."
  fi

  # Git 履歴の破壊、隠れた force push、任意コード実行につながる Git 設定改変を止める。
  if contains_match "$command" 'git[[:space:]]+push[[:space:]].*[[:space:]][+][A-Za-z0-9_./:-]+([[:space:]]|$)'; then
    emit_deny "Hidden force-push via +refspec syntax is blocked."
  fi

  if contains_match "$command" 'git[[:space:]]+(filter-branch|filter-repo|update-ref|reflog[[:space:]]+expire)([[:space:]]|$)'; then
    emit_deny "Git history rewrite commands are blocked."
  fi

  if contains_match "$command" 'git[[:space:]]+config([[:space:]]+--(global|system|local))*[[:space:]]+(core\.hookspath|alias\.|user\.signingkey|gpg\.program|credential\.helper)'; then
    emit_deny "Sensitive git config modification is blocked."
  fi

  # OS やホームディレクトリに対する復旧困難な破壊操作を止める。
  if contains_match "$command" 'rm[[:space:]]+(-[a-zA-Z]*[rRf][a-zA-Z]*[[:space:]]+)+(/|~|\$HOME|/(usr|etc|var|opt|bin|sbin|lib|home|boot|root))([[:space:]/]|$)'; then
    emit_deny "Recursive delete on system or home directory is blocked."
  fi

  if contains_match "$command" 'rm[[:space:]].*--no-preserve-root'; then
    emit_deny "--no-preserve-root is blocked."
  fi

  if contains_match "$command" 'dd[[:space:]].*of=/dev/(sd|nvme|hd|disk|rdisk|xvd|loop)'; then
    emit_deny "dd to a block device is blocked."
  fi

  if contains_match "$command" ':\(\)[[:space:]]*\{[[:space:]]*:\|:&'; then
    emit_deny "Fork bomb pattern is blocked."
  fi

  if contains_match "$command" '(^|[^a-zA-Z])mkfs(\.[a-z0-9]+)?[[:space:]]'; then
    emit_deny "Filesystem creation commands are blocked."
  fi

  if contains_match "$command" '(^|[^a-zA-Z])(shutdown|reboot|halt|poweroff)([[:space:]]|$)'; then
    emit_deny "System shutdown commands are blocked."
  fi

  # シークレット、秘密鍵、OS 認証情報を Bash の読み取り系コマンドで直接読む経路を止める。
  if contains_match "$command" "(^|[^a-zA-Z_])${secret_readers}[[:space:]][^|;&]*\\.env(\\.(local|production|prod|staging|stage|dev|development|test|secret|secrets))?([[:space:]]|$)"; then
    emit_deny "Reading .env files from Bash is blocked."
  fi

  if contains_match "$command" "(^|[^a-zA-Z_])${secret_readers}[[:space:]][^|;&]*(id_rsa|id_ed25519|id_ecdsa|id_dsa)([[:space:]]|$)"; then
    emit_deny "Reading SSH private keys from Bash is blocked."
  fi

  if contains_match "$command" "(^|[^a-zA-Z_])${secret_readers}[[:space:]][^|;&]*\\.aws/credentials"; then
    emit_deny "Reading AWS credentials from Bash is blocked."
  fi

  if contains_match "$command" "(^|[^a-zA-Z_])${secret_readers}[[:space:]][^|;&]*/etc/(shadow|gshadow)"; then
    emit_deny "Reading shadow files from Bash is blocked."
  fi

  # クラウドメタデータやリモート取得コードの即時実行など、外部入力からの権限昇格経路を止める。
  if contains_match "$command" '169\.254\.169\.254|metadata\.(google\.internal|azure\.com)'; then
    emit_deny "Cloud metadata endpoint access is blocked."
  fi

  if contains_match "$command" '(curl|wget)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|;&]*\|[[:space:]]*(sh|bash|zsh|fish|ksh)([[:space:]]|$)'; then
    emit_deny "Pipe-to-shell pattern is blocked. Download, inspect, then execute."
  fi

  if contains_match "$command" 'base64[[:space:]]+(-d|--decode|-D)[[:space:]].*\|[[:space:]]*(sh|bash|zsh|eval|exec)'; then
    emit_deny "Obfuscated execution via base64 decode is blocked."
  fi

  # ファイル権限や find の副作用 action による権限昇格・大量破壊を止める。
  if contains_match "$command" 'chmod[[:space:]]+([ugoa]*[+=][^[:space:]]*s|[0-7]?[2467][0-7]{3})[[:space:]]'; then
    emit_deny "SUID/SGID permission changes are blocked."
  fi

  if contains_match "$command" '(^|[^a-zA-Z])find[[:space:]].*[[:space:]]-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)([[:space:]]|$)'; then
    emit_deny "Destructive find actions are blocked. Use read-only find predicates."
  fi
}

main() {
  local input=""
  local tool_name=""
  local effective_cwd=""

  if ! command -v jq >/dev/null 2>&1; then
    debug "jq is not available; failing open"
    exit 0
  fi

  input="$(cat)"
  tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)"
  [[ "$tool_name" == "Bash" ]] || exit 0

  COMMAND="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
  CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)"
  COMMAND="$(trim_text "$COMMAND")"
  [[ -n "$COMMAND" ]] || exit 0

  effective_cwd="$CWD"
  if [[ -z "$effective_cwd" || "$effective_cwd" == "null" ]]; then
    effective_cwd="$(pwd)"
  fi

  log_event "check" "cwd=$effective_cwd" "$COMMAND"
  check_redirects "$COMMAND" "$effective_cwd"
  check_deny_patterns "$COMMAND"

  exit 0
}

main "$@"
