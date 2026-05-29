#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  cp .env.example .env
fi

# Ensure SESSION_SECRET is set for dev so the API starts
if ! grep -q '^SESSION_SECRET=.\{16,\}' .env; then
  sed -i.bak '/^SESSION_SECRET=/d' .env
  echo 'SESSION_SECRET=dev-session-secret-min-16-chars-long' >> .env
fi
if ! grep -q '^POSTGRES_PASSWORD=.' .env; then
  sed -i.bak '/^POSTGRES_PASSWORD=/d' .env
  echo 'POSTGRES_PASSWORD=control' >> .env
fi
if ! grep -q '^BASE_DOMAIN=.' .env; then
  sed -i.bak '/^BASE_DOMAIN=/d' .env
  echo 'BASE_DOMAIN=localhost' >> .env
fi
if ! grep -q '^AGENT_SHARED_TOKEN=.' .env; then
  sed -i.bak '/^AGENT_SHARED_TOKEN=/d' .env
  echo 'AGENT_SHARED_TOKEN=dev-agent-token' >> .env
fi

# Generate admin hash if absent
if ! grep -q '^INITIAL_ADMIN_PASSWORD_HASH=\$argon2' .env; then
  HASH=$(python ../../traefik-control-plane-api/scripts/hash_password.py 'admin' 2>/dev/null || true)
  if [ -n "$HASH" ]; then
    sed -i.bak '/^INITIAL_ADMIN_PASSWORD_HASH=/d' .env
    echo "INITIAL_ADMIN_PASSWORD_HASH=$HASH" >> .env
  fi
fi
rm -f .env.bak

mkdir -p traefik/acme
touch traefik/acme/acme.json
chmod 600 traefik/acme/acme.json

docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.dev.yml ps
echo
echo "API:  http://localhost:8000/v1/healthz"
echo "UI:   http://localhost:5173"
echo "Traefik dashboard: http://localhost:8080"
echo "Default admin: admin / admin"
