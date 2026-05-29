# Deploy Stack (Traefik + Control Plane)

This stack runs Traefik together with the control plane (API, UI, apply-agent,
Postgres, Redis). The control-plane services are built from sibling repos:

- `../../traefik-control-plane-api`
- `../../traefik-control-plane-ui`
- `../../traefik-control-plane-agent`

## Quick local dev (no DNS, no TLS)

```bash
./scripts/dev-up.sh
# UI:        http://localhost:5173  (admin / admin)
# API:       http://localhost:8000/v1/healthz
# Dashboard: http://localhost:8080
./scripts/dev-down.sh
```

`dev-up.sh` bootstraps a `.env` with safe dev defaults, creates the ACME
storage file, then starts the stack with the `docker-compose.dev.yml` override.
The UI runs as a Vite dev server with hot-reload; the API is exposed directly on
port 8000 without Traefik routing.

---

## Production setup

## 1. Prepare environment

```bash
cp .env.example .env
# Fill in BASE_DOMAIN, ACME_EMAIL, provider credentials, POSTGRES_PASSWORD,
# AGENT_SHARED_TOKEN, SESSION_SECRET, and at least one auth provider.
```

To set a local admin password:

```bash
python ../../traefik-control-plane-api/scripts/hash_password.py 'my-password'
# paste the printed hash into INITIAL_ADMIN_PASSWORD_HASH
```

## 2. Prepare ACME storage

```bash
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json
```

## 3. Build and start

```bash
docker compose build
docker compose up -d
```

## 4. Verify

1. `docker compose logs -f control-api` — confirm Alembic migrations ran and the
   seed admin was created.
2. Hit `https://traefik-admin.<BASE_DOMAIN>/api/v1/healthz` — expect `{"status":"ok"}`.
3. Open `https://traefik-admin.<BASE_DOMAIN>` in a browser, log in as the seed
   admin (or via OAuth if you configured a provider).
4. Create an environment, then a service (`http://whoami:80`), then a router
   (`Host(\`whoami.<BASE_DOMAIN>\`)`). Click **Apply environment**.
5. Watch `traefik/dynamic/active/<env-name>/` populate. Traefik picks up the
   change automatically via its file provider.

## Notes

- Keep secrets only in `.env` or a real secrets manager.
- `apply-agent` is the only service that should promote dynamic config from
  `staging` to `active`.
- The API is exposed at `/api` via Traefik with stripprefix; FastAPI runs with
  `root_path=/api` so generated docs and links remain correct.
