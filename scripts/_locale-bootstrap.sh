# shellcheck shell=sh
# POSIX sh. Sourced by entry scripts before they assume bash.
# Re-execs the caller under bash with a usable locale.

if [ "${BASH##*/}" != "bash" ]; then
  if [ -z "${BASTION_LOCALE_BOOTSTRAPPED:-}" ]; then
    if [ -n "${LC_ALL:-}" ] && [ "${LC_ALL}" != "C" ] && [ "${LC_ALL}" != "POSIX" ] \
      && ! locale -a 2>/dev/null | grep -Fxq "${LC_ALL}"; then
      for _bstn_candidate in C.UTF-8 en_US.UTF-8 C; do
        if [ "${_bstn_candidate}" = "C" ] || locale -a 2>/dev/null | grep -Fxq "${_bstn_candidate}"; then
          LC_ALL="${_bstn_candidate}"
          LANG="${_bstn_candidate}"
          export LC_ALL LANG
          break
        fi
      done
      unset _bstn_candidate
    fi
    export BASTION_LOCALE_BOOTSTRAPPED=1
  fi
  exec bash "$0" "$@"
fi
