#!/usr/bin/env bash
# Execute one command through an already prepared bastion tmux session.

set -euo pipefail

SESSION="${BASTION_SESSION:-bastion}"
TIMEOUT=60
RUNTIME_DIR="${BASTION_RUNTIME_DIR:-${TMPDIR:-/tmp}/bastion-run}"
SPOOL_DIR="${BASTION_SPOOL_DIR:-${RUNTIME_DIR}/spool}"
SPOOL_RETENTION_MINUTES="${BASTION_SPOOL_RETENTION_MINUTES:-1440}"
KEEP_SUCCESS_LOGS="${BASTION_KEEP_SUCCESS_LOGS:-0}"
KEEP_FAILED_LOGS=1
LOCK_DIR=""
SPOOL_FILE=""
PIPE_ENABLED=0
START=""
END=""
CMD=""

usage() {
  cat <<EOF
Usage:
  $0 [options] '<command>'
  $0 clean [--all]

Options:
  -t, --timeout SECONDS       Command timeout, default: 60
  -s, --session SESSION       tmux session name, default: bastion
      --spool-dir DIR         Spool directory, default: /tmp/bastion-run/spool
      --keep-log              Keep successful run spool file
      --no-keep-failed-log    Delete spool file even on failure or timeout
  -h, --help                  Show this help

Environment:
  BASTION_SESSION
  BASTION_RUNTIME_DIR
  BASTION_SPOOL_DIR
  BASTION_SPOOL_RETENTION_MINUTES
  BASTION_KEEP_SUCCESS_LOGS
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_deps() {
  local missing=0 cmd
  for cmd in tmux awk sed date mktemp wc tail find cat; do
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

acquire_lock() {
  LOCK_DIR="${RUNTIME_DIR}/lock-${SESSION}"
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    return 0
  fi

  local pid=""
  [[ -f "${LOCK_DIR}/pid" ]] && pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  echo "[bastion-run] tmux session ${SESSION} is busy${pid:+, lock pid ${pid}}." >&2
  echo "[bastion-run] Only one command can safely write to a bastion pane at a time." >&2
  exit 75
}

release_lock() {
  if [[ -n "${LOCK_DIR}" && -d "${LOCK_DIR}" ]]; then
    rm -rf "${LOCK_DIR}"
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

send_payload() {
  local nonce start_q end_q payload buffer_name spool_q
  nonce="$(make_nonce)"
  START="__BSTN_START_${nonce}__"
  END="__BSTN_END_${nonce}__"
  start_q="$(quote_for_remote_single "${START}")"
  end_q="$(quote_for_remote_single "${END}")"

  payload="case \$- in *e*) __bstn_had_errexit=1 ;; *) __bstn_had_errexit=0 ;; esac; set +e; printf '\\n%s\\n' '${start_q}'; ( ${CMD} ); __rc=\$?; if [[ \"\$__bstn_had_errexit\" == 1 ]]; then set -e; fi; printf '%s:%d\\n' '${end_q}' \"\$__rc\""
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
    tail -40 "${SPOOL_FILE}" 2>/dev/null | sed 's/^/  /' >&2 || true
  fi
}

stream_until_end() {
  local deadline offset size chunk buffer line started rc
  deadline=$(( $(date +%s) + TIMEOUT ))
  offset=0
  buffer=""
  started=0
  rc=""

  while (( $(date +%s) < deadline )); do
    size="$(wc -c < "${SPOOL_FILE}" | awk '{print $1}')"
    if [[ "${size}" -gt "${offset}" ]]; then
      chunk=""
      IFS= read -r -d '' chunk < <(tail -c +"$((offset + 1))" "${SPOOL_FILE}"; printf '\0')
      offset="${size}"
      buffer="${buffer}${chunk}"

      while [[ "${buffer}" == *$'\n'* ]]; do
        line="${buffer%%$'\n'*}"
        buffer="${buffer#*$'\n'}"
        line="${line%$'\r'}"

        if [[ "${started}" == "0" ]]; then
          if [[ "${line}" == "${START}" ]]; then
            started=1
          fi
          continue
        fi

        if [[ "${line}" == "${END}:"* ]]; then
          rc="${line#${END}:}"
          rc="${rc%%[^0-9]*}"
          if [[ -z "${rc}" ]]; then
            echo "[bastion-run] Found END sentinel but could not parse rc." >&2
            echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
            return 70
          fi
          return "${rc}"
        fi

        printf '%s\n' "${line}"
      done
    fi
    sleep 0.1
  done

  echo "[bastion-run] Timed out after ${TIMEOUT}s before seeing END sentinel." >&2
  echo "[bastion-run] Session: ${SESSION}" >&2
  echo "[bastion-run] Spool retained: ${SPOOL_FILE}" >&2
  echo "[bastion-run] Recent spool output:" >&2
  recent_spool_tail
  return 124
}

main() {
  parse_args "$@"
  check_deps
  ensure_runtime_dirs

  if ! session_exists; then
    echo "[bastion-run] tmux session ${SESSION} does not exist." >&2
    echo "[bastion-run] Start and prepare it with: ./scripts/bastion-up.sh up" >&2
    exit 1
  fi

  acquire_lock
  make_spool_file
  send_payload
  stream_until_end
}

main "$@"
