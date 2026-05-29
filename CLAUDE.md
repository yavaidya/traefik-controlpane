# Traefik Control Plane — Claude Context

This is the **umbrella** repo for a 4-repo system that implements the homelab
Traefik Control Plane. The authoritative design doc is
[`traefik-control-plane-e2e-plan.md`](./traefik-control-plane-e2e-plan.md) — do
not deviate from it without explicit user direction.

## Repo layout

Code lives in **sibling repos under `/home/yashv/code/node/`**, not in this
directory:

| Repo                                                 | Path                                                       | Role |
|------------------------------------------------------|------------------------------------------------------------|------|
| `traefik-control-plane-api`                          | `../traefik-control-plane-api`                             | FastAPI backend (auth, CRUD, validation, renderer, apply pipeline, Alembic) |
| `traefik-control-plane-ui`                           | `../traefik-control-plane-ui`                              | Vite + React + JS frontend |
| `traefik-control-plane-agent`                        | `../traefik-control-plane-agent`                           | FastAPI service that atomic-swaps rendered bundles into Traefik's active dynamic dir |
| `traefik-control-plane-config`                       | `../traefik-control-plane-config`                          | Git history of rendered bundles (one commit per successful apply) |

This umbrella holds the plan doc and `deploy/` (the docker-compose stack).
GitHub remotes live at `yavaidya/traefik-control-plane-*`.

## Stack

- Backend: FastAPI + SQLAlchemy 2.0 + Alembic + Pydantic v2 + Authlib + argon2
- Frontend: Vite + React 18 + JavaScript + TanStack Query + React Router
- DB: PostgreSQL 16, Redis 7
- Reverse proxy: Traefik v3.1 with file + docker providers
- Auth: local (argon2), Google OAuth, Microsoft OAuth (tenant), generic OIDC

## Hard rules

1. **No deviation from the plan doc.** If a feature isn't in `traefik-control-plane-e2e-plan.md`, do not add it.
2. **Sibling repos are the source of truth for code.** Never put code in this umbrella; only deploy and docs live here.
3. **Apply agent is the only writer to `deploy/traefik/dynamic/active/`.** API and UI never touch it directly.
4. **Validation gate before apply.** No apply path skips validation — any `error`-severity issue blocks.
5. **Audit every mutating action.** Every CRUD and lifecycle operation writes to `audit_events`.
6. **Secrets via `.env` only in dev**; Vault/SOPS in staging/prod per plan section 12.2.
7. **Subagents use Sonnet model**, hard limit **2 in parallel**.

## Working on this codebase

- Most changes go in one sibling repo. Identify the right repo before editing.
- `deploy/docker-compose.yml` builds from `../../traefik-control-plane-{api,ui,agent}` build contexts.
- The API runs behind Traefik with `stripprefix=/api` + `root_path=/api`, so app routes are `/v1/...` and external URLs are `/api/v1/...`.
- The UI dev server proxies `/api` → `http://localhost:8000` with prefix rewrite, so the same `apiFetch` helper works in dev and prod.

## Bring-up

```bash
cd deploy
cp .env.example .env  # fill in required vars
python ../../traefik-control-plane-api/scripts/hash_password.py 'pw'  # → INITIAL_ADMIN_PASSWORD_HASH
touch traefik/acme/acme.json && chmod 600 traefik/acme/acme.json
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d  # dev override exposes host ports
```

## When in doubt

- The plan doc is authoritative. Re-read the relevant section.
- The `Definition of Done` (plan section C) requires: API + UI + tests + audit + observability + docs.
