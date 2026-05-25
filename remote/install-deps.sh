#!/usr/bin/env bash
# ─── Dependency installation (server side) ──────────────────────────
# Sourced by bootstrap.sh. Idempotently installs docker + compose,
# nginx, certbot (+nginx plugin) and rclone. Relies on $SUDO and the
# log helpers being defined by the caller.

# Detect the system package manager into PKG / PKG_INSTALL.
_detect_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG="apt"; PKG_INSTALL="$SUDO apt-get install -y -q"
        $SUDO apt-get update -q
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"; PKG_INSTALL="$SUDO dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"; PKG_INSTALL="$SUDO yum install -y"
    else
        die "No supported package manager found (need apt-get, dnf or yum)."
    fi
}

install_deps() {
    section "Installing dependencies"
    _detect_pkg

    # Base tools.
    $PKG_INSTALL curl git ca-certificates >/dev/null 2>&1 || \
        $PKG_INSTALL curl git ca-certificates

    # Docker Engine + compose plugin via the official convenience script.
    if command -v docker >/dev/null 2>&1; then
        ok "docker already installed: $(docker --version 2>/dev/null)"
    else
        info "Installing Docker via get.docker.com ..."
        curl -fsSL https://get.docker.com | $SUDO sh
        $SUDO systemctl enable --now docker 2>/dev/null || true
    fi
    # Ensure the invoking (non-root) user can talk to the docker socket.
    if [[ "$(id -u)" -ne 0 ]]; then
        $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || true
    fi
    if ! docker compose version >/dev/null 2>&1; then
        warn "docker compose plugin not detected — trying package install"
        case "$PKG" in
            apt) $PKG_INSTALL docker-compose-plugin || true ;;
            dnf|yum) $PKG_INSTALL docker-compose-plugin || true ;;
        esac
    fi

    # nginx.
    if command -v nginx >/dev/null 2>&1; then
        ok "nginx already installed"
    else
        info "Installing nginx ..."
        $PKG_INSTALL nginx
        $SUDO systemctl enable --now nginx 2>/dev/null || true
    fi

    # certbot + nginx plugin.
    if command -v certbot >/dev/null 2>&1; then
        ok "certbot already installed"
    else
        info "Installing certbot + nginx plugin ..."
        case "$PKG" in
            apt)     $PKG_INSTALL certbot python3-certbot-nginx ;;
            dnf|yum) $PKG_INSTALL certbot python3-certbot-nginx ;;
        esac
    fi

    # rclone (for R2 backups) via the official installer.
    if command -v rclone >/dev/null 2>&1; then
        ok "rclone already installed: $(rclone version 2>/dev/null | head -1)"
    else
        info "Installing rclone ..."
        curl -fsSL https://rclone.org/install.sh | $SUDO bash || \
            $PKG_INSTALL rclone
    fi

    # cron — runs the scheduled R2 backups (the crontab is set later).
    if command -v crontab >/dev/null 2>&1; then
        ok "cron already installed"
    else
        info "Installing cron ..."
        case "$PKG" in
            apt)     $PKG_INSTALL cron ;;
            dnf|yum) $PKG_INSTALL cronie ;;
        esac
    fi
    $SUDO systemctl enable --now cron 2>/dev/null \
        || $SUDO systemctl enable --now crond 2>/dev/null || true

    ok "Dependencies ready."
}
