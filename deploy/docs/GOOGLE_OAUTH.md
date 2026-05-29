# Setting up Google OAuth for the Traefik Control Plane

## 1. Why

Google OAuth lets users sign in with their Google account instead of (or in addition to) the local username/password login. On first sign-in, Google-authenticated users are assigned the `viewer` role automatically. Promoting a user to `admin` must be done separately — see the SQL snippet in [§ 6 Test the flow](#6-test-the-flow).

---

## 2. Pre-requisites

- A **Google Cloud project** — create one at https://console.cloud.google.com/projectcreate  
- A reachable hostname for the API:
  - **Local dev:** `http://localhost:8001` works without HTTPS (Google treats `localhost` as a special case).
  - **Production:** the API must be accessible over HTTPS (e.g. `https://traefik-admin.example.com`).
- The `.env` file in `/home/yashv/code/node/traefik-controlpane/deploy/` ready to edit.

---

## 3. Google Cloud Console steps

### 3.1 Create or pick a project

Go to https://console.cloud.google.com/projectselector2/home/dashboard and select an existing project or create a new one.

### 3.2 Enable the Google People API

The Authlib OAuth client calls the People API to fetch the user's profile. Enable it at:

https://console.cloud.google.com/apis/library/people.googleapis.com

Click **Enable**. Wait a few seconds for activation.

### 3.3 Configure the OAuth consent screen

1. In the left nav, go to **APIs & Services → OAuth consent screen**.
2. Choose **User Type**:
   - **External** — any Google account can sign in (suitable for open or self-hosted installs). Starts in *Testing* mode (see § 7).
   - **Internal** — only users in your Google Workspace organisation can sign in.
3. Fill in the required fields:
   - **App name:** `Traefik Control Plane` (or anything descriptive)
   - **User support email:** your email address
   - **Authorized domains:** leave empty for dev; add your public domain (e.g. `example.com`) for prod.
4. On the **Scopes** step, add:
   - `openid`
   - `https://www.googleapis.com/auth/userinfo.email`
   - `https://www.googleapis.com/auth/userinfo.profile`
5. If **External + Testing**, add your Gmail address under **Test users**. Only listed users can sign in while the app is in Testing mode.
6. Save and continue through the remaining steps.

### 3.4 Create an OAuth 2.0 client ID

1. Go to **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. **Application type:** Web application.
3. **Name:** `Traefik Control Plane (dev)` — or use separate clients for dev and prod.
4. **Authorized JavaScript origins** — add the origins your UI and API are served from:

   | Environment | Origins to add |
   |-------------|----------------|
   | Dev | `http://localhost:5173`, `http://localhost:8001` |
   | Prod | `https://traefik-admin.example.com` |

5. **Authorized redirect URIs** — this must exactly match what the API sends:

   | Environment | Redirect URI |
   |-------------|--------------|
   | Dev | `http://localhost:8001/v1/auth/google/callback` |
   | Prod | `https://traefik-admin.example.com/api/v1/auth/google/callback` |

   > Note the `/api` prefix in production — Traefik strips it before forwarding to the API, so the API itself registers the callback at `/v1/auth/google/callback`, but the full public URI that Google calls includes `/api`.

6. Click **Create**.
7. A dialog displays your **Client ID** and **Client Secret**. Copy both now — the secret is not shown again.

---

## 4. Env vars to set

Edit `/home/yashv/code/node/traefik-controlpane/deploy/.env` and set:

```env
GOOGLE_CLIENT_ID=<paste the Client ID here>
GOOGLE_CLIENT_SECRET=<paste the Client Secret here>
```

Leave all other OAuth fields unchanged unless you are also configuring Microsoft or OIDC.

---

## 5. Apply the change

Restart only the API container to pick up the new env vars (no rebuild needed):

```bash
cd /home/yashv/code/node/traefik-controlpane/deploy
docker compose -f docker-compose.yml -f docker-compose.dev.yml restart control-api
```

Verify the provider is advertised:

```bash
curl -s http://localhost:8001/v1/auth/providers | python3 -m json.tool
# Expected: "google" appears in the list with enabled: true
```

---

## 6. Test the flow

1. Open http://localhost:5173 in your browser.
2. Click **Continue with Google**.
3. Sign in with a Google account that is listed as a test user (if in Testing mode).
4. You should be redirected back to the UI, logged in, with role `viewer`.

**Granting admin role via SQL:**

```bash
docker exec -it control-postgres psql -U control -d traefik_control \
  -c "INSERT INTO user_roles (user_id, role_id)
      SELECT u.id, r.id
      FROM users u, roles r
      WHERE u.email = '<your-google-email>'
        AND r.name = 'admin';"
```

---

## 7. Troubleshooting

| Symptom | Cause & fix |
|---------|-------------|
| `redirect_uri_mismatch` from Google | The redirect URI in the Google Console does not exactly match what the API sends. Check the scheme (`http` vs `https`), port, and path. Trailing slashes matter. |
| `Provider not configured` from `/v1/auth/providers` | The env vars were not loaded. Confirm `.env` was saved, then restart the container (`docker compose ... restart control-api`). |
| Only test users can sign in | Consent screen is in **Testing** mode. Add the user under *Test users*, or switch the consent screen to **Production** (triggers Google verification for External apps with sensitive scopes). |
| Users from other orgs cannot sign in | Consent screen is set to **Internal** (Workspace-only). Switch to External if you need non-Workspace accounts. |
| Login loop / session not persisting | `SESSION_SECRET` may have changed between restarts (invalidating existing sessions). Set a stable value in `.env`. |

---

## 8. Microsoft OAuth (brief reference)

The same flow applies to Microsoft / Entra ID login:

1. Go to https://entra.microsoft.com → **App registrations → New registration**.
2. Set the redirect URI to:
   - Dev: `http://localhost:8001/v1/auth/microsoft/callback`
   - Prod: `https://traefik-admin.example.com/api/v1/auth/microsoft/callback`
3. Under **Certificates & secrets**, create a client secret.
4. Set these env vars in `.env`:

```env
MICROSOFT_CLIENT_ID=<Application (client) ID>
MICROSOFT_CLIENT_SECRET=<client secret value>
MICROSOFT_TENANT_ID=common   # or your directory GUID / domain for single-tenant
```

5. Restart the API container as above.
