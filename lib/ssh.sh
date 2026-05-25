#!/usr/bin/env bash
# ─── SSH / SCP helpers ──────────────────────────────────────────────
# Thin wrappers over ssh/scp that honor CFG_SERVER_* and DRY_RUN. A
# ControlMaster connection is reused across calls so the user is only
# prompted (key passphrase / known_hosts) once per run.

_SSH_CONTROL_DIR=""
_SSH_OPTS=()
SSH_TARGET=""

ssh_setup() {
    SSH_TARGET="${CFG_SERVER_USER}@${CFG_SERVER_HOST}"
    _SSH_CONTROL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoist-ssh.XXXXXX")"
    _SSH_OPTS=(
        # accept-new: auto-trust a new host on first connect (so the very
        # first non-interactive scp/ssh works) but still refuse if a known
        # host's key later changes.
        -o "StrictHostKeyChecking=accept-new"
        -o "ControlMaster=auto"
        -o "ControlPath=${_SSH_CONTROL_DIR}/cm-%r@%h:%p"
        -o "ControlPersist=120"
        # Use -o Port=N (not -p): scp reads -p as preserve-mode, only ssh
        # treats -p as the port. -o Port works for both ssh and scp.
        -o "Port=${CFG_SERVER_PORT}"
    )
    # NB: use an `if` (not `[[ ... ]] && ...`) — as the function's last
    # statement a false `[[ ]]` would return 1 and, under `set -e`, abort
    # the whole script right after ssh_setup when no ssh_key is configured.
    if [[ -n "$CFG_SERVER_SSH_KEY" ]]; then
        _SSH_OPTS+=(-i "$CFG_SERVER_SSH_KEY" -o "IdentitiesOnly=yes")
    fi
}

ssh_cleanup() {
    [[ -z "$_SSH_CONTROL_DIR" ]] && return 0
    if [[ -z "${DRY_RUN:-}" ]]; then
        ssh "${_SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
    fi
    rm -rf "$_SSH_CONTROL_DIR"
    _SSH_CONTROL_DIR=""
}

# Run a non-interactive command on the server.
ssh_run() {
    local cmd="$1"
    if [[ -n "${DRY_RUN:-}" ]]; then
        printf '[dry-run] ssh %s %s -- %s\n' "${CFG_SERVER_PORT:+-p $CFG_SERVER_PORT}" "$SSH_TARGET" "$cmd"
        return 0
    fi
    # $cmd is intentionally built client-side (remote values already inlined).
    # shellcheck disable=SC2029
    ssh "${_SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
}

# Run an interactive command on the server (TTY allocated) — needed for
# the setup-dk deploy-key prompt and certbot/docker progress output.
ssh_run_tty() {
    local cmd="$1"
    if [[ -n "${DRY_RUN:-}" ]]; then
        printf '[dry-run] ssh -t %s %s -- %s\n' "${CFG_SERVER_PORT:+-p $CFG_SERVER_PORT}" "$SSH_TARGET" "$cmd"
        return 0
    fi
    ssh -t "${_SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
}

# Copy a single local file to a remote path.
scp_file() {
    local src="$1" dest="$2"
    if [[ -n "${DRY_RUN:-}" ]]; then
        printf '[dry-run] scp %s -> %s:%s\n' "$src" "$SSH_TARGET" "$dest"
        return 0
    fi
    scp "${_SSH_OPTS[@]}" -q "$src" "${SSH_TARGET}:${dest}"
}

# Recursively copy a local directory's contents to a remote directory.
scp_dir() {
    local src="$1" dest="$2"
    if [[ -n "${DRY_RUN:-}" ]]; then
        printf '[dry-run] scp -r %s/. -> %s:%s\n' "$src" "$SSH_TARGET" "$dest"
        return 0
    fi
    # shellcheck disable=SC2029
    ssh "${_SSH_OPTS[@]}" "$SSH_TARGET" "mkdir -p '$dest'"
    scp "${_SSH_OPTS[@]}" -q -r "$src/." "${SSH_TARGET}:${dest}/"
}
