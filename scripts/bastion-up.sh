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
PROFILES_DIR="${BASTION_PROFILES_DIR:-${HOME}/.ssh/bastion-profiles}"
LAST_PROFILE_FILE="${BASTION_LAST_PROFILE_FILE:-${HOME}/.ssh/bastion-last-profile}"
ACTIVE_SESSION_FILE="${BASTION_ACTIVE_SESSION_FILE:-${HOME}/.ssh/bastion-active-session}"
PROFILE_LABEL=""
PROFILE_SESSION=""

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

# --- Named connection profiles ------------------------------------------------
# Each profile is ~/.ssh/bastion-profiles/<session>.env holding a display
# LABEL, a tmux SESSION id, and the bastion host/port/user/ssh_options.
# `up` lets you pick one (default = last used) and connect straight away.

slugify() {
  # name -> ascii tmux/file-safe id (Chinese etc. stripped -> caller falls back)
  printf '%s' "${1:-}" | LC_ALL=C tr ' /\\:.@' '------' | LC_ALL=C tr -cd 'A-Za-z0-9_-' \
    | sed -e 's/^-*//' -e 's/-*$//' | cut -c1-40
}

write_profile_file() {
  # args: slug label host port user ssh_options
  local slug="$1" label="$2" host="$3" port="$4" user="$5" opts="$6"
  mkdir -p "${PROFILES_DIR}"
  umask 077
  cat > "${PROFILES_DIR}/${slug}.env" <<EOF
BASTION_LABEL="${label}"
BASTION_SESSION="${slug}"
BASTION_HOST="${host}"
BASTION_PORT="${port}"
BASTION_USER="${user}"
BASTION_SSH_OPTIONS="${opts}"
EOF
  chmod 600 "${PROFILES_DIR}/${slug}.env"
}

remember_active() {
  # args: slug session
  printf '%s\n' "$1" > "${LAST_PROFILE_FILE}" 2>/dev/null || true
  printf '%s\n' "$2" > "${ACTIVE_SESSION_FILE}" 2>/dev/null || true
  chmod 600 "${LAST_PROFILE_FILE}" "${ACTIVE_SESSION_FILE}" 2>/dev/null || true
}

load_profile() {
  local slug="$1"
  local file="${PROFILES_DIR}/${slug}.env"
  if [[ ! -r "${file}" ]]; then
    echo "profile not found: ${slug}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${file}"
  SESSION="${BASTION_SESSION:-${slug}}"
  remember_active "${slug}" "${SESSION}"
}

create_profile() {
  echo "New profile:"
  prompt_with_default PROFILE_LABEL "  Display name" "${DEFAULT_BASTION_HOST}"
  local suggested
  suggested="$(slugify "${PROFILE_LABEL}")"
  [[ -n "${suggested}" ]] || suggested="cluster"
  prompt_with_default PROFILE_SESSION "  Session id (ascii, tmux/file name)" "${suggested}"
  PROFILE_SESSION="$(slugify "${PROFILE_SESSION}")"
  [[ -n "${PROFILE_SESSION}" ]] || PROFILE_SESSION="cluster"
  prompt_with_default BASTION_HOST "  Bastion host or IP" "${DEFAULT_BASTION_HOST}"
  prompt_with_default BASTION_PORT "  Bastion port" "${DEFAULT_BASTION_PORT}"
  prompt_with_default BASTION_USER "  Bastion user" "${DEFAULT_BASTION_USER}"
  prompt_with_default BASTION_SSH_OPTIONS "  Extra SSH options" "${DEFAULT_BASTION_SSH_OPTIONS}"
  write_profile_file "${PROFILE_SESSION}" "${PROFILE_LABEL}" "${BASTION_HOST}" \
    "${BASTION_PORT}" "${BASTION_USER}" "${BASTION_SSH_OPTIONS}"
  echo "Saved profile: ${PROFILES_DIR}/${PROFILE_SESSION}.env"
  load_profile "${PROFILE_SESSION}"
}

migrate_legacy_config() {
  # One-time: turn the old single ~/.ssh/bastion.env into a named profile.
  [[ -f "${CONFIG_FILE}" ]] || return 0
  local f
  for f in "${PROFILES_DIR}"/*.env; do [[ -e "${f}" ]] && return 0; done
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  echo "Migrating existing config (${CONFIG_FILE}) into a named profile:"
  prompt_with_default PROFILE_LABEL "  Name this config" "${BASTION_HOST:-${DEFAULT_BASTION_HOST}}"
  local slug
  slug="$(slugify "${PROFILE_LABEL}")"
  [[ -n "${slug}" ]] || slug="default"
  prompt_with_default PROFILE_SESSION "  Session id (ascii)" "${slug}"
  PROFILE_SESSION="$(slugify "${PROFILE_SESSION}")"
  [[ -n "${PROFILE_SESSION}" ]] || PROFILE_SESSION="default"
  write_profile_file "${PROFILE_SESSION}" "${PROFILE_LABEL}" "${BASTION_HOST}" \
    "${BASTION_PORT:-22}" "${BASTION_USER}" "${BASTION_SSH_OPTIONS:-}"
  echo "Migrated -> ${PROFILES_DIR}/${PROFILE_SESSION}.env"
}

pick_profile() {
  mkdir -p "${PROFILES_DIR}"
  migrate_legacy_config

  local files=() f
  for f in "${PROFILES_DIR}"/*.env; do [[ -e "${f}" ]] && files+=("${f}"); done
  if [[ ${#files[@]} -eq 0 ]]; then
    create_profile
    return
  fi

  local last=""
  [[ -r "${LAST_PROFILE_FILE}" ]] && last="$(head -1 "${LAST_PROFILE_FILE}" | tr -d '[:space:]')"

  echo "Available profiles:"
  local i=1 default_idx=1
  local -a slugs=()
  for f in "${files[@]}"; do
    local slug label host user mark=""
    slug="$(basename "${f}" .env)"
    label="$(sed -n 's/^BASTION_LABEL="\(.*\)"$/\1/p' "${f}")"
    host="$(sed -n 's/^BASTION_HOST="\(.*\)"$/\1/p' "${f}")"
    user="$(sed -n 's/^BASTION_USER="\(.*\)"$/\1/p' "${f}")"
    [[ -n "${label}" ]] || label="${slug}"
    if [[ "${slug}" == "${last}" ]]; then mark="   [last]"; default_idx=${i}; fi
    printf '  %d) %s   (%s@%s, session=%s)%s\n' "${i}" "${label}" "${user}" "${host}" "${slug}" "${mark}"
    slugs[${i}]="${slug}"
    i=$((i + 1))
  done
  local new_idx=${i}
  printf '  %d) + new profile\n' "${new_idx}"

  local choice=""
  printf 'Select [%d]: ' "${default_idx}"
  IFS= read -r choice || choice=""
  [[ -n "${choice}" ]] || choice="${default_idx}"

  if [[ "${choice}" == "${new_idx}" ]]; then
    create_profile
    return
  fi
  if [[ ! "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
    echo "Invalid choice: ${choice}" >&2
    exit 1
  fi
  load_profile "${slugs[${choice}]}"
}

validate_loaded_config() {
  local ok=0
  [[ -n "${BASTION_HOST:-}" ]] || { echo "config: BASTION_HOST is empty" >&2; ok=1; }
  [[ -n "${BASTION_USER:-}" ]] || { echo "config: BASTION_USER is empty" >&2; ok=1; }
  [[ "${BASTION_PORT:-22}" =~ ^[0-9]+$ ]] || { echo "config: BASTION_PORT must be numeric" >&2; ok=1; }
  return "${ok}"
}

check_config() {
  # Report saved profiles (used by `doctor`).
  mkdir -p "${PROFILES_DIR}" 2>/dev/null || true
  local f n=0
  for f in "${PROFILES_DIR}"/*.env; do [[ -e "${f}" ]] && n=$((n + 1)); done
  if [[ "${n}" -eq 0 && ! -f "${CONFIG_FILE}" ]]; then
    echo "  no profiles yet in ${PROFILES_DIR} (create one with: up)"
    return 0
  fi
  echo "  ${n} profile(s) in ${PROFILES_DIR}"
  [[ -r "${ACTIVE_SESSION_FILE}" ]] && echo "  active session: $(head -1 "${ACTIVE_SESSION_FILE}")"
  return 0
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
  ensure_runtime_dirs
  pick_profile
  validate_loaded_config || { echo "Fix the profile and retry." >&2; exit 1; }

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
