#!/usr/bin/env bash
# ─── Database backup -> Cloudflare R2 (cron) ────────────────────────
# Installed to /opt/hoist/backup.sh and invoked by cron. Dumps the
# app database from its compose container, uploads to R2 via rclone, and
# prunes objects older than the retention window. Config comes from the
# sibling deploy.env; DB password is read from the app's .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/log.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/deploy.env"

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

info "=== backup run $(date -u +%FT%TZ) for ${APP_NAME} ==="

ENVF="${APP_DIR}/.env"
TS="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DUMP="${WORK}/${APP_NAME}-${TS}.sql.gz"

cd "$APP_DIR"
COMPOSE=(docker compose -f "$APP_COMPOSE_FILE")
DBPASS="$(_dotenv_get "$ENVF" "$DB_PASSWORD_ENV" || true)"

case "$DB_TYPE" in
    postgres)
        "${COMPOSE[@]}" exec -T -e PGPASSWORD="$DBPASS" "$DB_CONTAINER" \
            pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$DUMP"
        ;;
    mysql)
        "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$DBPASS" "$DB_CONTAINER" \
            mysqldump -u"$DB_USER" "$DB_NAME" | gzip > "$DUMP"
        ;;
    *)
        die "Unsupported DB_TYPE: $DB_TYPE"
        ;;
esac

[[ -s "$DUMP" ]] || die "Dump is empty — aborting upload."
ok "Dump created: $(basename "$DUMP") ($(du -h "$DUMP" | cut -f1))"

DEST="r2:${R2_BUCKET}/${R2_PREFIX}/"
rclone copy "$DUMP" "$DEST"
ok "Uploaded to ${DEST}"

if [[ "${BACKUP_RETENTION_DAYS:-0}" =~ ^[0-9]+$ ]] && (( BACKUP_RETENTION_DAYS > 0 )); then
    rclone delete --min-age "${BACKUP_RETENTION_DAYS}d" "$DEST" || \
        warn "Rotation step failed (non-fatal)"
    info "Pruned backups older than ${BACKUP_RETENTION_DAYS}d"
fi

ok "Backup finished: ${APP_NAME}-${TS}"
