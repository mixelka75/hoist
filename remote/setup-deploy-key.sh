#!/usr/bin/env bash
# Vendored verbatim from upstream; it uses color vars in printf formats.
# shellcheck disable=SC2059
set -euo pipefail

# ─── Deploy Key Setup Script ────────────────────────────────────────
# Vendored from git@github.com:mixelka75/setup-dk.git (setup-deploy-key.sh).
# Generates an ed25519 deploy key, configures ~/.ssh/config, prints the
# public key, waits for confirmation, then clones via the new host alias.
# Usage: setup-deploy-key.sh git@host:owner/repo.git
# ─────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ─── Parse SSH URL ──────────────────────────────────────────────────
usage() {
    echo "Usage: $0 git@host:owner/repo.git"
    echo ""
    echo "Examples:"
    echo "  $0 git@github.com:user/repo.git"
    echo "  $0 git@gitlab.com:group/project"
    echo "  $0 git@bitbucket.org:team/repo.git"
    exit 1
}

[[ $# -lt 1 ]] && usage

SSH_URL="$1"

# Validate and parse: git@host:owner/repo.git
if [[ ! "$SSH_URL" =~ ^git@([^:]+):([^/]+)/(.+)$ ]]; then
    die "Invalid SSH URL format: $SSH_URL (expected git@host:owner/repo.git)"
fi

HOST="${BASH_REMATCH[1]}"
OWNER="${BASH_REMATCH[2]}"
REPO="${BASH_REMATCH[3]}"

# Strip trailing .git if present
REPO="${REPO%.git}"

info "Parsed SSH URL:"
echo "  Host:  $HOST"
echo "  Owner: $OWNER"
echo "  Repo:  $REPO"
echo ""

# ─── Paths ──────────────────────────────────────────────────────────
SSH_DIR="$HOME/.ssh"
KEY_NAME="deploy_${HOST}_${OWNER}_${REPO}"
KEY_PATH="$SSH_DIR/$KEY_NAME"
CONFIG_PATH="$SSH_DIR/config"
HOST_ALIAS="${HOST}-${OWNER}-${REPO}"

# ─── Check for duplicates ──────────────────────────────────────────
if [[ -f "$KEY_PATH" ]]; then
    warn "Deploy key already exists: $KEY_PATH"
    die "Remove it manually if you want to regenerate: rm $KEY_PATH $KEY_PATH.pub"
fi

if [[ -f "$CONFIG_PATH" ]] && grep -q "^Host ${HOST_ALIAS}$" "$CONFIG_PATH" 2>/dev/null; then
    warn "SSH config entry already exists for Host $HOST_ALIAS"
    die "Remove it manually from $CONFIG_PATH if you want to reconfigure."
fi

# ─── Generate SSH Key ───────────────────────────────────────────────
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

info "Generating ed25519 deploy key..."
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "deploy-key:${OWNER}/${REPO}" -q
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"
ok "Key generated: $KEY_PATH"
echo ""

# ─── Configure ~/.ssh/config ───────────────────────────────────────
info "Adding entry to $CONFIG_PATH..."

# Ensure config file exists with correct permissions
touch "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"

# Add a newline before the entry if the file is non-empty and doesn't end with one
if [[ -s "$CONFIG_PATH" ]] && [[ "$(tail -c 1 "$CONFIG_PATH" | wc -l)" -eq 0 ]]; then
    echo "" >> "$CONFIG_PATH"
fi

cat >> "$CONFIG_PATH" <<EOF

# Deploy key: ${OWNER}/${REPO}
Host ${HOST_ALIAS}
    HostName ${HOST}
    User git
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
EOF

ok "SSH config updated."
echo ""

# ─── Display public key and instructions ────────────────────────────
printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
printf "${BOLD} Public key (add this as a deploy key in your repository):${NC}\n"
printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
echo ""
cat "$KEY_PATH.pub"
echo ""

# Platform-specific instructions
case "$HOST" in
    github.com)
        printf "${CYAN}GitHub:${NC} https://github.com/${OWNER}/${REPO}/settings/keys/new\n"
        ;;
    gitlab.com)
        printf "${CYAN}GitLab:${NC} https://gitlab.com/${OWNER}/${REPO}/-/settings/repository (Deploy Keys)\n"
        ;;
    bitbucket.org)
        printf "${CYAN}Bitbucket:${NC} https://bitbucket.org/${OWNER}/${REPO}/admin/access-keys/\n"
        ;;
    *)
        printf "${CYAN}Add the public key above as a deploy key in your ${HOST} repository settings.${NC}\n"
        ;;
esac

echo ""
printf "${YELLOW}If you need push access, check \"Allow write access\" when adding the key.${NC}\n"
printf "${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
echo ""

# ─── Wait for user confirmation ─────────────────────────────────────
# Read from /dev/tty because stdin may be consumed by curl pipe
read -r -p "Press Enter after you've added the deploy key to the repository..." </dev/tty

echo ""

# ─── Clone repository ───────────────────────────────────────────────
CLONE_URL="git@${HOST_ALIAS}:${OWNER}/${REPO}.git"

info "Cloning via: $CLONE_URL"
git clone "$CLONE_URL"

echo ""
ok "Repository cloned to: $(pwd)/${REPO}"
printf "${GREEN}Done!${NC}\n"
