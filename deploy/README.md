# Deploy Stack (Traefik + Control Plane)

## 1. Prepare environment
```bash
cp .env.example .env
```

## 2. Prepare ACME storage
```bash
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json
```

## 3. Start stack
```bash
docker compose up -d
```

## 4. Verify
- Open `https://traefik-admin.<BASE_DOMAIN>`
- Verify API health responds from `/api` routes
- Confirm certificate issuance in Traefik logs

## Notes
- Keep secrets only in `.env` or your secrets manager.
- `apply-agent` is the only service that should promote dynamic config from `staging` to `active`.
