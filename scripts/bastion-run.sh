#!/bin/sh
# shellcheck shell=bash
# shellcheck source=_locale-bootstrap.sh
. "$(dirname "$0")/_locale-bootstrap.sh"

# Execute one command through an already prepared bastion tmux session.

set -euo pipefail

SESSION="${BASTION_SESSION:-bastion}"
TIMEOUT="${BASTION_DEFAULT_TIMEOUT:-120}"
RUNTIME_DIR="${BASTION_RUNTIME_DIR:-${TMPDIR:-/tmp}/bastion-run}"
SPOOL_DIR="${BASTION_SPOOL_DIR:-${RUNTIME_DIR}/spool}"
SPOOL_RETENTION_MINUTES="${BASTION_SPOOL_RETENTION_MINUTES:-1440}"
LOCK_STALE_SECONDS="${BASTION_LOCK_STALE_SECONDS:-}"
KEEP_SUCCESS_LOGS="${BASTION_KEEP_SUCCESS_LOGS:-0}"
KEEP_FAILED_LOGS="${BASTION_KEEP_FAILED_LOGS:-1}"
NO_HOST_CHECK="${BASTION_NO_HOST_CHECK:-0}"
EXPECTED_HOST=""
PIN_FILE=""
LOCK_DIR=""
LOCK_OWNED=0
SPOOL_FILE=""
PIPE_ENABLED=0
START=""
END=""
CMD=""

usage() {
  cat <<EOF
Usage:
  $0 [options] '<command>'
  $0 pin
  $0 clean [--all]

Options:
  -t, --timeout SECONDS       Command timeout, default: 60
  -s, --session SESSION       tmux session name, default: bastion
      --spool-dir DIR         Spool directory, default: /tmp/bastion-run/spool
      --keep-log              Keep successful run spool file
      --no-keep-failed-log    Delete spool file even on failure or timeout
      --no-host-check         Skip the pinned-hostname guard for this run
  -h, --help                  Show this help

Environment:
  BASTION_SESSION
  BASTION_RUNTIME_DIR
  BASTION_SPOOL_DIR
  BASTION_SPOOL_RETENTION_MINUTES
  BASTION_LOCK_STALE_SECONDS    Defaults to TIMEOUT + 5
  BASTION_KEEP_SUCCESS_LOGS
  BASTION_KEEP_FAILED_LOGS      Default: 1
  BASTION_SKIP_PROMPT_CHECK     Set 1 to skip pre-paste prompt verification
  BASTION_PROMPT_TAIL_REGEX     Pane-tail regex marking a shell prompt
  BASTION_PIN_FILE              Default: ~/.ssh/bastion-pin-\${SESSION}
  BASTION_EXPECTED_HOSTNAME     Overrides pin file value
  BASTION_NO_HOST_CHECK         Set 1 to skip the hostname guard
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_deps() {
  local missing=0 cmd
  for cmd in tmux awk sed date mktemp wc tail find cat tr; do
    if ! need_cmd "${cmd}"; then
      echo "missing command: ${cmd}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

ensure_runtime_dirs() {
  mkdir -p "${RUNTIME_DIR}" "${SPOOL_DIR}"
}

clean_spools() {
  ensure_runtime_dirs
  if [[ "${1:-}" == "--all" ]]; then
    find "${SPOOL_DIR}" -type f -name 'run-*.log' -delete
    echo "Removed all bastion spool files from ${SPOOL_DIR}."
    return 0
  fi

  find "${SPOOL_DIR}" -type f -name 'run-*.log' -mmin +"${SPOOL_RETENTION_MINUTES}" -delete
  echo "Removed bastion spool files older than ${SPOOL_RETENTION_MINUTES} minutes from ${SPOOL_DIR}."
}

session_exists() {
  tmux has-session -t "${SESSION}" 2>/dev/null
}

write_lock_metadata() {
  printf '%s\n' "$(date +%s)" > "${LOCK_DIR}/created_at"
  printf '%s\n' "${BASHPID:-$$}" > "${LOCK_DIR}/pid"
}

acquire_lock() {
  LOCK_DIR="${RUNTIME_DIR}/lock-${SESSION}"
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    LOCK_OWNED=1
    write_lock_metadata
    return 0
  fi

  sleep 0.1

  local pid="" created_at="" now="" age=0
  [[ -f "${LOCK_DIR}/pid" ]] && pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  [[ -f "${LOCK_DIR}/created_at" ]] && created_at="$(cat "${LOCK_DIR}/created_at" 2>/dev/null || true)"
  now="$(date +%s)"
  if [[ "${created_at}" =~ ^[0-9]+$ && "${now}" -ge "${created_at}" ]]; then
    age=$((now - created_at))
  fi

  if { [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] || ! kill -0 "${pid}" 2>/dev/null; } \
    && { [[ -z "${created_at}" || ! "${created_at}" =~ ^[0-9]+$ ]] || [[ "${age}" -ge "${LOCK_STALE_SECONDS}" ]]; }; then
    echo "[bastion-run] Removing stale lock for tmux session ${SESSION}${pid:+, pid ${pid}}." >&2
    rm -rf "${LOCK_DIR}"
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      LOCK_OWNED=1
      write_lock_metadata
      return 0
    fi
    [[ -f "${LOCK_DIR}/pid" ]] && pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  fi

  echo "[bastion-run] tmux session ${SESSION} is busy${pid:+, lock pid ${pid}}." >&2
  echo "[bastion-run] Only one command can safely write to a bastion pane at a time." >&2
  exit 75
}

release_lock() {
  if [[ "${LOCK_OWNED}" == "1" && -n "${LOCK_DIR}" && -d "${LOCK_DIR}" ]]; then
    rm -rf "${LOCK_DIR}"
    LOCK_OWNED=0
  fi
}

disable_pipe() {
  if [[ "${PIPE_ENABLED}" == "1" ]]; then
    tmux pipe-pane -t "${SESSION}" 2>/dev/null || true
    PIPE_ENABLED=0
  fi
}

cleanup() {
  local rc=$?
  disable_pipe
  release_lock
  exec 3<&- 2>/dev/null || true

  if [[ -n "${SPOOL_FILE}" && -f "${SPOOL_FILE}" ]]; then
    if [[ "${rc}" -eq 0 && "${KEEP_SUCCESS_LOGS}" != "1" ]]; then
      rm -f "${SPOOL_FILE}"
    elif [[ "${rc}" -ne 0 && "${KEEP_FAILED_LOGS}" != "1" ]]; then
      rm -f "${SPOOL_FILE}"
    fi
  fi

  exit "${rc}"
}
trap cleanup EXIT INT TERM

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
  fi

  if [[ "${1:-}" == "clean" ]]; then
    shift
    check_deps
    clean_spools "$@"
    exit 0
  fi

  if [[ "${1:-}" == "pin" ]]; then
    shift
    pin_session "$@"
    exit $?
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -t|--timeout)
        [[ $# -ge 2 ]] || { echo "--timeout requires a value" >&2; exit 1; }
        TIMEOUT="$2"
        shift 2
        ;;
      --timeout=*)
        TIMEOUT="${1#*=}"
        shift
        ;;
      -s|--session)
        [[ $# -ge 2 ]] || { echo "--session requires a value" >&2; exit 1; }
        SESSION="$2"
        shift 2
        ;;
      --session=*)
        SESSION="${1#*=}"
        shift
        ;;
      --spool-dir)
        [[ $# -ge 2 ]] || { echo "--spool-dir requires a value" >&2; exit 1; }
        SPOOL_DIR="$2"
        shift 2
        ;;
      --spool-dir=*)
        SPOOL_DIR="${1#*=}"
        shift
        ;;
      --keep-log)
        KEEP_SUCCESS_LOGS=1
        shift
        ;;
      --no-keep-failed-log)
        KEEP_FAILED_LOGS=0
        shift
        ;;
      --no-host-check)
        NO_HOST_CHECK=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
  fi
  CMD="$*"

  if [[ ! "${TIMEOUT}" =~ ^[0-9]+$ || "${TIMEOUT}" -le 0 ]]; then
    echo "timeout must be a positive integer" >&2
    exit 1
  fi
}

make_nonce() {
  printf '%s-%s-%s-%s' "$$" "${RANDOM}" "${RANDOM}" "$(date +%s)"
}

pin_session() {
  local script_path host pin_file
  script_path="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  pin_file="${BASTION_PIN_FILE:-${HOME}/.ssh/bastion-pin-${SESSION}}"

  check_deps
  ensure_runtime_dirs

  if ! session_exists; then
    echo "[bastion-run] tmux session ${SESSION} does not exist. Run: ./scripts/bastion-up.sh up" >&2
    return 1
  fi

  echo "Probing remote hostname via tmux ${SESSION}..."
  host="$(BASTION_NO_HOST_CHECK=1 "${script_path}" -t 10 'hostname' 2>/dev/null | tail -1 | tr -d '[:space:]')"

  if [[ -z "${host}" ]]; then
    echo "[bastion-run] Failed to capture hostname. Is the pane at a shell prompt?" >&2
    return 1
  fi

  mkdir -p "$(dirname "${pin_file}")"
  umask 077
  printf '%s\n' "${host}" > "${pin_file}"
  chmod 600 "${pin_file}"
  echo "Pinned ${SESSION} to hostname: ${host}"
  echo "Pin file: ${pin_file}"
  return 0
}

make_spool_file() {
  local tmp_spool
  ensure_runtime_dirs
  clean_spools >/dev/null || true
  tmp_spool="$(mktemp "${SPOOL_DIR}/run-${SESSION}-XXXXXX")"
  SPOOL_FILE="${tmp_spool}.log"
  mv "${tmp_spool}" "${SPOOL_FILE}"
}

quote_for_remote_single() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

strip_control_stream() {
  local esc
  esc="$(printf '\033')"
  sed -E "s/${esc}\\[[0-9;?]*[ -/]*[@-~]//g" | tr -d '\000-\010\013\014\016-\037\177'
}

clean_text() {
  printf '%s' "$1" | strip_control_stream
}

verify_prompt_ready() {
  # Verify the tmux pane is at a shell prompt before pasting payload.
  # If the user left the pane in less/vim/a menu, pasting would corrupt state.
  [[ "${BASTION_SKIP_PROMPT_CHECK:-0}" == "1" ]] && return 0

  local pane_tail prompt_re
  pane_tail="$(tmux capture-pane -p -t "${SESSION}" 2>/dev/null | awk 'NF{line=$0} END{print line}' 2>/dev/null || true)"
  # If we can't read the pane (older tmux, capture-pane disabled), fall through.
  [[ -z "${pane_tail}" ]] && return 0

  prompt_re="${BASTION_PROMPT_TAIL_REGEX:-[\$#>%][[:space:]]*\$}"
  if [[ "${pane_tail}" =~ ${prompt_re} ]]; then
    return 0
  fi
  echo "[bastion-run] Pane does not look like a shell prompt." >&2
  echo "[bastion-run]   last line: ${pane_tail}" >&2
  echo "[bastion-run] Attach: tmux attach -t ${SESSION}, return to a shell prompt, detach (Ctrl-b d), and retry." >&2
  echo "[bastion-run] Override: BASTION_SKIP_PROMPT_CHECK=1, or set BASTION_PROMPT_TAIL_REGEX." >&2
  return 1
}

load_expected_host() {
  PIN_FILE="${BASTION_PIN_FILE:-${HOME}/.ssh/bastion-pin-${SESSION}}"
  if [[ "${NO_HOST_CHECK}" == "1" ]]; then
    EXPECTED_HOST=""
    return
  fi
  if [[ -n "${BASTION_EXPECTED_HOSTNAME:-}" ]]; then
    EXPECTED_HOST="${BASTION_EXPECTED_HOSTNAME}"
    return
  fi
  if [[ -r "${PIN_FILE}" ]]; then
    EXPECTED_HOST="$(head -1 "${PIN_FILE}" 2>/dev/null | tr -d '[:space:]')"
    return
  fi
  EXPECTED_HOST=""
}

send_payload() {
  local nonce nonce_q expected_q payload buffer_name spool_q
  local payload_head payload_check payload_body payload_tail cmd_b64
  nonce="$(make_nonce)"
  START="__BSTN_START_${nonce}__"
  END="__BSTN_END_${nonce}__"
  nonce_q="$(quote_for_remote_single "${nonce}")"
  expected_q="$(quote_for_remote_single "${EXPECTED_HOST}")"
  # base64-frame the command: paste a single fixed-shape line so quotes,
  # pipes, newlines and non-ASCII in the command can never corrupt the
  # interactive paste. Decoded and run on the remote.
  cmd_b64="$(printf '%s' "${CMD}" | base64 | tr -d '\n')"

  payload_head="__bstn_nonce='${nonce_q}'; __bstn_start=\"__BSTN_START_\${__bstn_nonce}__\"; __bstn_end=\"__BSTN_END_\${__bstn_nonce}__\"; __bstn_expected_host='${expected_q}'; case \$- in *e*) __bstn_had_errexit=1 ;; *) __bstn_had_errexit=0 ;; esac; set +e; export COMPOSE_PROGRESS=\"\${COMPOSE_PROGRESS:-plain}\" NO_COLOR=\"\${NO_COLOR:-1}\"; printf '\\n%s\\n' \"\$__bstn_start\";"
  payload_check="__bstn_actual_host=\"\$(hostname 2>/dev/null)\"; if [ -n \"\$__bstn_expected_host\" ] && [ \"\$__bstn_actual_host\" != \"\$__bstn_expected_host\" ]; then printf '[bastion-run] hostname mismatch: expected=%s actual=%s\\n' \"\$__bstn_expected_host\" \"\$__bstn_actual_host\" >&2; __rc=99; else"
  payload_body=" ( printf '%s' '${cmd_b64}' | base64 --decode | bash ); __rc=\$?; fi;"
  payload_tail=" if [[ \"\$__bstn_had_errexit\" == 1 ]]; then set -e; fi; printf '%s:%d\\n' \"\$__bstn_end\" \"\$__rc\""

  payload="${payload_head} ${payload_check}${payload_body}${payload_tail}"
  buffer_name="bastion-run-${nonce}"
  spool_q="$(printf '%q' "${SPOOL_FILE}")"

  tmux pipe-pane -t "${SESSION}" "cat >> ${spool_q}"
  PIPE_ENABLED=1
  tmux set-buffer -b "${buffer_name}" -- "${payload}"
  tmux paste-buffer -b "${buffer_name}" -t "${SESSION}"
  tmux delete-buffer -b "${buffer_name}" 2>/dev/null || true
  tmux send-keys -t "${SESSION}" Enter
}

recent_spool_tail() {
  if [[ -n "${SPOOL_FILE}" && -f "${SPOOL_FILE}" ]]; then
    tail -40 "${SPOOL_FILE}" 2>/dev/null | strip_control_stream | sed 's/^/  /' >&2 || true
  fi
}

parse_end_from_text() {
  local text clean line after rc started
  text="$1"
  clean="$(clean_text "${text}")"
  started=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ "${started}" == "0" ]]; then
      [[ "${line}" == "${START}" ]] && started=1
      continue
    fi

    if [[ "${line}" == *"${END}:"* ]]; then
      after="${line#*"${END}:"}"
      rc="${after%%[^0-9]*}"
      [[ -n "${rc}" ]] || return 70
      printf '%s\n' "${rc}"
      return 0
    fi
  done <<< "${clean}"

  return 1
}

recover_pane() {
  local attempt max_attempts prompt_re pane_tail
  max_attempts="${BASTION_RECOVER_ATTEMPTS:-5}"
  prompt_re="${BASTION_PROMPT_TAIL_REGEX:-[\$#>%][[:space:]]*\$}"

  echo "[bastion-run] Attempting pane recovery (Ctrl-C + wait prompt)..." >&2
  for attempt in $(seq 1 "${max_attempts}"); do
    tmux send-keys -t "${SESSION}" C-c 2>/dev/null || true
    sleep 1.5
    pane_tail="$(tmux capture-pane -p -t "${SESSION}" 2>/dev/null \
      | awk 'NF{line=$0} END{print line}' 2>/dev/null || true)"
    if [[ -n "${pane_tail}" ]] && [[ "${pane_tail}" =~ ${prompt_re} ]]; then
      echo "[bastion-run] Pane recovered after ${attempt} attempt(s)." >&2
      return 0
    fi
  done
  echo "[bastion-run] Pane recovery failed after ${max_attempts} attempts." >&2
  echo "[bastion-run] Attach manually: tmux attach -t ${SESSION}" >&2
  return 1
}

stream_until_end() {
  local deadline chunk buffer line clean_line started rc before
  deadline=$(( $(date +%s) + TIMEOUT ))
  buffer=""
  started=0
  rc=""

  exec 3< "${SPOOL_FILE}"

  while (( $(date +%s) < deadline )); do
    chunk=""
    IFS= read -r -d '' chunk < <(cat <&3; printf '\0') || true
    if [[ -n "${chunk}" ]]; then
      buffer="${buffer}${chunk}"

      while [[ "${buffer}" == *$'\n'* ]]; do
        line="${buffer%%$'\n'*}"
        buffer="${buffer#*$'\n'}"
        line="${line%$'\r'}"
        clean_line="$(clean_text "${line}")"

        if [[ "${started}" == "0" ]]; then
          if [[ "${clean_line}" == "${START}" ]]; then
            started=1
            continue
          else
            continue
          fi
        fi

        if [[ "${clean_line}" == *"${END}:"* ]]; then
          before="${clean_line%%"${END}:"*}"
          [[ -n "${before}" ]] && printf '%s\n' "${before}"
          rc="${clean_line#*"${END}:"}"
          rc="${rc%%[^0-9]*}"
          if [[ -z "${rc}" ]]; then
            echo "[bastion-run] Found END sentinel but could not parse rc." >&2
            echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
            return 70
          fi
          return "${rc}"
        fi

        [[ -n "${clean_line}" ]] && printf '%s\n' "${clean_line}"
      done

      if [[ "${started}" == "1" && "${buffer}" == *"${END}"* ]]; then
        clean_line="$(clean_text "${buffer}")"
        if [[ "${clean_line}" == *"${END}:"* ]]; then
          before="${clean_line%%"${END}:"*}"
          [[ -n "${before}" ]] && printf '%s\n' "${before}"
          rc="${clean_line#*"${END}:"}"
          rc="${rc%%[^0-9]*}"
          if [[ -z "${rc}" ]]; then
            echo "[bastion-run] Found END sentinel but could not parse rc." >&2
            echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
            return 70
          fi
          return "${rc}"
        fi
      fi
    fi
    sleep 0.1
  done

  if rc="$(parse_end_from_text "$(cat "${SPOOL_FILE}" 2>/dev/null || true)")"; then
    return "${rc}"
  elif [[ "$?" -eq 70 ]]; then
    echo "[bastion-run] Found END sentinel but could not parse rc." >&2
    echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
    return 70
  fi

  echo "[bastion-run] Timed out after ${TIMEOUT}s before seeing END sentinel." >&2
  echo "[bastion-run] Session: ${SESSION}" >&2
  echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
  echo "[bastion-run] Recent spool output:" >&2
  recent_spool_tail
  disable_pipe
  recover_pane || true
  return 124
}

main() {
  parse_args "$@"
  check_deps
  ensure_runtime_dirs

  [[ -n "${LOCK_STALE_SECONDS}" ]] || LOCK_STALE_SECONDS=$((TIMEOUT + 5))
  load_expected_host

  acquire_lock
  if ! session_exists; then
    echo "[bastion-run] tmux session ${SESSION} does not exist." >&2
    echo "[bastion-run] Start and prepare it with: ./scripts/bastion-up.sh up" >&2
    exit 1
  fi
  verify_prompt_ready || exit 1
  make_spool_file
  send_payload
  stream_until_end
}

main "$@"
