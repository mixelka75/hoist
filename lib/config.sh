#!/usr/bin/env bash
# ─── Config loading & validation ────────────────────────────────────
# Parses hoist.yml with `yq` (mikefarah/yq v4) into CFG_* globals,
# and serializes domains into a TSV. Heavy YAML work happens here, on
# the local side only — the server never parses YAML.
#
# The CFG_* globals set here are consumed by sibling sourced scripts
# (hoist, lib/ssh.sh), so SC2034 "appears unused" is expected.
# shellcheck disable=SC2034

# Ensure a usable yq is available; install mikefarah/yq to ~/.local/bin
# if missing. Sets the global YQ to the resolved binary path.
config_ensure_yq() {
    if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi 'mikefarah\|version v4\|version 4'; then
        YQ="$(command -v yq)"
        return 0
    fi
    if [[ -x "$HOME/.local/bin/yq" ]]; then
        YQ="$HOME/.local/bin/yq"
        return 0
    fi

    # yq is required locally to parse the config — install it even in
    # dry-run, since parsing is a local, harmless read.
    warn "yq (mikefarah v4) not found — installing to ~/.local/bin/yq"

    local os arch url
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "Unsupported arch for yq auto-install: $(uname -m). Install yq manually." ;;
    esac
    url="https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "$url" -o "$HOME/.local/bin/yq" || die "Failed to download yq from $url"
    chmod +x "$HOME/.local/bin/yq"
    YQ="$HOME/.local/bin/yq"
    ok "Installed yq -> $YQ"
}

# yq_get <path> [default] — read a scalar; null/missing falls back to
# default. NOTE: we deliberately avoid yq's `//` operator because it
# also substitutes on boolean `false` (jq falsy semantics), which would
# silently turn `ssl: false` into the default `true`.
_yq_get() {
    local path="$1" def="${2:-}" val
    val="$("$YQ" -r "$path" "$CONFIG_FILE" 2>/dev/null)"
    [[ -z "$val" || "$val" == "null" ]] && val="$def"
    printf '%s' "$val"
}

# Expand a leading ~ to $HOME (yq returns the literal tilde).
_expand_tilde() {
    local p="$1"
    [[ "$p" == "~"* ]] && p="${HOME}${p:1}"
    printf '%s' "$p"
}

# config_load <file> — populate CFG_* globals and DOMAINS_TSV.
config_load() {
    CONFIG_FILE="$1"
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    config_ensure_yq

    # server
    CFG_SERVER_HOST="$(_yq_get '.server.host')"
    CFG_SERVER_USER="$(_yq_get '.server.user' 'root')"
    CFG_SERVER_PORT="$(_yq_get '.server.port' '22')"
    CFG_SERVER_SSH_KEY="$(_expand_tilde "$(_yq_get '.server.ssh_key')")"

    # app
    CFG_APP_NAME="$(_yq_get '.app.name')"
    CFG_APP_REPO="$(_yq_get '.app.repo')"
    CFG_APP_BRANCH="$(_yq_get '.app.branch' 'main')"
    CFG_APP_DIR="$(_yq_get '.app.dir')"
    CFG_APP_PRIVATE="$(_yq_get '.app.private' 'false')"
    CFG_APP_COMPOSE_FILE="$(_yq_get '.app.compose_file' 'docker-compose.yml')"
    CFG_APP_ENV_FILE="$(_expand_tilde "$(_yq_get '.app.env_file' '.env')")"

    # ssl
    CFG_SSL_EMAIL="$(_yq_get '.ssl.email')"

    # backup
    CFG_BACKUP_ENABLED="$(_yq_get '.backup.enabled' 'false')"
    CFG_BACKUP_SCHEDULE="$(_yq_get '.backup.schedule' '0 3 * * *')"
    CFG_BACKUP_RETENTION_DAYS="$(_yq_get '.backup.retention_days' '14')"
    CFG_DB_TYPE="$(_yq_get '.backup.database.type')"
    CFG_DB_CONTAINER="$(_yq_get '.backup.database.container')"
    CFG_DB_NAME="$(_yq_get '.backup.database.name')"
    CFG_DB_USER="$(_yq_get '.backup.database.user')"
    CFG_DB_PASSWORD_ENV="$(_yq_get '.backup.database.password_env')"
    CFG_R2_ACCOUNT_ID="$(_yq_get '.backup.r2.account_id')"
    CFG_R2_BUCKET="$(_yq_get '.backup.r2.bucket')"
    CFG_R2_PREFIX="$(_yq_get '.backup.r2.prefix' "$CFG_APP_NAME")"
    CFG_R2_ACCESS_KEY_ID_ENV="$(_yq_get '.backup.r2.access_key_id_env' 'R2_ACCESS_KEY_ID')"
    CFG_R2_SECRET_ACCESS_KEY_ENV="$(_yq_get '.backup.r2.secret_access_key_env' 'R2_SECRET_ACCESS_KEY')"

    # domains -> records separated by US (\x1f), one per line. A
    # non-whitespace separator is required so `read` does not collapse
    # empty fields (which would silently shift columns).
    local n i d up ssl www
    n="$("$YQ" -r '.domains | length' "$CONFIG_FILE" 2>/dev/null)"
    [[ "$n" == "null" || -z "$n" ]] && n=0
    DOMAINS_TSV=""
    for (( i=0; i<n; i++ )); do
        d="$(_yq_get ".domains[$i].domain")"
        up="$(_yq_get ".domains[$i].upstream")"
        ssl="$(_yq_get ".domains[$i].ssl" 'true')"
        www="$(_yq_get ".domains[$i].www_redirect" 'false')"
        DOMAINS_TSV+="${d}"$'\x1f'"${up}"$'\x1f'"${ssl}"$'\x1f'"${www}"$'\n'
    done

    config_validate
}

config_validate() {
    local errs=()
    [[ -n "$CFG_SERVER_HOST" ]] || errs+=("server.host is required")
    [[ -n "$CFG_APP_NAME" ]]    || errs+=("app.name is required")
    [[ -n "$CFG_APP_REPO" ]]    || errs+=("app.repo is required")
    [[ -n "$CFG_APP_DIR" ]]     || errs+=("app.dir is required")
    [[ -n "$DOMAINS_TSV" ]]     || errs+=("at least one domains[] entry is required")

    # per-domain checks
    local need_ssl_email=0 d up ssl _www
    while IFS=$'\x1f' read -r d up ssl _www; do
        [[ -z "$d" ]] && continue
        [[ -n "$up" ]] || errs+=("domain '$d' is missing upstream")
        [[ "$ssl" == "true" ]] && need_ssl_email=1
    done <<< "$DOMAINS_TSV"
    if [[ "$need_ssl_email" == "1" && -z "$CFG_SSL_EMAIL" ]]; then
        errs+=("ssl.email is required when any domain has ssl: true")
    fi

    if [[ "$CFG_BACKUP_ENABLED" == "true" ]]; then
        [[ -n "$CFG_DB_TYPE" ]]      || errs+=("backup.database.type is required when backups are enabled")
        [[ -n "$CFG_DB_CONTAINER" ]] || errs+=("backup.database.container is required when backups are enabled")
        [[ -n "$CFG_DB_NAME" ]]      || errs+=("backup.database.name is required when backups are enabled")
        [[ -n "$CFG_DB_USER" ]]      || errs+=("backup.database.user is required when backups are enabled")
        [[ -n "$CFG_R2_ACCOUNT_ID" ]] || errs+=("backup.r2.account_id is required when backups are enabled")
        [[ -n "$CFG_R2_BUCKET" ]]    || errs+=("backup.r2.bucket is required when backups are enabled")
        case "$CFG_DB_TYPE" in
            postgres|mysql) ;;
            *) errs+=("backup.database.type must be 'postgres' or 'mysql' (got '$CFG_DB_TYPE')") ;;
        esac
    fi

    if (( ${#errs[@]} > 0 )); then
        err "Invalid config ($CONFIG_FILE):"
        local e; for e in "${errs[@]}"; do printf '  - %s\n' "$e" >&2; done
        exit 1
    fi
}

# Write the resolved scalar config to a server-sourced env file.
config_write_deploy_env() {
    local out="$1"
    cat > "$out" <<EOF
# Generated by hoist — do not edit by hand.
APP_NAME=$(printf '%q' "$CFG_APP_NAME")
APP_REPO=$(printf '%q' "$CFG_APP_REPO")
APP_BRANCH=$(printf '%q' "$CFG_APP_BRANCH")
APP_DIR=$(printf '%q' "$CFG_APP_DIR")
APP_PRIVATE=$(printf '%q' "$CFG_APP_PRIVATE")
APP_COMPOSE_FILE=$(printf '%q' "$CFG_APP_COMPOSE_FILE")
SSL_EMAIL=$(printf '%q' "$CFG_SSL_EMAIL")
BACKUP_ENABLED=$(printf '%q' "$CFG_BACKUP_ENABLED")
BACKUP_SCHEDULE=$(printf '%q' "$CFG_BACKUP_SCHEDULE")
BACKUP_RETENTION_DAYS=$(printf '%q' "$CFG_BACKUP_RETENTION_DAYS")
DB_TYPE=$(printf '%q' "$CFG_DB_TYPE")
DB_CONTAINER=$(printf '%q' "$CFG_DB_CONTAINER")
DB_NAME=$(printf '%q' "$CFG_DB_NAME")
DB_USER=$(printf '%q' "$CFG_DB_USER")
DB_PASSWORD_ENV=$(printf '%q' "$CFG_DB_PASSWORD_ENV")
R2_ACCOUNT_ID=$(printf '%q' "$CFG_R2_ACCOUNT_ID")
R2_BUCKET=$(printf '%q' "$CFG_R2_BUCKET")
R2_PREFIX=$(printf '%q' "$CFG_R2_PREFIX")
R2_ACCESS_KEY_ID_ENV=$(printf '%q' "$CFG_R2_ACCESS_KEY_ID_ENV")
R2_SECRET_ACCESS_KEY_ENV=$(printf '%q' "$CFG_R2_SECRET_ACCESS_KEY_ENV")
EOF
}
