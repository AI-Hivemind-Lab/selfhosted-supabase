#!/usr/bin/env bash
#
# generate-secrets.sh — produce a fresh .env for a self-hosted Supabase stack.
#
# Usage:
#   ./scripts/generate-secrets.sh > .env
#   chmod 600 .env
#
# Generates:
#   - POSTGRES_PASSWORD, JWT_SECRET, SECRET_KEY_BASE, PG_META_CRYPTO_KEY,
#     REALTIME_DB_ENC_KEY (16-char), DASHBOARD_PASSWORD
#   - HS256-signed ANON_KEY and SERVICE_ROLE_KEY against the new JWT_SECRET
#
# Leaves placeholders (CHANGEME / yourdomain.com / etc.) for fields that
# need human input: KONG_ALIAS, all hostnames, Google OAuth credentials.
#
# Requires: openssl, python3 (>= 3.6).

set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found" >&2
    exit 1
fi

POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 32)
PG_META_CRYPTO_KEY=$(openssl rand -hex 32)
REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)   # 16 chars, AES-128 needs exactly that
DASHBOARD_PASSWORD=$(openssl rand -hex 16)

# HS256-sign ANON_KEY and SERVICE_ROLE_KEY using the new JWT_SECRET.
read -r ANON_KEY SERVICE_ROLE_KEY <<<"$(JWT_SECRET="$JWT_SECRET" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
secret = os.environ["JWT_SECRET"]
def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def sign(role):
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"role": role, "iss": "supabase", "iat": int(time.time()), "exp": 1893456000}  # year 2030
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    p = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{b64url(sig)}"
print(sign("anon"), sign("service_role"))
PY
)"

cat <<EOF
############################################################
# Supabase Self-Hosted — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Random secrets are unique to this stack. Replace the
# CHANGEME / yourdomain.com fields before deploying.
############################################################

# ── Multi-stack disambiguation (REQUIRED) ───────────────
KONG_ALIAS=CHANGEME-kong

# ── PostgreSQL ──────────────────────────────────────────
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres

# ── JWT ─────────────────────────────────────────────────
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}

# ── URLs ─────────────────────────────────────────────────
SUPABASE_PUBLIC_URL=https://CHANGEME-supabase.yourdomain.com
API_EXTERNAL_URL=https://CHANGEME-supabase.yourdomain.com
SITE_URL=https://CHANGEME.yourdomain.com
ADDITIONAL_REDIRECT_URLS=https://CHANGEME.yourdomain.com/**,http://localhost:3000/**

# ── Dashboard / Studio ───────────────────────────────────
DASHBOARD_USERNAME=supabase
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
STUDIO_HOSTNAME=CHANGEME-studio.yourdomain.com

# ── Auth (GoTrue) ────────────────────────────────────────
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_JWT_EXP=3600

# ── Google OAuth ─────────────────────────────────────────
# TODO: create a NEW Google OAuth client per stack.
# Authorized redirect URI to register in Google Cloud Console:
#   https://CHANGEME-supabase.yourdomain.com/auth/v1/callback
GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=CHANGEME.apps.googleusercontent.com
GOTRUE_EXTERNAL_GOOGLE_SECRET=CHANGEME

# ── Storage ──────────────────────────────────────────────
FILE_SIZE_LIMIT=52428800

# ── Misc ─────────────────────────────────────────────────
SECRET_KEY_BASE=${SECRET_KEY_BASE}
REALTIME_DB_ENC_KEY=${REALTIME_DB_ENC_KEY}
PG_META_CRYPTO_KEY=${PG_META_CRYPTO_KEY}
EOF
