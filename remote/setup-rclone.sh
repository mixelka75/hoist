#!/usr/bin/env bash
# ─── rclone (R2) + backup cron installer (server side) ──────────────
# Sourced by bootstrap.sh. Writes an rclone remote named "r2" pointing
# at Cloudflare R2 (secrets read from the app's .env), installs the
# backup script to a persistent dir, and registers the cron job.
# Relies on $SUDO, $SCRIPT_DIR, and CFG/deploy.env vars from the caller.

PERSIST_DIR="/opt/hoist"

# Read a single KEY from a dotenv file without sourcing it (safer).
_dotenv_get() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -1)" || true
    [[ -z "$line" ]] && return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

setup_rclone() {
    section "Configuring rclone for Cloudflare R2"
    local envf="${APP_DIR}/.env" akid secret
    akid="$(_dotenv_get "$envf" "$R2_ACCESS_KEY_ID_ENV")" || \
        die "R2 access key id var '$R2_ACCESS_KEY_ID_ENV' not found in $envf"
    secret="$(_dotenv_get "$envf" "$R2_SECRET_ACCESS_KEY_ENV")" || \
        die "R2 secret var '$R2_SECRET_ACCESS_KEY_ENV' not found in $envf"

    local conf_dir="${HOME}/.config/rclone"
    mkdir -p "$conf_dir"
    cat > "${conf_dir}/rclone.conf" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${akid}
secret_access_key = ${secret}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    chmod 600 "${conf_dir}/rclone.conf"
    ok "rclone remote 'r2' configured."
}

install_backup() {
    section "Installing backup job"
    $SUDO mkdir -p "$PERSIST_DIR"
    $SUDO chown "$(id -u):$(id -g)" "$PERSIST_DIR"

    cp "${SCRIPT_DIR}/backup.sh"  "${PERSIST_DIR}/backup.sh"
    cp "${SCRIPT_DIR}/log.sh"     "${PERSIST_DIR}/log.sh"
    cp "${SCRIPT_DIR}/deploy.env" "${PERSIST_DIR}/deploy.env"
    chmod +x "${PERSIST_DIR}/backup.sh"

    local marker="# hoist-backup:${APP_NAME}"
    local line="${BACKUP_SCHEDULE} ${PERSIST_DIR}/backup.sh >> ${PERSIST_DIR}/backup.log 2>&1 ${marker}"
    # Drop any previous entry for this app, then append the fresh one. `|| true`
    # absorbs the expected non-zero on a fresh server (no crontab yet →
    # `crontab -l` exits 1; empty input → `grep` exits 1) under set -e/pipefail.
    ( crontab -l 2>/dev/null | grep -vF "$marker" || true; echo "$line" ) | crontab -
    ok "Cron installed: ${BACKUP_SCHEDULE} -> ${PERSIST_DIR}/backup.sh"
}
