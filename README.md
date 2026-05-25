# hoist

One config, one command. Describe a deployment in a single `hoist.yml`,
run `./hoist up` from your laptop, and the server gets:

- the app **cloned** (private repos via the [setup-dk](https://github.com/mixelka75/setup-dk) deploy-key flow),
- services up with **Docker Compose**,
- an **nginx** reverse proxy per domain + **Let's Encrypt** TLS,
- your **`.env`** copied over securely (scp, mode 600),
- nightly **database backups to Cloudflare R2** with retention, via cron.

It's plain Bash on your side and on the server — the only hard dependency it
installs locally is [`yq`](https://github.com/mikefarah/yq) (auto-installed to
`~/.local/bin` if missing). Everything heavy (Docker, nginx, certbot, rclone)
is installed on the server automatically and idempotently.

## How it works

```
 laptop                                  server
 ┌────────────────────┐  ssh/scp   ┌──────────────────────────────┐
 │ hoist up       │ ─────────▶ │ ~/.hoist/_run/bootstrap │
 │  • parse YAML (yq)  │            │  • install deps              │
 │  • render deploy.env│            │  • clone repo (setup-dk)     │
 │  • scp .env + bundle│            │  • place .env (600)          │
 └────────────────────┘            │  • nginx site + certbot      │
                                    │  • docker compose up -d      │
                                    │  • rclone R2 + backup cron   │
                                    └──────────────────────────────┘
```

All logic lives locally; the server only executes. The CLI bundles the
`remote/` scripts + a generated `deploy.env` (resolved scalars) + `domains.tsv`
+ your `.env`, ships them to `~/.hoist/_run`, and runs `bootstrap.sh`.

## Quick start

```bash
cp hoist.example.yml hoist.yml
$EDITOR hoist.yml          # set server, repo, domain, backup
$EDITOR .env                    # app secrets: DB password, R2 keys, ...

./hoist up                 # full first deploy
```

Preview without touching the server:

```bash
./hoist up --dry-run
```

## Commands

| Command | What it does |
|---|---|
| `hoist up` | First full deploy: deps → clone → .env → nginx+TLS → compose → backup cron |
| `hoist deploy` | `git pull` + `docker compose up -d --build` |
| `hoist env` | Re-push `.env` and restart services |
| `hoist nginx` | Regenerate nginx sites + reload + certbot |
| `hoist backup` | Run a backup to R2 right now |
| `hoist logs [svc]` | Follow `docker compose logs` |
| `hoist status` | `compose ps` + nginx + cron status |
| `hoist ssh` | Open a shell in the app dir on the server |

Flags: `-c FILE` (config, default `./hoist.yml`), `--dry-run`, `-h`, `-v`.

## Config

See [`hoist.example.yml`](hoist.example.yml). Key idea: **secrets stay
in `.env`** (which is gitignored and scp'd securely). In the YAML you only
reference variable *names* (`password_env`, `access_key_id_env`, …).

Your `.env` must contain whatever the YAML references, e.g.:

```dotenv
POSTGRES_PASSWORD=super-secret
R2_ACCESS_KEY_ID=xxxxxxxx
R2_SECRET_ACCESS_KEY=yyyyyyyy
```

## Requirements

- **Local:** bash 4+, `ssh`, `scp`, `git`, `curl`. `yq` auto-installs if absent.
- **Server:** a fresh Debian/Ubuntu or RHEL/Fedora box reachable over SSH with a
  sudo/root user. Docker, nginx, certbot and rclone are installed for you.
- **DNS:** point each domain's A record at the server *before* `up`, so certbot
  can validate. If DNS isn't ready, the site still serves on HTTP and you can
  re-run `hoist nginx` later to get the cert.

## Backups & restore

Backups land in `r2:<bucket>/<prefix>/<app>-<timestamp>.sql.gz`. Restore example:

```bash
rclone copy r2:my-backups/myapp/myapp-20260525-030000.sql.gz .
gunzip -c myapp-20260525-030000.sql.gz | \
  docker compose exec -T db psql -U postgres mydb
```

## Notes

- nginx and certbot run on the host (simpler cert issuance/renewal); your app
  ports are bound to `127.0.0.1` in compose and proxied.
- Re-running `hoist up` is safe (idempotent): existing repo is pulled,
  deps are skipped if present, the cron entry is replaced not duplicated.
- The setup-dk script is vendored in `remote/setup-deploy-key.sh`; for private
  repos it prints a deploy public key and waits for you to add it to the repo.
