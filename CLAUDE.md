# CLAUDE.md

Guidance for Claude Code working in forks of this template.

## What this repo is

A multi-stack-safe template for self-hosted Supabase on Dokploy. The README has the full operational story; this file is the short architectural reference.

## Architecture (post-multi-stack-fix)

```
Browser → Traefik → Kong (only Kong on dokploy-network)
                       ↓
                  project-default network (auto-named <project>_default)
                       ├── db (PostgreSQL 17)
                       ├── db-setup (one-shot role-password fixup)
                       ├── auth (GoTrue)
                       ├── rest (PostgREST)
                       ├── realtime (alias: realtime-dev.supabase-realtime)
                       ├── storage + imgproxy
                       ├── meta (postgres-meta — Studio's backend)
                       └── studio
```

Two network membership rules — both load-bearing:

- **`kong` is on both `default` and `dokploy-network`.** Default lets it reach upstreams; dokploy-network exposes it to Traefik.
- **Every other service is on `default` only.** Putting them on dokploy-network is the bug that triggered the cross-stack `db` DNS collision.

## Key files

| File | What to know |
|------|--------------|
| `docker-compose.yml` | 9 services + db-setup. Uses `${KONG_ALIAS}` for the disambiguating alias on dokploy-network; required, fails fast if unset. |
| `volumes/api/kong.yml` | Kong declarative routing. `${VAR}` placeholders substituted at container start by `kong-startup.sh`. |
| `volumes/api/kong-startup.sh` | `sed`-substitutes env vars into kong.yml before Kong starts. Add a new `sed` line per new env var. |
| `scripts/generate-secrets.sh` | Source-of-truth recipe for fresh secrets. Includes HS256-signed ANON_KEY / SERVICE_ROLE_KEY. |
| `.env.example` | Annotated template. `.env` is gitignored. |

## The `supabase_admin` chicken-and-egg

`supabase/postgres` initializes `supabase_admin` with `POSTGRES_PASSWORD` **only on a fresh volume**. `db-setup` connects as `supabase_admin` and `ALTER ROLE`s the *other* internal roles. So:

- If `POSTGRES_PASSWORD` is unchanged across deploys → everything works.
- If `POSTGRES_PASSWORD` changed but the volume wasn't wiped → `supabase_admin` still has the old password; `db-setup` exits 2 with `28P01 password authentication failed`. Fix: wipe `<project>_db_data_v4`.

## Multi-stack DNS gotcha (the bug behind this template)

Two Supabase stacks on the same Dokploy host both register service-name aliases (`db`, `meta`, `auth`, `rest`, `studio`, `kong`) on the shared external network `dokploy-network`. Docker's embedded DNS returns ambiguous results. Symptoms observed in the wild:

- `db-setup` exit 2 (one stack's db-setup hit the other stack's db).
- Studio for stack A rendering stack B's tables (Kong-on-A's meta lookup hit stack B's meta).
- Pdfsearch app intermittent 401s (`SUPABASE_INTERNAL_URL=http://kong:8000` hit the wrong stack's Kong, JWT secret didn't validate).

Fix: keep internal services off `dokploy-network`, give each Kong a unique alias. Both are in this template.

## Critical gotchas

- **SITE_URL ≠ SUPABASE_PUBLIC_URL.** SITE_URL is your app; OAuth callbacks redirect to `SITE_URL/auth/callback`. Mixing them silently breaks login.
- **Dokploy env is source of truth.** Local `.env` is reference; Dokploy regenerates server-side `.env` from its UI on each deploy (when "Create Environment File" toggle is ON).
- **Adding domains in Dokploy requires a redeploy.** Kong's hostname-based routes don't update at runtime.
- **WebSocket support** must be enabled on the `<project>-supabase.*` Dokploy domain for Realtime.
- **Apps in the same docker network use `SUPABASE_INTERNAL_URL=http://${KONG_ALIAS}:8000`**, never the bare `kong`.
- **Do NOT mount** `./volumes/db/init` into `/docker-entrypoint-initdb.d` — that overrides the image's own init scripts and breaks role creation.

## Database roles

| Role | Used by | Notes |
|------|---------|-------|
| `supabase_admin` | db-setup, meta, realtime | Superuser. Password set by Postgres init from POSTGRES_PASSWORD. |
| `supabase_auth_admin` | GoTrue | Password reset by db-setup. |
| `supabase_storage_admin` | Storage | Password reset by db-setup; also gets BYPASSRLS. |
| `authenticator` | PostgREST | Switches to anon/authenticated based on JWT. Password reset by db-setup. |
| `service_role` | Admin API calls | Has BYPASSRLS by default; granted storage schema by db-setup. |

## Kong consumers

| Consumer | Auth | Access |
|----------|------|--------|
| ANON | `apikey: <ANON_KEY>` | Public API endpoints |
| SERVICE_ROLE | `apikey: <SERVICE_ROLE_KEY>` | All API endpoints (bypasses RLS via the role mapping) |
| DASHBOARD | HTTP Basic Auth (`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`) | Studio + pg-meta only |

## Editing checklist

- **Adding a new Kong route:** edit `kong.yml`. If it needs an env var, add a `sed` substitution in `kong-startup.sh` and pass the var via `docker-compose.yml`'s kong `environment:` block.
- **Adding a new auth provider:** add `GOTRUE_EXTERNAL_<PROVIDER>_*` to `docker-compose.yml`'s auth service env and to `.env.example`.
- **Bumping a service image:** edit `docker-compose.yml`. For Postgres major version bumps, follow `pg_upgrade`.
- **Adding env vars to the multi-stack contract:** update `.env.example`, `generate-secrets.sh`, and the README.
