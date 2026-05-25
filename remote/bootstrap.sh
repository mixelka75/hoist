#!/usr/bin/env bash
# ─── hoist server-side orchestrator ────────────────────────────
# Run on the target server (invoked over SSH by the local CLI). Sources
# the resolved deploy.env, then installs deps, fetches the app source,
# places .env, configures nginx + TLS, brings up docker compose, and
# installs the R2 backup cron. Idempotent — safe to re-run.
#
# Usage: bootstrap.sh [up|deploy|restart|nginx]
set -Eeuo pipefail   # -E: ERR trap is inherited by functions and subshells

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/log.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/deploy.env"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/install-deps.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/nginx-site.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/setup-rclone.sh"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Run docker with sudo when not root (group membership may not be active
# yet in this freshly-created session).
dock() {
    if [[ -n "$SUDO" ]]; then sudo docker "$@"; else docker "$@"; fi
}

# ─── error handling ─────────────────────────────────────────────────
# Report which phase failed instead of dying with a bare non-zero exit.
# $_STEP is set before each phase in the dispatcher below.
_STEP="initialization"
_on_err() {
    local code=$? line="${1:-?}"
    err "✗ Failed while: ${_STEP}  (line ${line}, exit ${code})"
    err "  Nothing was rolled back — fix the cause and re-run; hoist is idempotent."
    exit "$code"
}
trap '_on_err "$LINENO"' ERR

clone_or_update() {
    section "Fetching application source"
    if [[ -d "${APP_DIR}/.git" ]]; then
        info "Repo present -> git pull (${APP_BRANCH})"
        git -C "$APP_DIR" fetch origin "$APP_BRANCH" --quiet || true
        git -C "$APP_DIR" checkout "$APP_BRANCH" 2>/dev/null || true
        git -C "$APP_DIR" pull --ff-only || warn "git pull failed — continuing with current checkout"
        return 0
    fi

    $SUDO mkdir -p "$APP_DIR"
    $SUDO chown -R "$(id -u):$(id -g)" "$APP_DIR"

    if [[ "$APP_PRIVATE" == "true" ]]; then
        info "Private repo -> setup-deploy-key flow (interactive)"
        local tmp base
        tmp="$(mktemp -d)"
        ( cd "$tmp" && bash "${SCRIPT_DIR}/setup-deploy-key.sh" "$APP_REPO" )
        base="$(basename "${APP_REPO%.git}")"
        shopt -s dotglob
        mv "${tmp}/${base}"/* "${APP_DIR}/"
        shopt -u dotglob
        rm -rf "$tmp"
    else
        # git clone needs an empty target; APP_DIR was just created empty.
        git clone -b "$APP_BRANCH" "$APP_REPO" "$APP_DIR" 2>/dev/null || \
            git clone "$APP_REPO" "$APP_DIR"
    fi
    git -C "$APP_DIR" checkout "$APP_BRANCH" 2>/dev/null || true
    ok "Source ready at $APP_DIR"
}

place_env() {
    if [[ -f "${SCRIPT_DIR}/app.env" ]]; then
        cp "${SCRIPT_DIR}/app.env" "${APP_DIR}/.env"
        chmod 600 "${APP_DIR}/.env"
        ok ".env installed at ${APP_DIR}/.env (mode 600)"
    else
        warn "No .env was uploaded — skipping (app must not require one)"
    fi
}

compose_up() {
    section "Starting services (docker compose)"
    cd "$APP_DIR"
    [[ -f "$APP_COMPOSE_FILE" ]] || die "Compose file not found: ${APP_DIR}/${APP_COMPOSE_FILE}"
    if ! dock info >/dev/null 2>&1; then
        info "docker daemon not responding — starting it"
        $SUDO systemctl start docker 2>/dev/null || true
        dock info >/dev/null 2>&1 || die "docker daemon is not running and could not be started"
    fi
    dock compose -f "$APP_COMPOSE_FILE" up -d --build --remove-orphans
    dock compose -f "$APP_COMPOSE_FILE" ps
    ok "Services are up."
}

backup_setup() {
    [[ "$BACKUP_ENABLED" == "true" ]] || { info "Backups disabled — skipping"; return 0; }
    setup_rclone
    install_backup
}

ACTION="${1:-up}"
case "$ACTION" in
    up)
        _STEP="installing dependencies";      install_deps
        _STEP="fetching application source";  clone_or_update
        _STEP="installing .env";              place_env
        _STEP="configuring nginx + TLS";      nginx_configure
        _STEP="starting docker compose";      compose_up
        _STEP="installing backups";           backup_setup
        ;;
    deploy)
        _STEP="fetching application source";  clone_or_update
        _STEP="installing .env";              place_env
        _STEP="starting docker compose";      compose_up
        ;;
    restart)
        _STEP="installing .env";              place_env
        _STEP="starting docker compose";      compose_up
        ;;
    nginx)
        _STEP="configuring nginx + TLS";      nginx_configure
        ;;
    *)
        die "Unknown action: $ACTION (expected up|deploy|restart|nginx)"
        ;;
esac

section "Done"
ok "hoist '${ACTION}' completed for ${APP_NAME}"
