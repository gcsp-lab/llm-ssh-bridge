#!/bin/sh
# shellcheck shell=bash
# shellcheck source=_locale-bootstrap.sh
. "$(dirname "$0")/_locale-bootstrap.sh"

# Manage a manually authenticated bastion tmux session.

set -euo pipefail

CONFIG_FILE="${BASTION_CONFIG_FILE:-${HOME}/.ssh/bastion.env}"
SESSION="${BASTION_SESSION:-bastion}"
RUNTIME_DIR="${BASTION_RUNTIME_DIR:-${TMPDIR:-/tmp}/bastion-run}"
SPOOL_DIR="${BASTION_SPOOL_DIR:-${RUNTIME_DIR}/spool}"
SPOOL_RETENTION_MINUTES="${BASTION_SPOOL_RETENTION_MINUTES:-1440}"
DEFAULT_BASTION_HOST="${BASTION_DEFAULT_HOST:-example.com}"
DEFAULT_BASTION_PORT="${BASTION_DEFAULT_PORT:-22}"
DEFAULT_BASTION_USER="${BASTION_DEFAULT_USER:-${USER:-}}"
DEFAULT_BASTION_SSH_OPTIONS="${BASTION_DEFAULT_SSH_OPTIONS:-}"
BASTION_HOST="${BASTION_HOST:-}"
BASTION_PORT="${BASTION_PORT:-}"
BASTION_USER="${BASTION_USER:-}"
BASTION_SSH_OPTIONS="${BASTION_SSH_OPTIONS:-}"

usage() {
  cat <<EOF
Usage: $0 {up|attach|status|doctor|reset|down|clean|--help}

Commands:
  up             Start or attach the tmux bastion session
  attach         Attach an existing session
  status         Show local session status
  doctor         Check dependencies, config, session, and recent pane output
  reset          Stop the local tmux session, then start it again
  down           Stop the local tmux session
  clean [--all]  Remove old spool files, or all spool files with --all

Environment:
  BASTION_CONFIG_FILE             Default: ~/.ssh/bastion.env
  BASTION_SESSION                 Default: bastion
  BASTION_RUNTIME_DIR             Default: /tmp/bastion-run
  BASTION_SPOOL_DIR               Default: \$BASTION_RUNTIME_DIR/spool
  BASTION_SPOOL_RETENTION_MINUTES Default: 1440
  BASTION_DEFAULT_HOST            Default: ${DEFAULT_BASTION_HOST}
  BASTION_DEFAULT_PORT            Default: ${DEFAULT_BASTION_PORT}
  BASTION_DEFAULT_USER            Default: ${DEFAULT_BASTION_USER}
  BASTION_DEFAULT_SSH_OPTIONS     Default: ${DEFAULT_BASTION_SSH_OPTIONS}
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_deps() {
  local missing=0 cmd
  for cmd in tmux ssh awk sed date mktemp wc find tail; do
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

config_mode() {
  if stat -f '%Lp' "${CONFIG_FILE}" >/dev/null 2>&1; then
    stat -f '%Lp' "${CONFIG_FILE}"
  else
    stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || echo unknown
  fi
}

prompt_with_default() {
  local var_name="$1"
  local label="$2"
  local default_value="$3"
  local value=""

  printf '  %s [%s]: ' "${label}" "${default_value}"
  IFS= read -r value || value=""
  printf -v "${var_name}" '%s' "${value:-${default_value}}"
}

confirm_default_yes() {
  local label="$1"
  local value=""

  printf '%s [Y/n]: ' "${label}"
  IFS= read -r value || value=""
  case "${value}" in
    ""|y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

save_config() {
  mkdir -p "$(dirname "${CONFIG_FILE}")"
  umask 077
  cat > "${CONFIG_FILE}" <<EOF
BASTION_HOST="${BASTION_HOST}"
BASTION_PORT="${BASTION_PORT}"
BASTION_USER="${BASTION_USER}"
BASTION_SSH_OPTIONS="${BASTION_SSH_OPTIONS}"
EOF
  chmod 600 "${CONFIG_FILE}"
  echo "Saved ${CONFIG_FILE}."
}

configure_bastion() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    echo "Confirm bastion info; press Enter to keep each current value:"
  else
    echo "First run. Enter bastion info; it will be saved to ${CONFIG_FILE}:"
  fi

  prompt_with_default BASTION_HOST "Bastion host or IP" "${BASTION_HOST:-${DEFAULT_BASTION_HOST}}"
  prompt_with_default BASTION_PORT "Bastion port" "${BASTION_PORT:-${DEFAULT_BASTION_PORT}}"
  prompt_with_default BASTION_USER "Bastion user" "${BASTION_USER:-${DEFAULT_BASTION_USER}}"
  prompt_with_default BASTION_SSH_OPTIONS "Extra SSH options" "${BASTION_SSH_OPTIONS:-${DEFAULT_BASTION_SSH_OPTIONS}}"
  save_config
}

load_config() {
  configure_bastion
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
}

check_config() {
  local ok=0 mode

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "config: missing ${CONFIG_FILE}" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  if [[ -z "${BASTION_HOST:-}" ]]; then
    echo "config: BASTION_HOST is empty" >&2
    ok=1
  fi
  if [[ -z "${BASTION_USER:-}" ]]; then
    echo "config: BASTION_USER is empty" >&2
    ok=1
  fi
  if [[ ! "${BASTION_PORT:-22}" =~ ^[0-9]+$ ]]; then
    echo "config: BASTION_PORT must be numeric" >&2
    ok=1
  fi

  mode="$(config_mode)"
  if [[ "${mode}" != "600" && "${mode}" != "400" && "${mode}" != "unknown" ]]; then
    echo "config: ${CONFIG_FILE} mode is ${mode}; recommended 600" >&2
  fi

  return "${ok}"
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

show_status() {
  if session_exists; then
    echo "tmux ${SESSION}: active"
    tmux list-windows -t "${SESSION}" 2>/dev/null | sed 's/^/  /'
  else
    echo "tmux ${SESSION}: not running"
  fi
}

doctor() {
  local failed=0

  echo "Dependencies:"
  if check_deps; then
    echo "  ok"
  else
    echo "  failed"
    failed=1
  fi

  echo "Config:"
  if check_config; then
    echo "  ok: ${CONFIG_FILE}"
  else
    echo "  failed: ${CONFIG_FILE}"
    failed=1
  fi

  echo "Runtime:"
  if ensure_runtime_dirs; then
    echo "  ok: ${RUNTIME_DIR}"
    echo "  spool: ${SPOOL_DIR}"
  else
    echo "  failed to create runtime directories"
    failed=1
  fi

  echo "Session:"
  if need_cmd tmux && session_exists; then
    echo "  active: ${SESSION}"
    echo "Recent pane output:"
    tmux capture-pane -p -t "${SESSION}" -S -20 2>/dev/null | tail -20 | sed 's/^/  /' || true
  else
    echo "  not running: ${SESSION}"
  fi

  return "${failed}"
}

start_session() {
  check_deps

  if session_exists; then
    echo "tmux ${SESSION} already exists."
    if confirm_default_yes "Attach existing session"; then
      echo "After the target shell is ready, detach with Ctrl-b then d."
      sleep 1
      exec tmux attach -t "${SESSION}"
    fi
    echo "Restarting tmux ${SESSION}."
    tmux kill-session -t "${SESSION}"
  fi

  load_config
  ensure_runtime_dirs
  check_config

  local target="${BASTION_USER}@${BASTION_HOST}"
  local port="${BASTION_PORT:-22}"
  local ssh_options="${BASTION_SSH_OPTIONS:-}"
  local ssh_command

  echo "Starting ssh to ${target}:${port} inside tmux ${SESSION}."
  # Keepalive reduces silent connection drops (which otherwise force a fresh
  # password+OTP login). 30s probes, give up after ~2min of no response.
  local keepalive="-o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o TCPKeepAlive=yes"
  if [[ -n "${ssh_options}" ]]; then
    echo "Using extra SSH options: ${ssh_options}"
    ssh_command="TERM=xterm ssh ${keepalive} ${ssh_options} -p ${port} ${target}"
  else
    ssh_command="TERM=xterm ssh ${keepalive} -p ${port} ${target}"
  fi
  echo "Sequence: enter password, enter OTP if prompted, choose the target host."
  echo "After landing in the target shell, detach with Ctrl-b then d."
  sleep 1
  tmux new-session -d -s "${SESSION}" "${ssh_command}"
  tmux set-option -t "${SESSION}" mouse off
  exec tmux attach -t "${SESSION}"
}

cmd="${1:-up}"
case "${cmd}" in
  --help|-h|help)
    usage
    ;;
  up)
    start_session
    ;;
  attach)
    check_deps
    if ! session_exists; then
      echo "tmux ${SESSION} does not exist. Run: $0 up" >&2
      exit 1
    fi
    exec tmux attach -t "${SESSION}"
    ;;
  status)
    check_deps
    show_status
    ;;
  doctor)
    doctor
    ;;
  reset)
    check_deps
    if session_exists; then
      tmux kill-session -t "${SESSION}"
      echo "tmux ${SESSION} stopped."
    fi
    start_session
    ;;
  down)
    check_deps
    if session_exists; then
      tmux kill-session -t "${SESSION}"
      echo "tmux ${SESSION} stopped."
    else
      echo "No active session."
    fi
    ;;
  clean)
    shift || true
    clean_spools "$@"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
