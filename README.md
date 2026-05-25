# Self-Hosted Supabase Template

Dokploy-compatible Supabase stack, designed for safe **multi-stack** deployment on a single Dokploy host. Use this as the source-of-truth template; fork once per project.

**Stack:** PostgreSQL 17 · pgvector · GoTrue · PostgREST · Realtime · Storage · Kong · Studio
**Tested with:** Dokploy + Cloudflare Tunnel/Access ingress, Postgres 17.6.

---

## Quickstart (per project)

```bash
# 1. Fork this repo to your-org/selfhosted-supabase-for-<project>
# 2. Clone, generate secrets, fill placeholders
git clone git@github.com:your-org/selfhosted-supabase-for-<project>.git
cd selfhosted-supabase-for-<project>
./scripts/generate-secrets.sh > .env
chmod 600 .env

# 3. Edit .env — replace every CHANGEME placeholder:
#    KONG_ALIAS=<project>-kong              # MUST be unique per stack
#    SUPABASE_PUBLIC_URL=https://<project>-supabase.yourdomain.com
#    API_EXTERNAL_URL=https://<project>-supabase.yourdomain.com
#    SITE_URL=https://<project>.yourdomain.com
#    ADDITIONAL_REDIRECT_URLS=…
#    STUDIO_HOSTNAME=<project>-studio.yourdomain.com
#    GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID/SECRET (create a fresh OAuth client)

# 4. DNS: point <project>-supabase.* and <project>-studio.* at your Dokploy host
# 5. Deploy on Dokploy (see §Deployment)
```

---

## Deployment (Dokploy)

1. **New Compose service** pointing to your fork. Source type: GitHub.
2. **Environment** tab: paste the *entire* contents of your local `.env`. Toggle **Create Environment File** ON.
3. **Domains** tab: add two entries, both pointing at the `kong` service on port `8000`:
   - `<project>-supabase.yourdomain.com` — API gateway
   - `<project>-studio.yourdomain.com` — Studio (Kong routes by hostname)
4. Enable **WebSocket support** on the `<project>-supabase.*` domain (Realtime needs it).
5. Click **Deploy**. Watch logs until `db-setup-1 Exited (0)`.
6. **After adding/changing domains, you MUST redeploy.** (Dokploy banner says this; honor it.)

Verification:
```bash
curl -H "apikey: <ANON_KEY>" https://<project>-supabase.yourdomain.com/auth/v1/health
# → {"version":"...","name":"GoTrue",...}

curl -H "apikey: <ANON_KEY>" https://<project>-supabase.yourdomain.com/rest/v1/
# → OpenAPI JSON (PostgREST + db connectivity)
```

Studio:
1. Open `https://<project>-studio.yourdomain.com`
2. Basic-auth with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`

---

## Multi-stack — the most important section

Running 2+ Supabase stacks on the same Dokploy host **without** following these rules will silently break in subtle ways. We learned this the hard way; here's the distilled rulebook.

### Rule 1 — `KONG_ALIAS` must be unique per stack

Every Supabase Kong joins `dokploy-network` (the external network Dokploy uses for Traefik ingress). If two stacks both register the alias `kong`, any app on `dokploy-network` using `SUPABASE_INTERNAL_URL=http://kong:8000` will **round-robin** between them. Symptom: intermittent 401 errors (JWT secrets differ across stacks) or — worse — apps reading the wrong stack's data.

Fix (already in this template): set `KONG_ALIAS=<project>-kong` and point apps at `http://<project>-kong:8000`.

### Rule 2 — internal services live on the project-default network, never the shared one

Compose's project-default network is auto-named `<dokploy-compose-name>_default` — guaranteed unique. This template puts every service except Kong on that private network. **Do not "fix" this by moving `db`, `meta`, `auth`, etc. back onto `dokploy-network`** — that's what created the multi-stack DNS roulette in the first place.

If you ever see `pg-meta` / Studio rendering *another stack's* tables, it means Rule 1 or Rule 2 has been violated and a service is resolving short names (`db`, `meta`, etc.) across stacks.

### Rule 3 — every secret must be regenerated per stack

In particular `JWT_SECRET`. Re-using JWT_SECRET across stacks means a token forged by one Supabase is valid on the other — total cross-tenant compromise. `./scripts/generate-secrets.sh` ensures this.

### Rule 4 — Dokploy "environments" are a UI grouping, not a network boundary

Putting two stacks in different Dokploy environments does **not** isolate their docker networks. The external `dokploy-network` is host-wide. Rules 1–3 are what actually isolate.

### Rule 5 — each stack gets its own Google OAuth client

Don't share a single Google OAuth client across stacks. Create a fresh one per project, with authorized redirect URI:
```
https://<project>-supabase.yourdomain.com/auth/v1/callback
```

---

## Operational gotchas (read before you debug)

### `POSTGRES_PASSWORD` is locked at first init

The `supabase/postgres` image initializes `supabase_admin`'s password from `POSTGRES_PASSWORD` **only on a fresh data volume**. Changing `POSTGRES_PASSWORD` in `.env` after the volume is initialized does **not** change the password in the database. You'll see:

```
FATAL: 28P01: password authentication failed for user "supabase_admin"
```

Fix: wipe `db_data_v4` and `storage_data` volumes, redeploy. (`docker compose -p <project> down --volumes` from the Dokploy host, or "Delete Service" with the "Delete volumes" checkbox in Dokploy UI.)

### Dokploy's UI env is the source of truth, not your local `.env`

Local `.env` is reference / dev parity. Dokploy reads vars from its **Environment** tab and regenerates `.env` on the server at deploy time (only when the "Create Environment File" toggle is ON). If you edit local `.env` and don't paste into Dokploy → no effect on the running container.

### After changing Dokploy domains, redeploy

Adding a new domain in Dokploy → it needs a redeploy to take effect (Kong's `kong.yml` substitutes env vars at startup, so STUDIO_HOSTNAME changes require Kong restart).

### `db-setup` is non-optional

This stack uses `supabase/postgres` whose superuser is `supabase_admin`, not `postgres`. The image's built-in init creates `supabase_auth_admin`, `supabase_storage_admin`, `authenticator` with **hardcoded** passwords. `db-setup` runs after `db` is healthy and `ALTER ROLE`s them all to `POSTGRES_PASSWORD`. Without it, auth/storage/rest can't connect.

### Do not mount `./volumes/db/init` into `/docker-entrypoint-initdb.d`

That overrides the image's built-in init scripts and breaks role creation entirely. This template intentionally does not mount it.

### Studio's hostname-based routing

Studio is reachable via `STUDIO_HOSTNAME`, which Kong matches in `kong.yml`. The Dokploy Domain entry for `<project>-studio.*` must point at `kong:8000`, **not** `studio:3000`. Kong does the hostname-based proxy internally.

---

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All Supabase services. Kong-only on `dokploy-network`; everything else on project-default. |
| `.env.example` | Annotated template. Don't commit your real `.env`. |
| `scripts/generate-secrets.sh` | One-shot generator for all per-stack secrets including HS256-signed ANON/SERVICE_ROLE JWTs. |
| `volumes/api/kong.yml` | Kong declarative routing. Uses `${VAR}` placeholders. |
| `volumes/api/kong-startup.sh` | `sed`-substitutes env vars into `kong.yml` before Kong starts. |

---

## Connecting apps

Browser/client-side:
```env
NEXT_PUBLIC_SUPABASE_URL=https://<project>-supabase.yourdomain.com
NEXT_PUBLIC_SUPABASE_ANON_KEY=<ANON_KEY>
```

Server-side, app deployed in the same Dokploy docker network:
```env
SUPABASE_INTERNAL_URL=http://<project>-kong:8000   # NOT http://kong:8000
SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY>
```

Server-side bypasses Cloudflare / Traefik for internal calls. The KONG_ALIAS disambiguation in §Multi-stack §Rule 1 is the reason for the explicit `<project>-kong` form.

---

## Upgrading

- **Image versions** — bump in `docker-compose.yml`. Check the [Supabase self-hosting changelog](https://github.com/supabase/supabase/releases).
- **Postgres major** — needs `pg_upgrade`. Don't bump the major tag and redeploy without it.

---

## Backups

State lives in two named volumes per stack, prefixed by the Dokploy compose project name:

- `<project>_db_data_v4` — Postgres data
- `<project>_storage_data` — uploaded files

```bash
# Logical Postgres dump
docker exec <db-container> pg_dumpall -U supabase_admin > backup-$(date +%Y%m%d).sql

# Storage volume
docker run --rm -v <project>_storage_data:/data -v $(pwd):/backup alpine \
    tar czf /backup/storage-$(date +%Y%m%d).tar.gz -C /data .
```

For regulated content, schedule these via Dokploy cron or an external backup service. Single VM disk is not durable storage.

---

## Security notes

- RLS policies live in your app's database setup (run in Studio SQL editor after first deploy). This template doesn't seed any.
- Cloudflare Access in front of `<project>-supabase.*` and `<project>-studio.*` is recommended. If you use it, set `SUPABASE_INTERNAL_URL=http://<project>-kong:8000` for server-side calls to bypass the Access challenge.
- The `service_role` key has god-mode database access. Never ship it to a browser; never commit it.
- Rotate `JWT_SECRET` only by generating a new one *and* re-signing `ANON_KEY` / `SERVICE_ROLE_KEY` against it (the generator script does both).
