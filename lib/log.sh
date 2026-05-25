#!/usr/bin/env bash
# ─── Logging helpers ────────────────────────────────────────────────
# Shared by the local CLI and the remote scripts. Colors auto-disable
# when stdout is not a TTY or NO_COLOR is set.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _C_RED='\033[0;31m'; _C_GREEN='\033[0;32m'; _C_YELLOW='\033[1;33m'
    _C_CYAN='\033[0;36m'; _C_BOLD='\033[1m'; _C_NC='\033[0m'
else
    _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''; _C_BOLD=''; _C_NC=''
fi

# All diagnostics go to stderr so stdout stays clean for command
# substitution (e.g. functions that "return" a value via printf).
info()  { printf "${_C_CYAN}[INFO]${_C_NC} %s\n" "$*" >&2; }
ok()    { printf "${_C_GREEN}[OK]${_C_NC} %s\n" "$*" >&2; }
warn()  { printf "${_C_YELLOW}[WARN]${_C_NC} %s\n" "$*" >&2; }
err()   { printf "${_C_RED}[ERROR]${_C_NC} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Section header for readable multi-step output.
section() {
    printf "\n${_C_BOLD}══ %s ══${_C_NC}\n" "$*" >&2
}
