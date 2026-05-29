# traefik-controlpane

Umbrella repo: design document, integrated deploy stack, and developer quickstart for the Traefik Control Plane.

## Related repos

- **[traefik-controlpane](https://github.com/yavaidya/traefik-controlpane) — design doc and deploy stack (this repo)**
- [traefik-control-plane-api](https://github.com/yavaidya/traefik-control-plane-api) — FastAPI backend
- [traefik-control-plane-ui](https://github.com/yavaidya/traefik-control-plane-ui) — Vite + React frontend
- [traefik-control-plane-agent](https://github.com/yavaidya/traefik-control-plane-agent) — apply-agent for atomic dynamic-config swap
- [traefik-control-plane-config](https://github.com/yavaidya/traefik-control-plane-config) — generated bundle history

## What this repo does

This repo is the entry point for the Traefik Control Plane project. It holds no application code. Instead it contains the authoritative design document (`traefik-control-plane-e2e-plan.md`), the `deploy/` directory that wires the four sibling repos into a runnable docker-compose stack, and `CLAUDE.md` which documents the hard rules for AI-assisted development on this codebase.

The four sibling repos (API, UI, agent, config) live as separate git repositories under the same parent directory. The docker-compose build contexts reference them with relative paths (`../../traefik-control-plane-{api,ui,agent}`), so all five repos must be checked out as siblings.

## Architecture

```
Browser
  |
  |  HTTPS / HTTP
  v
Traefik v3.1  (ports 80, 443; dashboard on 8080 in dev)
  |           reads /etc/traefik/dynamic/active/<env>/
  |
  +---> control-ui   (Vite/React, port 3000 in prod / 5173 in dev)
  |       |
  +---> control-api  (FastAPI, port 8000; external prefix /api/v1/...)
          |
          +---> apply-agent  (FastAPI, port 7000; Bearer-token protected)
          |       |
          |       +---> dynamic/staging/<env>/  (write, then atomic swap)
          |       +---> dynamic/active/<env>/   (the only writer)
          |
          +---> postgres:5432   (SQLAlchemy / Alembic)
          +---> redis:6379      (session rate-limiter)
          +---> traefik-control-plane-config/  (git commits on apply)
```

Traefik watches `dynamic/active/` with `watch: true` and reloads instantly when a directory is swapped in by the agent.

## Repository layout

```
traefik-controlpane/
  traefik-control-plane-e2e-plan.md   # authoritative design document
  CLAUDE.md                           # developer/AI context and hard rules
  deploy/
    docker-compose.yml                # production-style compose (TLS, Traefik labels)
    docker-compose.dev.yml            # dev override: host ports, no TLS, hot-reload
    .env.example                      # template — copy to .env before bring-up
    scripts/
      dev-up.sh                       # one-shot dev bring-up script
      dev-down.sh                     # teardown
    traefik/
      static/
        traefik.yml                   # production static config (ACME via CF / Route53)
        traefik.dev.yml               # dev static config (insecure dashboard, no ACME)
      dynamic/
        active/                       # Traefik watches this directory
        staging/                      # agent writes here before swapping
      acme/
        acme.json                     # Let's Encrypt storage (chmod 600)
```

## Local development quickstart

All five repos must be checked out as siblings:

```
/home/<user>/code/node/
  traefik-controlpane/        ← this repo
  traefik-control-plane-api/
  traefik-control-plane-ui/
  traefik-control-plane-agent/
  traefik-control-plane-config/
```

### Bring up with the helper script

```bash
cd deploy
./scripts/dev-up.sh
```

The script:
1. Copies `.env.example` to `.env` if absent
2. Fills in safe dev defaults for `SESSION_SECRET`, `POSTGRES_PASSWORD`, `BASE_DOMAIN`, and `AGENT_SHARED_TOKEN`
3. Runs `scripts/hash_password.py admin` to set `INITIAL_ADMIN_PASSWORD_HASH` if not already set
4. Creates and chmods `traefik/acme/acme.json`
5. Runs `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build`

### Bring up manually

```bash
cd deploy
cp .env.example .env
# Edit .env — at minimum set SESSION_SECRET and POSTGRES_PASSWORD
python ../../traefik-control-plane-api/scripts/hash_password.py 'yourpassword'
# Paste the output into .env as INITIAL_ADMIN_PASSWORD_HASH=...
touch traefik/acme/acme.json && chmod 600 traefik/acme/acme.json
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

### Local URLs (dev override)

| Service | URL |
|---|---|
| UI | http://localhost:5173 |
| API (direct) | http://localhost:8001/v1/healthz |
| Apply agent | http://localhost:7000/healthz |
| Traefik dashboard | http://localhost:8089 |
| Traefik HTTP proxy | http://localhost:8088 |

### Seed admin credentials

Username: `admin`
Password: `admin` (dev default — the script hashes this with argon2)

The API creates the admin account at startup if `INITIAL_ADMIN_USERNAME` and `INITIAL_ADMIN_PASSWORD_HASH` are set. To hash a different password:

```bash
python ../../traefik-control-plane-api/scripts/hash_password.py 'yourpassword'
```

### Where apply bundles land

When an environment is applied through the UI or API:

1. The API renderer generates split YAML files under `http.routers/`, `tcp.routers/`, `udp.routers/`, `services/`, and `middlewares/`.
2. The API calls the agent's `POST /apply` with the bundle and a SHA-256 checksum.
3. The agent writes the files into `deploy/traefik/dynamic/staging/<env-name>/` in a temp directory, then atomically renames it to `deploy/traefik/dynamic/active/<env-name>/`.
4. If `CONFIG_REPO_PATH` is set, the API also commits the rendered files to the config repo with a message like `apply env=<name> checksum=<short> actor=<id> changeset=<id|none>`.

## Environment variables (deploy/.env)

| Variable | Required | Description |
|---|---|---|
| `SESSION_SECRET` | yes | Cookie signing secret, min 16 chars |
| `POSTGRES_PASSWORD` | yes | Postgres password for the `control` user |
| `BASE_DOMAIN` | yes (prod) | Domain for Traefik Host rules, e.g. `example.com` |
| `AGENT_SHARED_TOKEN` | yes | Shared bearer token between API and agent |
| `ACME_EMAIL` | prod | Email for Let's Encrypt |
| `CF_DNS_API_TOKEN` | prod | Cloudflare token for DNS challenge and DNS management |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | optional | Route53 ACME + DNS management |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | optional | Google OAuth |
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` / `MICROSOFT_TENANT_ID` | optional | Microsoft OAuth |
| `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | optional | Generic OIDC |
| `LOCAL_AUTH_ENABLED` | optional | Set to `false` to disable username/password login |
| `INITIAL_ADMIN_USERNAME` | optional | Seed admin username (default: `admin`) |
| `INITIAL_ADMIN_PASSWORD_HASH` | optional | Argon2 hash of seed admin password |
| `CONFIG_REPO_PATH` | optional | Absolute path to config repo for git commits |
| `POWERDNS_API_URL` / `POWERDNS_API_KEY` | optional | PowerDNS DNS management |

## Teardown

```bash
cd deploy
./scripts/dev-down.sh
# or
docker compose -f docker-compose.yml -f docker-compose.dev.yml down
```

To also remove persistent volumes:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml down -v
```

## Design document

The full end-to-end design is in [`traefik-control-plane-e2e-plan.md`](./traefik-control-plane-e2e-plan.md). All capability decisions should be validated against it. The [`CLAUDE.md`](./CLAUDE.md) file documents the hard rules for working in this codebase.

## License

MIT
