#!/usr/bin/env bash
set -euo pipefail

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
      start="$(printf '%s\n' "${payload}" | sed -n "s/.*printf '\\\\n%s\\\\n' '\\([^']*\\)'.*/\\1/p")"
      end="$(printf '%s\n' "${payload}" | sed -n "s/.*printf '%s:%d\\\\n' '\\([^']*\\)'.*/\\1/p")"
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
export BASTION_SPOOL_DIR="${TMPDIR}/spool"
export FAKE_TMUX_HAS_SESSION=0
export BASTION_DEFAULT_HOST="example.com"
export BASTION_DEFAULT_PORT="2222"
export BASTION_DEFAULT_USER="default-user"

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
first_up="$(printf '\n\n\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${first_up}" "Bastion host or IP [example.com]"
assert_contains "${first_up}" "Bastion port [2222]"
assert_contains "${first_up}" "Bastion user [default-user]"
saved_config="$(cat "${HOME}/.ssh/bastion.env")"
assert_contains "${saved_config}" 'BASTION_HOST="example.com"'
assert_contains "${saved_config}" 'BASTION_PORT="2222"'
assert_contains "${saved_config}" 'BASTION_USER="default-user"'
new_session="$(cat "${FAKE_TMUX_STATE}/new-session")"
assert_contains "${new_session}" "ssh -p 2222 default-user@example.com"

second_up="$(printf 'custom.example\n2023\ncustom-user\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${second_up}" "Bastion host or IP [example.com]"
assert_contains "${second_up}" "Bastion port [2222]"
assert_contains "${second_up}" "Bastion user [default-user]"
saved_config="$(cat "${HOME}/.ssh/bastion.env")"
assert_contains "${saved_config}" 'BASTION_HOST="custom.example"'
assert_contains "${saved_config}" 'BASTION_PORT="2023"'
assert_contains "${saved_config}" 'BASTION_USER="custom-user"'
new_session="$(cat "${FAKE_TMUX_STATE}/new-session")"
assert_contains "${new_session}" "ssh -p 2023 custom-user@custom.example"

export FAKE_TMUX_HAS_SESSION=1
attach_existing="$(printf '\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${attach_existing}" "tmux bastion already exists"
assert_contains "${attach_existing}" "Attach existing session"
attach_session="$(cat "${FAKE_TMUX_STATE}/attach")"
assert_contains "${attach_session}" "-t bastion"

restart_existing="$(printf 'n\n\n\n\n' | "${ROOT}/scripts/bastion-up.sh" up 2>&1)"
assert_contains "${restart_existing}" "Restarting tmux bastion"
assert_contains "${restart_existing}" "Bastion host or IP [custom.example]"
kill_session="$(cat "${FAKE_TMUX_STATE}/kill-session")"
assert_contains "${kill_session}" "-t bastion"

export FAKE_TMUX_HAS_SESSION=0
"${ROOT}/scripts/bastion-up.sh" clean --all >/dev/null
"${ROOT}/scripts/bastion-run.sh" clean --all >/dev/null

if "${ROOT}/scripts/bastion-run.sh" 'echo should-not-run' >/tmp/bastion-test.out 2>&1; then
  echo "expected bastion-run without a tmux session to fail" >&2
  exit 1
fi
missing_session="$(cat /tmp/bastion-test.out)"
assert_contains "${missing_session}" "tmux session"
assert_contains "${missing_session}" "bastion-up.sh"

export FAKE_TMUX_HAS_SESSION=1
touch "${TMPDIR}/spool/run-bastion-XXXXXX.log"
spool_count_before="$(find "${TMPDIR}/spool" -type f -name 'run-*.log' | wc -l | awk '{print $1}')"
long_output="$("${ROOT}/scripts/bastion-run.sh" -t 5 'long-output-probe')"
assert_contains "${long_output}" "line-001"
assert_contains "${long_output}" "line-300"
last_payload="$(cat "${FAKE_TMUX_STATE}/buffer")"
assert_contains "${last_payload}" "( long-output-probe )"
assert_contains "${last_payload}" "case \$- in"
assert_contains "${last_payload}" "set +e"

spool_count="$(find "${TMPDIR}/spool" -type f -name 'run-*.log' | wc -l | awk '{print $1}')"
if [[ "${spool_count}" != "${spool_count_before}" ]]; then
  echo "expected successful run not to leave a new spool file, found ${spool_count} before ${spool_count_before}" >&2
  exit 1
fi
