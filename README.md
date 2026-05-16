# LLM SSH Bridge

LLM SSH Bridge is a standalone tmux-based helper for letting an LLM or coding agent drive a manually authenticated SSH session.

## Quick Start

```bash
./llm-ssh-bridge up
```

When starting a new session, confirm the SSH host, port, and user prompts. Press Enter to keep the shown default. Manually enter password, OTP, or any bastion menu choices required by your environment. After landing in the target shell, detach tmux with `Ctrl-b` then `d`.

If a tmux session already exists, `./llm-ssh-bridge up` asks whether to attach it. Answer `n` to stop the old session, confirm connection settings again, and start fresh.

Then run commands through the prepared session:

```bash
./llm-ssh-bridge run 'hostname && pwd'
./llm-ssh-bridge run -t 120 'find /var/log -type f | head'
```

## Commands

```bash
./llm-ssh-bridge up             # start or attach the tmux SSH session
./llm-ssh-bridge attach         # attach an existing session
./llm-ssh-bridge status         # show local session status
./llm-ssh-bridge doctor         # check dependencies, config, session, and pane output
./llm-ssh-bridge reset          # stop local tmux session, then start it again
./llm-ssh-bridge down           # stop local tmux session
./llm-ssh-bridge pin            # pin the current remote hostname as a guard
./llm-ssh-bridge clean [--all]  # clean spool files
./llm-ssh-bridge run '<cmd>'    # execute one command through the prepared session
```

The implementation scripts live in `scripts/`.

## Hostname Guard

If the SSH session drops mid-way and the tmux pane lands on a different shell (the bastion host's local shell, a different target after re-routing, etc.), `run` would otherwise execute commands on the wrong host. To defend against this, pin the expected remote hostname:

```bash
./llm-ssh-bridge pin
```

This probes `hostname` over the current session and writes the result to `~/.ssh/bastion-pin-${BASTION_SESSION}` (default `~/.ssh/bastion-pin-bastion`). Subsequent `run` invocations prepend a check to the payload; if the remote `hostname` no longer matches the pinned value, the command is not executed and the run exits with code 99.

Re-pin after any reconnection or target change. Override or disable per-run:

```bash
BASTION_EXPECTED_HOSTNAME=other-host ./llm-ssh-bridge run 'uptime'
./llm-ssh-bridge run --no-host-check 'uptime'
```

## Spool Files

`llm-ssh-bridge run` uses a short-lived spool file while each command is running. This avoids relying on tmux pane scrollback, so long command output can still be parsed correctly.

Successful runs delete their spool file by default. Failed, timed out, or unparsable runs keep the spool file and print its path.

## Configuration

On first `./llm-ssh-bridge up`, the script writes:

```bash
~/.ssh/bastion.env
```

Expected fields:

```bash
BASTION_HOST="example.com"
BASTION_PORT="22"
BASTION_USER="your-user"
```

Useful environment variables:

```bash
export BASTION_SESSION=bastion
export BASTION_CONFIG_FILE="$HOME/.ssh/bastion.env"
export BASTION_RUNTIME_DIR="${TMPDIR:-/tmp}/bastion-run"
export BASTION_SPOOL_DIR="$BASTION_RUNTIME_DIR/spool"
export BASTION_SPOOL_RETENTION_MINUTES=1440
export BASTION_KEEP_SUCCESS_LOGS=0
export BASTION_DEFAULT_HOST="example.com"
export BASTION_DEFAULT_PORT="22"
export BASTION_DEFAULT_USER="$USER"
```

This helper intentionally does not automate password entry, OTP entry, or SSH/bastion menu navigation.

## Test

```bash
bash scripts/test-bastion-scripts.sh
```

## License

MIT
