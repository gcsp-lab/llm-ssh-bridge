#!/bin/sh
# shellcheck shell=bash
if [ -z "${BASTION_TEST_BASH_BOOTSTRAPPED:-}" ]; then
  if [ -n "${LC_ALL:-}" ] && [ "${LC_ALL}" != "C" ] && [ "${LC_ALL}" != "POSIX" ] \
    && ! locale -a 2>/dev/null | grep -Fxq "${LC_ALL}"; then
    for candidate in C.UTF-8 en_US.UTF-8 C; do
      if [ "${candidate}" = "C" ] || locale -a 2>/dev/null | grep -Fxq "${candidate}"; then
        LC_ALL="${candidate}"
        LANG="${candidate}"
        export LC_ALL LANG
        break
      fi
    done
  fi
  export BASTION_TEST_BASH_BOOTSTRAPPED=1
  exec bash "$0" "$@"
fi

set -euo pipefail

normalize_locale() {
  local candidate
  if [[ -n "${LC_ALL:-}" && "${LC_ALL}" != "C" && "${LC_ALL}" != "POSIX" ]] \
    && ! locale -a 2>/dev/null | grep -Fxq "${LC_ALL}"; then
    :
  elif locale >/dev/null 2>&1; then
    return 0
  fi

  for candidate in C.UTF-8 en_US.UTF-8 C; do
    if [[ "${candidate}" == "C" ]] || locale -a 2>/dev/null | grep -Fxq "${candidate}"; then
      export LC_ALL="${candidate}"
      export LANG="${candidate}"
      return 0
    fi
  done
}

normalize_locale

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bastion-test.XXXXXX")"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${TMPDIR}/bin" "${TMPDIR}/home/.ssh" "${TMPDIR}/spool"
export FAKE_TMUX_STATE="${TMPDIR}/tmux-state"
mkdir -p "${FAKE_TMUX_STATE}"

cat > "${TMPDIR}/home/.ssh/bastion.env" <<'EOF'
BASTION_HOST="example.invalid"
BASTION_PORT="22"
BASTION_USER="tester"
EOF
chmod 600 "${TMPDIR}/home/.ssh/bastion.env"

cat > "${TMPDIR}/bin/tmux" <<'EOF'
#!/usr/bin/env bash
state="${FAKE_TMUX_STATE:?}"
case "$1" in
  has-session)
    [[ "${FAKE_TMUX_HAS_SESSION:-0}" == "1" ]]
    ;;
  list-windows) exit 1 ;;
  capture-pane) exit 1 ;;
  attach)
    printf '%s\n' "$*" > "${state}/attach"
    ;;
  kill-session)
    printf '%s\n' "$*" > "${state}/kill-session"
    ;;
  new-session)
    printf '%s\n' "$*" > "${state}/new-session"
    ;;
  set-option)
    printf '%s\n' "$*" > "${state}/set-option"
    ;;
  pipe-pane)
    if [[ $# -gt 3 ]]; then
      cmd="${*:4}"
      spool="${cmd#cat >> }"
      printf '%s\n' "${spool}" > "${state}/spool"
    else
      rm -f "${state}/spool"
    fi
    ;;
  set-buffer)
    printf '%s\n' "${@:5}" > "${state}/buffer"
    ;;
  paste-buffer)
    ;;
  delete-buffer)
    ;;
  send-keys)
    if [[ "${*: -1}" == "Enter" ]]; then
      spool="$(cat "${state}/spool")"
      payload="$(cat "${state}/buffer")"
      nonce="$(printf '%s\n' "${payload}" | sed -n "s/.*__bstn_nonce='\\([^']*\\)'.*/\\1/p")"
      start="__BSTN_START_${nonce}__"
      end="__BSTN_END_${nonce}__"
      ansi_b64="$(printf '%s' 'ansi-sentinel-probe' | base64 | tr -d '\n')"
      if [[ "${payload}" == *"${ansi_b64}"* ]]; then
        {
          printf '\n\033[01;32m%s\033[0m\n' "${start}"
          printf 'json-body-without-newline'
          printf '\033[01;31m%s\033[0m:7\n' "${end}"
        } >> "${spool}"
      else
        {
          printf '\n%s\n' "${start}"
          i=1
          while [[ "${i}" -le 300 ]]; do
            printf 'line-%03d\n' "${i}"
            i=$((i + 1))
          done
          printf '%s:0\n' "${end}"
        } >> "${spool}"
      fi
    fi
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TMPDIR}/bin/tmux"

cat > "${TMPDIR}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMPDIR}/bin/ssh"

export HOME="${TMPDIR}/home"
export PATH="${TMPDIR}/bin:${PATH}"
export BASTION_RUNTIME_DIR="${TMPDIR}"
export BASTION_SPOOL_DIR="${TMPDIR}/spool"
export FAKE_TMUX_HAS_SESSION=0
export BASTION_DEFAULT_HOST="example.com"
export BASTION_DEFAULT_PORT="2222"
export BASTION_DEFAULT_USER="default-user"
export BASTION_DEFAULT_SSH_OPTIONS=""

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'expected output to contain %q, got:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

bash -n "${ROOT}/scripts/bastion-up.sh"
bash -n "${ROOT}/scripts/bastion-run.sh"
bash -n "${ROOT}/llm-ssh-bridge"

cli_help="$("${ROOT}/llm-ssh-bridge" --help 2>&1)"
assert_contains "${cli_help}" "llm-ssh-bridge up"
assert_contains "${cli_help}" "llm-ssh-bridge run [run-options] '<command>'"

public_default_help="$(env -u BASTION_DEFAULT_HOST "${ROOT}/scripts/bastion-up.sh" --help 2>&1)"
assert_contains "${public_default_help}" "BASTION_DEFAULT_HOST            Default: example.com"

up_help="$("${ROOT}/scripts/bastion-up.sh" --help 2>&1)"
assert_contains "${up_help}" "doctor"
assert_contains "${up_help}" "clean"

run_help="$("${ROOT}/scripts/bastion-run.sh" --help 2>&1)"
assert_contains "${run_help}" "--keep-log"
assert_contains "${run_help}" "clean"

doctor="$("${ROOT}/scripts/bastion-up.sh" doctor 2>&1)"
assert_contains "${doctor}" "Dependencies"
assert_contains "${doctor}" "Session"

rm -f "${HOME}/.ssh/bastion.env"
first_up="$(printf '\n\n\n\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${first_up}" "Bastion host or IP [example.com]"
assert_contains "${first_up}" "Bastion port [2222]"
assert_contains "${first_up}" "Bastion user [default-user]"
assert_contains "${first_up}" "Extra SSH options []"
saved_config="$(cat "${HOME}/.ssh/bastion.env")"
assert_contains "${saved_config}" 'BASTION_HOST="example.com"'
assert_contains "${saved_config}" 'BASTION_PORT="2222"'
assert_contains "${saved_config}" 'BASTION_USER="default-user"'
assert_contains "${saved_config}" 'BASTION_SSH_OPTIONS=""'
new_session="$(cat "${FAKE_TMUX_STATE}/new-session")"
assert_contains "${new_session}" "-p 2222 default-user@example.com"
assert_contains "${new_session}" "ServerAliveInterval=30"
set_option="$(cat "${FAKE_TMUX_STATE}/set-option")"
assert_contains "${set_option}" "mouse off"

second_up="$(printf 'custom.example\n2023\ncustom-user\n-o HostKeyAlgorithms=+ssh-rsa\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${second_up}" "Bastion host or IP [example.com]"
assert_contains "${second_up}" "Bastion port [2222]"
assert_contains "${second_up}" "Bastion user [default-user]"
assert_contains "${second_up}" "Extra SSH options []"
saved_config="$(cat "${HOME}/.ssh/bastion.env")"
assert_contains "${saved_config}" 'BASTION_HOST="custom.example"'
assert_contains "${saved_config}" 'BASTION_PORT="2023"'
assert_contains "${saved_config}" 'BASTION_USER="custom-user"'
assert_contains "${saved_config}" 'BASTION_SSH_OPTIONS="-o HostKeyAlgorithms=+ssh-rsa"'
new_session="$(cat "${FAKE_TMUX_STATE}/new-session")"
assert_contains "${new_session}" "-o HostKeyAlgorithms=+ssh-rsa -p 2023 custom-user@custom.example"

export FAKE_TMUX_HAS_SESSION=1
attach_existing="$(printf '\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${attach_existing}" "tmux bastion already exists"
assert_contains "${attach_existing}" "Attach existing session"
attach_session="$(cat "${FAKE_TMUX_STATE}/attach")"
assert_contains "${attach_session}" "-t bastion"

restart_existing="$(printf 'n\n\n\n\n\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${restart_existing}" "Restarting tmux bastion"
assert_contains "${restart_existing}" "Bastion host or IP [custom.example]"
kill_session="$(cat "${FAKE_TMUX_STATE}/kill-session")"
assert_contains "${kill_session}" "-t bastion"

export FAKE_TMUX_HAS_SESSION=0
"${ROOT}/scripts/bastion-up.sh" clean --all >/dev/null
"${ROOT}/scripts/bastion-run.sh" clean --all >/dev/null

if "${ROOT}/scripts/bastion-run.sh" 'echo should-not-run' >"${TMPDIR}/missing-session.out" 2>&1; then
  echo "expected bastion-run without a tmux session to fail" >&2
  exit 1
fi
missing_session="$(cat "${TMPDIR}/missing-session.out")"
assert_contains "${missing_session}" "tmux session"
assert_contains "${missing_session}" "bastion-up.sh"

export FAKE_TMUX_HAS_SESSION=1
touch "${TMPDIR}/spool/run-bastion-XXXXXX.log"
spool_count_before="$(find "${TMPDIR}/spool" -type f -name 'run-*.log' | wc -l | awk '{print $1}')"
long_output="$("${ROOT}/scripts/bastion-run.sh" -t 5 'long-output-probe')"
assert_contains "${long_output}" "line-001"
assert_contains "${long_output}" "line-300"
last_payload="$(cat "${FAKE_TMUX_STATE}/buffer")"
assert_contains "${last_payload}" "base64 --decode | bash"
assert_contains "${last_payload}" "$(printf '%s' 'long-output-probe' | base64 | tr -d '\n')"
assert_contains "${last_payload}" "case \$- in"
assert_contains "${last_payload}" "set +e"
assert_contains "${last_payload}" "COMPOSE_PROGRESS=\"\${COMPOSE_PROGRESS:-plain}\""
assert_contains "${last_payload}" "NO_COLOR=\"\${NO_COLOR:-1}\""

spool_count="$(find "${TMPDIR}/spool" -type f -name 'run-*.log' | wc -l | awk '{print $1}')"
if [[ "${spool_count}" != "${spool_count_before}" ]]; then
  echo "expected successful run not to leave a new spool file, found ${spool_count} before ${spool_count_before}" >&2
  exit 1
fi

lock_dir="${TMPDIR}/lock-bastion"
mkdir -p "${lock_dir}"
printf '%s\n' "$(date +%s)" > "${lock_dir}/created_at"
printf '999999\n' > "${lock_dir}/pid"
set +e
recent_lock_output="$("${ROOT}/scripts/bastion-run.sh" -t 5 'recent-lock-probe' 2>&1)"
recent_lock_rc=$?
set -e
if [[ "${recent_lock_rc}" != "75" ]]; then
  echo "expected recent lock to be treated as busy, got ${recent_lock_rc}" >&2
  echo "${recent_lock_output}" >&2
  exit 1
fi
assert_contains "${recent_lock_output}" "tmux session bastion is busy"
if [[ ! -d "${lock_dir}" ]]; then
  echo "expected busy runner not to remove a lock it does not own" >&2
  exit 1
fi
rm -rf "${lock_dir}"

mkdir -p "${lock_dir}"
printf '0\n' > "${lock_dir}/created_at"
printf '999999\n' > "${lock_dir}/pid"
stale_lock_output="$("${ROOT}/scripts/bastion-run.sh" -t 5 'stale-lock-probe' 2>&1)"
assert_contains "${stale_lock_output}" "line-001"
if [[ -d "${lock_dir}" ]]; then
  echo "expected stale lock to be removed after run" >&2
  exit 1
fi

set +e
"${ROOT}/scripts/bastion-run.sh" --keep-log -t 5 'ansi-sentinel-probe' >"${TMPDIR}/ansi.out" 2>"${TMPDIR}/ansi.err"
ansi_rc=$?
set -e
if [[ "${ansi_rc}" != "7" ]]; then
  echo "expected ansi-sentinel-probe rc 7, got ${ansi_rc}" >&2
  cat "${TMPDIR}/ansi.err" >&2
  exit 1
fi
ansi_output="$(cat "${TMPDIR}/ansi.out")"
assert_contains "${ansi_output}" "json-body-without-newline"
if grep -q "Timed out" "${TMPDIR}/ansi.err"; then
  echo "did not expect timeout when END sentinel is ANSI wrapped and follows output without newline" >&2
  cat "${TMPDIR}/ansi.err" >&2
  exit 1
fi

# Hostname guard scaffolding is always present in the payload but inert by default.
assert_contains "${last_payload}" "__bstn_expected_host=''"
assert_contains "${last_payload}" "__bstn_actual_host"
assert_contains "${last_payload}" "hostname mismatch"

# Env override embeds expected hostname in payload.
BASTION_EXPECTED_HOSTNAME=fake-target "${ROOT}/scripts/bastion-run.sh" -t 5 'env-host-probe' >/dev/null
env_payload="$(cat "${FAKE_TMUX_STATE}/buffer")"
assert_contains "${env_payload}" "__bstn_expected_host='fake-target'"

# Pin file is read when no env override is set.
pin_file="${TMPDIR}/pin-bastion"
printf 'pinned-host\n' > "${pin_file}"
BASTION_PIN_FILE="${pin_file}" "${ROOT}/scripts/bastion-run.sh" -t 5 'pin-file-probe' >/dev/null
pin_payload="$(cat "${FAKE_TMUX_STATE}/buffer")"
assert_contains "${pin_payload}" "__bstn_expected_host='pinned-host'"

# --no-host-check overrides pin file.
BASTION_PIN_FILE="${pin_file}" "${ROOT}/scripts/bastion-run.sh" -t 5 --no-host-check 'no-host-check-probe' >/dev/null
nohost_payload="$(cat "${FAKE_TMUX_STATE}/buffer")"
assert_contains "${nohost_payload}" "__bstn_expected_host=''"
rm -f "${pin_file}"

# `pin` subcommand probes hostname and writes pin file.
fresh_pin="${TMPDIR}/new-pin"
rm -f "${fresh_pin}"
BASTION_PIN_FILE="${fresh_pin}" "${ROOT}/scripts/bastion-run.sh" pin >/dev/null
if [[ ! -f "${fresh_pin}" ]]; then
  echo "expected pin file to be created at ${fresh_pin}" >&2
  exit 1
fi
pinned_content="$(cat "${fresh_pin}")"
assert_contains "${pinned_content}" "line-300"
