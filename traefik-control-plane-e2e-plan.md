# Traefik Control Plane for Homelab: End-to-End Execution Plan

## 1. Objective and Non-Goals

### Objective
Build a self-hosted Traefik Control Plane application with a modern UI to centrally manage Traefik routers, services, middlewares, TLS settings, and safe deployment workflows (validate, diff, apply, rollback) for the entire homelab.

### Non-Goals (Initial Phases)
- Replacing Traefik runtime itself.
- Managing Traefik static config from UI (keep static config as infrastructure-managed).
- First release support for every Traefik feature. Prioritize 80% common workflows first.

## 2. Product Scope

### Primary Personas
- Homelab Owner (Admin): full access.
- Operator: can propose and apply changes but cannot modify global security policies.
- Viewer: read-only access to topology and status.

### Must-Have Capabilities
1. CRUD for routers/services/middlewares with strong validation.
2. TLS management (resolver selection, domains, wildcard support, cert references).
3. ChangeSet workflow: draft -> validate -> review diff -> apply.
4. Rollback to previous known-good version.
5. Read-only runtime status from Traefik API.
6. Full audit trail (who changed what and when).
7. Domain inventory management (zones, subdomains, ownership tags, environment mapping).
8. DNS change management from UI (A/AAAA/CNAME/TXT/MX records) with preview and apply.
9. ACME lifecycle visibility (pending/issued/renewal/error states) and manual retry.

### Should-Have (Phase 2)
1. TCP/UDP route management.
2. Canary/weighted routing and failover policies.
3. Policy engine warnings and hard blocks.
4. Git approval flow (optional PR-based promotion).
5. DNS provider connectors (Cloudflare/Route53/PowerDNS) with unified adapter.

## 3. Source of Truth Strategy (Recommended)

Use **Traefik File Provider + GitOps-backed generated config**.

- UI/API writes to DB as canonical application state.
- Renderer generates Traefik dynamic YAML into versioned git repo.
- Apply agent deploys rendered files to Traefik dynamic config directory.
- Every apply ties to git commit SHA + app ChangeSet ID.

Why this approach:
- Deterministic and auditable.
- Easier rollback.
- Better control than docker labels for central UI.
- Works for mixed homelab environments.

## 4. Target Architecture

## 4.1 Components
1. Frontend (Vite + React + JavaScript + component library).
2. Backend API (FastAPI + Python).
3. PostgreSQL (metadata, authz, audit, config state).
4. Redis (optional: queues/locks/events).
5. Config Renderer (domain model -> Traefik dynamic YAML).
6. Git Adapter (commit/tag history for generated configs).
7. Apply Agent (writes config files and reports deployment status).
8. Secrets Provider Adapter (Vault/SOPS/env-injected references).
9. Observability stack (Loki/Prometheus/Grafana or equivalent).

## 4.2 Deployment Topology
- `traefik-control-ui` + `traefik-control-api` run separately from Traefik.
- `apply-agent` has controlled write access to Traefik dynamic config mount.
- Traefik static config points to that dynamic directory.
- mTLS or token auth between API and agent.

## 4.3 Failure Domain Design
- Control plane downtime must not stop existing traffic.
- Apply failure must not partially corrupt active config set.
- Agent writes to staging path then atomic swap/symlink switch.

## 5. Data Model (Concrete)

## 5.1 Core Tables
1. `users`
```sql
CREATE TABLE users (
  id UUID PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  auth_provider TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

2. `roles`
```sql
CREATE TABLE roles (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL UNIQUE CHECK (name IN ('admin', 'operator', 'viewer'))
);
```

3. `user_roles`
```sql
CREATE TABLE user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);
```

4. `environments`
```sql
CREATE TABLE environments (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

5. `entrypoints`
```sql
CREATE TABLE entrypoints (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  protocol TEXT NOT NULL CHECK (protocol IN ('http', 'tcp', 'udp')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, name)
);
```

6. `services`
```sql
CREATE TABLE services (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  protocol TEXT NOT NULL CHECK (protocol IN ('http', 'tcp', 'udp')),
  pass_host_header BOOLEAN NOT NULL DEFAULT TRUE,
  sticky_cookie_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  healthcheck_path TEXT,
  healthcheck_interval TEXT,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, name)
);
```

7. `service_servers`
```sql
CREATE TABLE service_servers (
  id UUID PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
  is_backup BOOLEAN NOT NULL DEFAULT FALSE,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (service_id, url)
);
```

8. `middlewares`
```sql
CREATE TABLE middlewares (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  config_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, name)
);
```

9. `tls_profiles`
```sql
CREATE TABLE tls_profiles (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  cert_resolver TEXT,
  options_ref TEXT,
  domains_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, name)
);
```

10. `routers`
```sql
CREATE TABLE routers (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  protocol TEXT NOT NULL CHECK (protocol IN ('http', 'tcp', 'udp')),
  rule TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  service_id UUID REFERENCES services(id) ON DELETE RESTRICT,
  tls_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  tls_profile_id UUID REFERENCES tls_profiles(id) ON DELETE SET NULL,
  entrypoints_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, name)
);
```

11. `router_middlewares`
```sql
CREATE TABLE router_middlewares (
  router_id UUID NOT NULL REFERENCES routers(id) ON DELETE CASCADE,
  middleware_id UUID NOT NULL REFERENCES middlewares(id) ON DELETE RESTRICT,
  order_index INTEGER NOT NULL CHECK (order_index >= 0),
  PRIMARY KEY (router_id, middleware_id),
  UNIQUE (router_id, order_index)
);
```

12. `changesets`
```sql
CREATE TABLE changesets (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  state TEXT NOT NULL CHECK (state IN ('draft', 'validated', 'approved', 'applied', 'failed', 'rolled_back')),
  proposed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  target_version TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

13. `changeset_items`
```sql
CREATE TABLE changeset_items (
  id UUID PRIMARY KEY,
  changeset_id UUID NOT NULL REFERENCES changesets(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('router', 'service', 'middleware', 'tls_profile')),
  entity_id UUID NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
  before_json JSONB,
  after_json JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

14. `deployments`
```sql
CREATE TABLE deployments (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  changeset_id UUID REFERENCES changesets(id) ON DELETE SET NULL,
  git_commit_sha TEXT NOT NULL,
  rendered_bundle_checksum TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'applying', 'success', 'failed', 'rolled_back')),
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  error_text TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

15. `audit_events`
```sql
CREATE TABLE audit_events (
  id UUID PRIMARY KEY,
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

16. `secrets_refs`
```sql
CREATE TABLE secrets_refs (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  key_name TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('vault', 'sops', 'env')),
  external_ref TEXT NOT NULL,
  last_verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, key_name)
);
```

17. `dns_zones`
```sql
CREATE TABLE dns_zones (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  zone_name TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('cloudflare', 'route53', 'powerdns', 'manual')),
  provider_config_ref TEXT NOT NULL,
  is_authoritative BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (environment_id, zone_name)
);
```

18. `dns_records`
```sql
CREATE TABLE dns_records (
  id UUID PRIMARY KEY,
  zone_id UUID NOT NULL REFERENCES dns_zones(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('A', 'AAAA', 'CNAME', 'TXT', 'MX', 'SRV', 'CAA')),
  value TEXT NOT NULL,
  ttl INTEGER NOT NULL DEFAULT 300 CHECK (ttl >= 60),
  priority INTEGER,
  proxied BOOLEAN,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

19. `certificates`
```sql
CREATE TABLE certificates (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  common_name TEXT NOT NULL,
  san_json JSONB NOT NULL DEFAULT '[]'::jsonb,
  issuer TEXT,
  resolver_name TEXT,
  not_before TIMESTAMPTZ,
  not_after TIMESTAMPTZ,
  renewal_window_days INTEGER NOT NULL DEFAULT 30,
  status TEXT NOT NULL CHECK (status IN ('pending', 'issued', 'renewing', 'expired', 'error')),
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

20. `dns_change_requests`
```sql
CREATE TABLE dns_change_requests (
  id UUID PRIMARY KEY,
  environment_id UUID NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  requested_by UUID REFERENCES users(id) ON DELETE SET NULL,
  state TEXT NOT NULL CHECK (state IN ('draft', 'validated', 'approved', 'applied', 'failed', 'rolled_back')),
  changes_json JSONB NOT NULL,
  provider_transaction_id TEXT,
  error_text TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

## 5.2 Constraints
- Unique `(environment_id, name)` for routers/services/middlewares.
- Prevent deleting service if referenced by active router unless force with explicit migration path.
- Middleware ordering unique per router.

## 6. API Contract (v1)

Base path: `/api/v1`

### Auth and Access
- `POST /auth/login` (OIDC redirect start)
- `GET /auth/callback`
- `POST /auth/logout`
- `GET /me`

### Routers
- `GET /environments/{envId}/routers`
- `POST /environments/{envId}/routers`
- `GET /environments/{envId}/routers/{id}`
- `PUT /environments/{envId}/routers/{id}`
- `DELETE /environments/{envId}/routers/{id}`
- `POST /environments/{envId}/routers/{id}/validate`

### Services
- `GET/POST/PUT/DELETE /environments/{envId}/services...`

### Middlewares
- `GET/POST/PUT/DELETE /environments/{envId}/middlewares...`

### TLS Profiles
- `GET/POST/PUT/DELETE /environments/{envId}/tls-profiles...`

### Domains, DNS, and Certificates
- `GET/POST/PUT/DELETE /environments/{envId}/dns/zones`
- `GET/POST/PUT/DELETE /environments/{envId}/dns/zones/{zoneId}/records`
- `POST /environments/{envId}/dns/change-requests`
- `POST /environments/{envId}/dns/change-requests/{id}/validate`
- `POST /environments/{envId}/dns/change-requests/{id}/apply`
- `POST /environments/{envId}/dns/change-requests/{id}/rollback`
- `GET /environments/{envId}/certificates`
- `POST /environments/{envId}/certificates/{id}/renew`
- `GET /environments/{envId}/certificates/{id}/events`

### ChangeSets and Deployments
- `POST /environments/{envId}/changesets`
- `POST /environments/{envId}/changesets/{id}/validate`
- `GET /environments/{envId}/changesets/{id}/diff`
- `POST /environments/{envId}/changesets/{id}/approve`
- `POST /environments/{envId}/changesets/{id}/apply`
- `POST /environments/{envId}/deployments/{id}/rollback`
- `GET /environments/{envId}/deployments`

### Runtime Status
- `GET /environments/{envId}/runtime/routers`
- `GET /environments/{envId}/runtime/services`
- `GET /environments/{envId}/runtime/health`

### Audit
- `GET /environments/{envId}/audit-events`

## 7. Validation and Policy Engine

## 7.1 Static Validation Rules
1. Router rule syntax validity.
2. Conflict detection for same host/path + entrypoint overlap.
3. Priority collision detection with warning or block.
4. Middleware schema validation per type.
5. Redirect loop detection (http/https and path rewrite chain).
6. Service target URL and protocol validation.
7. TLS profile completeness checks.
8. DNS record conflicts (duplicate host/type, CNAME with sibling records, invalid apex CNAME).
9. ACME prerequisites validation (resolver, DNS challenge tokens, required TXT permissions).

## 7.2 Runtime Guardrails
1. Block apply when referenced service has zero enabled servers.
2. Block apply if critical route loses authentication unexpectedly (unless override by admin with reason).
3. Block dangerous public exposure patterns based on policy config.
4. Enforce rate-limit and auth on tagged sensitive apps.

## 7.3 Policy Severity Model
- `info`: advisory.
- `warn`: can apply with acknowledgement.
- `error`: cannot apply.

## 8. Config Generation and Apply Workflow

### 8.1 Rendering Pipeline
1. Load active state + changeset delta.
2. Build in-memory canonical model.
3. Render deterministic YAML split by object type:
- `routers/*.yaml`
- `services/*.yaml`
- `middlewares/*.yaml`
- `tls/*.yaml`
4. Compute checksum and semantic diff vs active bundle.
5. Run dry parse against Traefik schema checker (custom + integration validation).

### 8.2 Apply Pipeline
1. Acquire environment deployment lock.
2. Commit rendered bundle to git with metadata.
3. Push to agent staging directory.
4. Agent validates file integrity.
5. Atomic activation (symlink swap or dir rename).
6. Poll Traefik `/api/rawdata` and health endpoints.
7. Mark deployment success or auto-rollback.

### 8.3 Rollback Strategy
- Rollback by previous successful deployment ID.
- Re-activate previous checksum bundle.
- Record rollback reason and actor.

## 9. Frontend UX Blueprint

## 9.1 Main Screens
1. Dashboard
- route/service health summary
- recent deployments
- validation warnings

2. Topology Explorer
- domain -> router -> middleware chain -> service endpoints

3. Routers Page
- table + quick filters + bulk actions
- create/edit drawer with live validation

4. Services Page
- upstream server management
- healthcheck and sticky settings

5. Middlewares Library
- typed forms per middleware
- reusable middleware templates

6. TLS and Certificates
- resolver mapping
- domain coverage visualization

7. Change Review
- structured diff (before/after)
- policy warnings with acknowledgment controls

8. Deployments and Rollbacks
- timeline, status, logs, one-click rollback

9. Audit Log
- actor, action, entity, timestamp, correlated deployment

## 9.2 UX Requirements
- Autosave drafts.
- Dirty-state prompts.
- Deterministic ordering for middleware chain UI.
- Inline examples for Traefik rule expressions.
- Keyboard-friendly power-user flows.

## 10. Security Plan

1. Multi-provider auth:
- OIDC SSO (primary) via Keycloak/Auth0/Authentik.
- Google OAuth (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`).
- Microsoft OAuth (`MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, tenant config).
- Local username/password login for homelab fallback and break-glass admin.
2. RBAC with backend enforcement (never UI-only).
3. Secrets never stored in plaintext; only references in DB.
4. Signed and immutable audit entries (hash chain or WORM destination optional).
5. CSRF protection and secure cookie/session configuration.
6. Optional MFA requirement for apply/rollback actions.
7. Sensitive action confirmation requiring typed confirmation text.

## 11. Observability and Operations

1. Structured logs with request ID and deployment ID correlation.
2. Metrics:
- apply_duration_seconds
- apply_failure_total
- validation_error_total
- rollback_total
- active_router_count

3. Alerts:
- deployment failed
- rollback occurred
- certificate expiration threshold
- runtime route mismatch between desired and active

4. Tracing:
- API request -> renderer -> agent -> health-check span chain.

## 12. Environment and Infrastructure Setup

## 12.1 Environments
- `dev`: local docker-compose with mock Traefik.
- `staging`: real Traefik instance with non-critical routes.
- `prod`: primary homelab Traefik.

## 12.2 IaC Requirements
- Docker Compose for quick start.
- Optional Helm chart if migrating to Kubernetes later.
- Secret injection through `.env` only in dev; Vault/SOPS in staging/prod.

## 12.3 Single-Stack Docker Compose (Traefik + Control Plane)
Use one stack so Traefik and the control plane are deployed together, while still isolating runtime responsibilities.

```yaml
version: "3.9"

services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --providers.file.directory=/etc/traefik/dynamic/active
      - --providers.file.watch=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/etc/traefik/acme/acme.json
      - --certificatesresolvers.le.acme.dnschallenge=true
      - --certificatesresolvers.le.acme.dnschallenge.provider=${ACME_DNS_PROVIDER}
      - --log.level=INFO
      - --accesslog=true
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
      - AWS_REGION=${AWS_REGION}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/static:/etc/traefik/static:ro
      - ./traefik/dynamic/active:/etc/traefik/dynamic/active
      - ./traefik/dynamic/staging:/etc/traefik/dynamic/staging
      - ./traefik/acme:/etc/traefik/acme
    networks:
      - edge
      - control

  control-api:
    image: ghcr.io/yourorg/traefik-control-api:latest
    container_name: control-api
    restart: unless-stopped
    environment:
      - APP_ENV=production
      - DATABASE_URL=postgres://control:${POSTGRES_PASSWORD}@postgres:5432/traefik_control
      - REDIS_URL=redis://redis:6379
      - OIDC_ISSUER=${OIDC_ISSUER}
      - OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
      - OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
      - AGENT_SHARED_TOKEN=${AGENT_SHARED_TOKEN}
      - API_HOST=0.0.0.0
      - API_PORT=8000
      - API_ROOT_PATH=/api
      - CORS_ALLOWED_ORIGINS=https://traefik-admin.${BASE_DOMAIN}
    labels:
      - traefik.enable=true
      - traefik.http.routers.control-api.rule=Host(`traefik-admin.${BASE_DOMAIN}`) && PathPrefix(`/api`)
      - traefik.http.routers.control-api.entrypoints=websecure
      - traefik.http.routers.control-api.tls=true
      - traefik.http.routers.control-api.tls.certresolver=le
      - traefik.http.services.control-api.loadbalancer.server.port=8000
    depends_on:
      - postgres
      - redis
    networks:
      - edge
      - control

  control-ui:
    image: ghcr.io/yourorg/traefik-control-ui:latest
    container_name: control-ui
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - VITE_API_BASE_URL=/api
    labels:
      - traefik.enable=true
      - traefik.http.routers.control-ui.rule=Host(`traefik-admin.${BASE_DOMAIN}`)
      - traefik.http.routers.control-ui.entrypoints=websecure
      - traefik.http.routers.control-ui.tls=true
      - traefik.http.routers.control-ui.tls.certresolver=le
      - traefik.http.services.control-ui.loadbalancer.server.port=3000
    depends_on:
      - control-api
    networks:
      - edge
      - control

  apply-agent:
    image: ghcr.io/yourorg/traefik-control-agent:latest
    container_name: apply-agent
    restart: unless-stopped
    environment:
      - API_URL=http://control-api:8080
      - AGENT_SHARED_TOKEN=${AGENT_SHARED_TOKEN}
      - TRAEFIK_DYNAMIC_STAGING_DIR=/etc/traefik/dynamic/staging
      - TRAEFIK_DYNAMIC_ACTIVE_DIR=/etc/traefik/dynamic/active
    volumes:
      - ./traefik/dynamic/active:/etc/traefik/dynamic/active
      - ./traefik/dynamic/staging:/etc/traefik/dynamic/staging
    depends_on:
      - control-api
    networks:
      - control

  postgres:
    image: postgres:16
    container_name: control-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=traefik_control
      - POSTGRES_USER=control
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - control

  redis:
    image: redis:7-alpine
    container_name: control-redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    networks:
      - control

volumes:
  postgres_data:
  redis_data:

networks:
  edge:
  control:
```

Notes:
- Keep `./traefik/acme/acme.json` permission at `600`.
- Use DNS challenge for wildcard certs.
- Do not let UI/API write directly to `active`; only `apply-agent` can promote `staging` to `active`.

## 12.4 Routing and Base URL Setup (Control UI + Control API)

Recommended public routing model (single domain):
- Control plane base domain: `https://traefik-admin.${BASE_DOMAIN}`
- UI routes: `https://traefik-admin.${BASE_DOMAIN}/`
- API routes: `https://traefik-admin.${BASE_DOMAIN}/api/*`

Traefik routers:
1. `control-ui` router
- Rule: `Host(traefik-admin.${BASE_DOMAIN})`
- Service target: `control-ui:3000`

2. `control-api` router
- Rule: `Host(traefik-admin.${BASE_DOMAIN}) && PathPrefix(/api)`
- Service target: `control-api:8000`

FastAPI setup:
- Set `root_path=/api` so OpenAPI/docs and generated links are consistent when served behind Traefik path prefix.
- Bind app to `0.0.0.0:8000`.
- CORS should allow only `https://traefik-admin.${BASE_DOMAIN}` unless there is a second UI origin.

Vite frontend setup (JavaScript only):
- Use `VITE_API_BASE_URL=/api` in production.
- All frontend API clients should build URLs from `import.meta.env.VITE_API_BASE_URL`.
- Avoid hardcoding container DNS names in browser code.

Example JavaScript API client:
```javascript
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "/api";

export async function apiFetch(path, options = {}) {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    credentials: "include",
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`API ${response.status}: ${text}`);
  }
  return response.status === 204 ? null : response.json();
}
```

## 13. Delivery Plan

## Phase 0: Foundations
- Finalize requirements, threat model, architecture decision record.
- Define protobuf/openapi schemas and DB migrations.
- Set up repos, CI, linting, test harness.

Exit Criteria:
- Approved ADRs and initial CI green.

## Phase 1: Core Domain + CRUD
- Implement DB schema and repositories.
- Build Routers/Services/Middlewares/TLS CRUD APIs.
- Implement frontend basic pages/forms.
- Add static validation engine.

Exit Criteria:
- Create/edit/delete entities from UI with validation.

## Phase 2: ChangeSets + Diff + Apply
- Implement changeset lifecycle.
- Build renderer and diff endpoint.
- Implement apply agent and deployment lock.
- Add deployment status UI.

Exit Criteria:
- Draft -> validate -> apply works end-to-end in dev.

## Phase 3: Rollback + Runtime Sync
- Deployment history and rollback support.
- Read-only Traefik API runtime ingestion.
- Drift detection between desired and runtime state.

Exit Criteria:
- Rollback verified and drift alerts visible.

## Phase 4: Security + RBAC + Audit
- OIDC integration.
- RBAC and guarded actions.
- Signed audit log pipeline.

Exit Criteria:
- Role tests pass; audit complete for all critical operations.

## Phase 5: Hardening + Production Rollout
- Load tests, failure drills, chaos scenarios.
- Backup/restore verification.
- Staged rollout and cutover runbook.

Exit Criteria:
- Production-ready checklist fully passed.

## 14. Comprehensive Testing Strategy

## 14.1 Unit Tests
- Rule parser helpers.
- Middleware config schema validation.
- Conflict detection logic.
- YAML renderer determinism.

## 14.2 Integration Tests
- API + DB + renderer path.
- Apply agent with test Traefik container.
- Rollback scenarios.

## 14.3 End-to-End Tests
- Create protected app route and verify auth.
- Add redirect middleware and verify no loop.
- Simulate invalid config and confirm blocked apply.

## 14.4 Non-Functional Tests
- Concurrency: simultaneous edits on same route.
- Performance: 500+ routers render/apply SLA.
- Resilience: agent crash mid-deploy.
- Security: authz bypass attempts, CSRF tests.

## 15. Risk Register and Mitigation

1. Risk: Misapplied config causes outage.
- Mitigation: validation gate + atomic apply + health-check rollback.

2. Risk: Let’s Encrypt rate limits.
- Mitigation: staging resolver for tests; domain batching safeguards.

3. Risk: Lockout via auth middleware misconfig.
- Mitigation: emergency bypass route + break-glass admin runbook.

4. Risk: Config drift from manual edits.
- Mitigation: drift detection + optional read-only lock on dynamic config path.

5. Risk: Scope creep (too many Traefik features early).
- Mitigation: strict MVP boundaries and backlog triage.

## 16. Runbooks (Must Create)

1. Failed deployment recovery.
2. Emergency rollback procedure.
3. Certificate failure troubleshooting.
4. Auth outage and break-glass login.
5. DB restore and config repo restore.
6. Agent connectivity failure diagnostics.

## 17. Acceptance Criteria (Production Go-Live)

1. 100% critical routes managed via control plane.
2. Zero manual edits to dynamic config for 30 days.
3. Successful rollback drill under 5 minutes.
4. All apply actions fully audited.
5. No P1 incidents caused by control plane in 30-day observation window.

## 18. Backlog After Go-Live

1. TCP/UDP advanced templates.
2. Multi-Traefik cluster federation.
3. Policy-as-code (OPA/CEL).
4. Git PR approval workflow.
5. Smart recommendations (unused middleware cleanup, conflict auto-fixes).

## 19. Immediate Next Actions

1. Confirm stack:
- Backend: FastAPI + Python.
- Frontend: Vite + React + JavaScript.
- DB: PostgreSQL.

2. Create repos:
- `traefik-control-plane-api`
- `traefik-control-plane-ui`
- `traefik-control-plane-agent`
- `traefik-control-plane-config` (generated bundle history)

3. Build first vertical slice:
- Create service
- Create router
- Validate
- Render YAML
- Apply to test Traefik
- Confirm route works

4. Lock MVP boundary document and milestone dates.
5. Stand up the single-stack Docker Compose locally and validate:
- UI reachable at `https://traefik-admin.<your-domain>`.
- DNS challenge successfully issues a cert.
- API can create a DNS change request and apply it to provider sandbox.
6. Generate runnable baseline infrastructure files in a dedicated folder:
- `deploy/docker-compose.yml`
- `deploy/.env.example`
- `deploy/traefik/static/traefik.yml`
- `deploy/traefik/dynamic/active/.gitkeep`
- `deploy/traefik/dynamic/staging/.gitkeep`
- `deploy/traefik/acme/.gitkeep`
- Include a short `deploy/README.md` with bring-up commands and permissions steps (`acme.json` with `600`).

## 20. Implementation Deliverable: Production-Ready Stack Files

Create these files as the first executable artifact so the stack can run directly:

1. `deploy/docker-compose.yml`
- Includes Traefik, control-ui, control-api, apply-agent, postgres, redis.
- Uses environment variables only from `.env`.
- Mounts dynamic config directories for staged/active promotion.

2. `deploy/.env.example`
- Includes all required keys with placeholders:
`BASE_DOMAIN`, `ACME_EMAIL`, `ACME_DNS_PROVIDER`, provider credentials, `POSTGRES_PASSWORD`, `OIDC_*`, `AGENT_SHARED_TOKEN`.
- Also include:
`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `MICROSOFT_TENANT_ID`, `LOCAL_AUTH_ENABLED`, `INITIAL_ADMIN_USERNAME`, `INITIAL_ADMIN_PASSWORD_HASH`.

3. `deploy/traefik/static/traefik.yml`
- Static Traefik configuration for entrypoints, providers, logging, API, and certificate resolver wiring.

4. Supporting directories and placeholders
- Ensure dynamic and acme paths exist in git with `.gitkeep`.
- Document one-time creation and permission hardening for `acme.json`.

5. `deploy/README.md`
- Contains exact commands:
`cp .env.example .env`, `touch traefik/acme/acme.json`, `chmod 600 traefik/acme/acme.json`, `docker compose up -d`.
- Includes initial verification checklist for UI, cert issuance, and health endpoints.

---

## Appendix A: Suggested Tech Choices

- Backend: FastAPI + Uvicorn, SQLAlchemy + Alembic, Pydantic v2.
- Frontend: Vite + React (JavaScript), React Hook Form + Zod, TanStack Query.
- Auth:
- Keycloak/Auth0/Authentik via OIDC.
- Google OAuth (client ID/secret).
- Microsoft OAuth (client ID/secret + tenant).
- Local username/password (bcrypt/argon2 hash storage, rate limiting, lockout policy).
- Queue/Locking: Redis Redlock or Postgres advisory locks.
- Diff Viewer: Monaco diff or `react-diff-view`.
- Deployment: Docker Compose initially; optional Nomad/K8s later.

## Appendix B: API Error Model

Standard response:
```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Router rule conflicts with existing route",
    "details": [
      {
        "field": "rule",
        "reason": "host/path overlap on entrypoint websecure",
        "conflicts_with": "router:app-main"
      }
    ],
    "request_id": "req_..."
  }
}
```

## Appendix C: Definition of Done for Each Feature

1. API implemented with authz checks.
2. UI flow completed and accessible.
3. Unit + integration tests pass.
4. Audit events emitted.
5. Documentation updated.
6. Observability hooks added.
