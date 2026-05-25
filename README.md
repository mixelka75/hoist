# hoist

Один конфиг, одна команда. Описываешь деплой в единственном `hoist.yml`,
запускаешь `./hoist up` со своего ноутбука — и на сервере появляется:

- приложение, **склонированное** из репы (приватные — через deploy-key flow [setup-dk](https://github.com/mixelka75/setup-dk));
- поднятые сервисы через **Docker Compose**;
- **nginx** как обратный прокси на каждый домен + TLS-сертификат **Let's Encrypt**;
- твой **`.env`**, безопасно скопированный по scp (права 600);
- ночные **бэкапы базы в Cloudflare R2** с ротацией, через cron.

Это чистый Bash и у тебя, и на сервере. Единственная зависимость локально —
[`yq`](https://github.com/mikefarah/yq) (ставится автоматически в `~/.local/bin`,
если его нет). Всё тяжёлое (Docker, nginx, certbot, rclone) ставится на сервер
само и идемпотентно.

## Как это работает

```
 ноутбук                                 сервер
 ┌────────────────────┐  ssh/scp   ┌──────────────────────────────┐
 │ hoist up            │ ─────────▶ │ ~/.hoist/_run/bootstrap      │
 │  • парсит YAML (yq) │            │  • ставит зависимости        │
 │  • рендерит deploy.env           │  • клонит репу (setup-dk)    │
 │  • scp .env + бандл │            │  • кладёт .env (600)         │
 └────────────────────┘            │  • nginx сайт + certbot      │
                                    │  • docker compose up -d      │
                                    │  • rclone R2 + cron бэкапы   │
                                    └──────────────────────────────┘
```

Вся логика — локально, сервер только исполняет. CLI собирает бандл из скриптов
`remote/` + сгенерированный `deploy.env` (готовые значения) + `domains.tsv` +
твой `.env`, отправляет это в `~/.hoist/_run` и запускает `bootstrap.sh`.

## Быстрый старт

```bash
cp hoist.example.yml hoist.yml
$EDITOR hoist.yml          # сервер, репа, домен, бэкапы
$EDITOR .env              # секреты приложения: пароль БД, ключи R2, ...

./hoist up                # полный первый деплой
```

Посмотреть, что будет, не трогая сервер:

```bash
./hoist up --dry-run
```

## Команды

| Команда | Что делает |
|---|---|
| `hoist up` | Полный первый деплой: зависимости → клон → .env → nginx+TLS → compose → cron бэкапов |
| `hoist deploy` | `git pull` + `docker compose up -d --build` |
| `hoist env` | Перезалить `.env` и перезапустить сервисы |
| `hoist nginx` | Перегенерить nginx-сайты + reload + certbot |
| `hoist backup` | Сделать бэкап в R2 прямо сейчас |
| `hoist logs [svc]` | Следить за `docker compose logs` |
| `hoist status` | `compose ps` + статус nginx и cron |
| `hoist ssh` | Открыть шелл в каталоге приложения на сервере |

Флаги: `-c FILE` (конфиг, по умолчанию `./hoist.yml`), `--dry-run`, `-h`, `-v`.

## Конфиг

Смотри [`hoist.example.yml`](hoist.example.yml). Главная идея: **секреты живут
только в `.env`** (он в `.gitignore` и доставляется по scp). В YAML ты указываешь
лишь *имена* переменных (`password_env`, `access_key_id_env`, …).

В твоём `.env` должно быть то, на что ссылается YAML, например:

```dotenv
POSTGRES_PASSWORD=super-secret
R2_ACCESS_KEY_ID=xxxxxxxx
R2_SECRET_ACCESS_KEY=yyyyyyyy
```

## Требования

- **Локально:** bash 4+, `ssh`, `scp`, `git`, `curl`. `yq` доустановится сам.
- **Сервер:** свежая Debian/Ubuntu или RHEL/Fedora, доступная по SSH, с
  sudo/root-пользователем. Docker, nginx, certbot и rclone ставятся за тебя.
- **DNS:** A-запись каждого домена должна указывать на сервер *до* `up`, чтобы
  certbot прошёл валидацию. Если DNS ещё не прописан — сайт поднимется по HTTP,
  а сертификат можно дополучить позже через `hoist nginx`.

## Бэкапы и восстановление

Бэкапы кладутся в `r2:<bucket>/<prefix>/<app>-<timestamp>.sql.gz`. Пример
восстановления:

```bash
rclone copy r2:my-backups/myapp/myapp-20260525-030000.sql.gz .
gunzip -c myapp-20260525-030000.sql.gz | \
  docker compose exec -T db psql -U postgres mydb
```

## Заметки

- nginx и certbot работают на хосте (так проще выпускать и продлевать
  сертификаты); порты приложения вешаются на `127.0.0.1` в compose и проксируются.
- Повторный `hoist up` безопасен (идемпотентность): существующая репа
  подтягивается через pull, уже стоящие зависимости пропускаются, строка cron
  заменяется, а не дублируется.
- Скрипт setup-dk вшит в `remote/setup-deploy-key.sh`: для приватных реп он
  печатает публичный deploy-ключ и ждёт, пока ты добавишь его в репозиторий.
