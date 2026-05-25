#!/usr/bin/env bash
# ─── nginx site configuration (server side) ─────────────────────────
# Sourced by bootstrap.sh. Renders a reverse-proxy server block per
# domain into /etc/nginx/conf.d/, reloads nginx, then obtains/renews TLS
# certs with certbot. Relies on $SUDO, $SCRIPT_DIR, $SSL_EMAIL and the
# log helpers from the caller. Templating is done with pure bash (no
# envsubst dependency) substituting only ${SERVER_NAMES}/${UPSTREAM}/${DOMAIN}.

_NGINX_TEMPLATE="${SCRIPT_DIR}/templates/nginx-site.conf.tmpl"
_NGINX_CONFD="/etc/nginx/conf.d"

# Shared map for WebSocket Connection upgrade — written once.
_nginx_write_ws_map() {
    $SUDO tee "${_NGINX_CONFD}/00-hoist-ws.conf" >/dev/null <<'NGINXMAP'
# Managed by hoist: WebSocket upgrade helper.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINXMAP
}

_nginx_render_site() {
    local domain="$1" upstream="$2" server_names="$3" content
    content="$(cat "$_NGINX_TEMPLATE")"
    content="${content//\$\{SERVER_NAMES\}/$server_names}"
    content="${content//\$\{UPSTREAM\}/$upstream}"
    content="${content//\$\{DOMAIN\}/$domain}"
    printf '%s\n' "$content" | $SUDO tee "${_NGINX_CONFD}/${domain}.conf" >/dev/null
}

nginx_configure() {
    section "Configuring nginx"
    [[ -f "$_NGINX_TEMPLATE" ]] || die "nginx template missing: $_NGINX_TEMPLATE"

    $SUDO mkdir -p "$_NGINX_CONFD" /var/www/html
    _nginx_write_ws_map

    local domain upstream ssl www server_names
    while IFS=$'\x1f' read -r domain upstream ssl www; do
        [[ -z "$domain" ]] && continue
        server_names="$domain"
        [[ "$www" == "true" ]] && server_names="$domain www.$domain"

        info "Rendering site for $domain (-> $upstream)"
        _nginx_render_site "$domain" "$upstream" "$server_names"
    done < "${SCRIPT_DIR}/domains.tsv"

    info "Testing nginx config ..."
    $SUDO nginx -t
    $SUDO systemctl reload nginx 2>/dev/null || $SUDO nginx -s reload
    ok "nginx reloaded."

    # Obtain TLS certificates after nginx serves HTTP (needed for HTTP-01).
    while IFS=$'\x1f' read -r domain upstream ssl www; do
        [[ -z "$domain" ]] && continue
        [[ "$ssl" == "true" ]] || { warn "SSL disabled for $domain — skipping certbot"; continue; }

        local cargs=(-d "$domain")
        [[ "$www" == "true" ]] && cargs+=(-d "www.$domain")
        info "Requesting certificate for $domain ..."
        $SUDO certbot --nginx "${cargs[@]}" \
            --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect || \
            warn "certbot failed for $domain (DNS not pointed yet?) — site still serves on HTTP"
    done < "${SCRIPT_DIR}/domains.tsv"

    ok "nginx configuration complete."
}
