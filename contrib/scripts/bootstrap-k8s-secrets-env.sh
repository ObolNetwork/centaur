#!/usr/bin/env bash
set -euo pipefail

# Bootstrap centaur-infra-env for ironProxy.secretSource=env (Obol local/prod path).
# Credentials are plain K8s Secret keys; iron-proxy reads them from env at runtime.

NAMESPACE="centaur"
FORCE=0

usage() {
  cat <<'EOF'
Usage: bootstrap-k8s-secrets-env.sh [--namespace NAMESPACE] [--force]

Creates centaur-infra-env for env-mode iron-proxy (no 1Password).

Required shell variables:
  SLACK_BOT_TOKEN
  SLACK_SIGNING_SECRET
  SLACKBOT_API_KEY
  At least one model key:
    ANTHROPIC_API_KEY     # Claude Code (Obol default; just smoke harness=claude-code)
    OPENAI_API_KEY        # Codex (just smoke harness=codex)

Optional:
  GITHUB_TOKEN            # git operations in sandboxes
  LOCAL_DEV_API_KEY       # admin API key seeded on first boot

Copy .env.obol-local.example to .env in the repo root; just loads it automatically.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)
      NAMESPACE="${2:?--namespace requires a value}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "FATAL: $name is required in the shell environment" >&2
    echo "       Copy .env.obol-local.example to .env and fill in values." >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FATAL: required command not found: $1" >&2
    exit 1
  fi
}

secret_exists() {
  kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1
}

delete_if_forced() {
  local name="$1"
  if [[ "$FORCE" == "1" ]]; then
    kubectl -n "$NAMESPACE" delete secret "$name" --ignore-not-found >/dev/null
  fi
}

rand_hex() {
  openssl rand -hex 32 | tr -d '\n'
}

require_cmd kubectl
require_cmd openssl
require_env SLACK_BOT_TOKEN
require_env SLACK_SIGNING_SECRET
require_env SLACKBOT_API_KEY
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
  echo "FATAL: set ANTHROPIC_API_KEY and/or OPENAI_API_KEY in the shell environment" >&2
  echo "       Obol local default: ANTHROPIC_API_KEY + just smoke harness=claude-code" >&2
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

delete_if_forced centaur-infra-env
delete_if_forced centaur-firewall-ca
delete_if_forced centaur-firewall-ca-key

if secret_exists centaur-infra-env && [[ "$FORCE" != "1" ]]; then
  echo "Secret centaur-infra-env already exists in namespace $NAMESPACE; leaving unchanged"
  echo "Re-run with --force after updating .env to rotate credentials."
else
  POSTGRES_PASSWORD="$(rand_hex)"
  DATABASE_URL="postgresql://tempo:${POSTGRES_PASSWORD}@centaur-centaur-postgres:5432/ai_v2"
  IRON_CONTROL_DATABASE_URL="${IRON_CONTROL_DATABASE_URL:-postgresql://tempo:${POSTGRES_PASSWORD}@centaur-centaur-postgres:5432}"
  IRON_CONTROL_INITIAL_USER_EMAIL="${IRON_CONTROL_INITIAL_USER_EMAIL:-admin@centaur.local}"

  secret_args=(
    -n "$NAMESPACE" create secret generic centaur-infra-env
    --from-literal=IRON_MANAGEMENT_API_KEY="$(rand_hex)"
    --from-literal=IRON_BROKER_TOKEN="$(rand_hex)"
    --from-literal=SANDBOX_SIGNING_KEY="$(rand_hex)"
    --from-literal=SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN"
    --from-literal=SLACK_SIGNING_SECRET="$SLACK_SIGNING_SECRET"
    --from-literal=SLACKBOT_API_KEY="$SLACKBOT_API_KEY"
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
    --from-literal=DATABASE_URL="$DATABASE_URL"
    --from-literal=IRON_CONTROL_DATABASE_URL="$IRON_CONTROL_DATABASE_URL"
    --from-literal=IRON_CONTROL_INITIAL_USER_EMAIL="$IRON_CONTROL_INITIAL_USER_EMAIL"
    --from-literal=IRON_CONTROL_INITIAL_USER_PASSWORD="$(rand_hex)"
    --from-literal=IRON_CONTROL_INITIAL_API_KEY="iak_$(rand_hex)"
    --from-literal=IRON_CONTROL_AR_ENCRYPTION_PRIMARY_KEY="$(rand_hex)"
    --from-literal=IRON_CONTROL_AR_ENCRYPTION_DETERMINISTIC_KEY="$(rand_hex)"
    --from-literal=IRON_CONTROL_AR_ENCRYPTION_KEY_DERIVATION_SALT="$(rand_hex)"
    --from-literal=IRON_CONTROL_SECRET_KEY_BASE="$(rand_hex)$(rand_hex)"
  )
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    secret_args+=(--from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
  fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    secret_args+=(--from-literal=OPENAI_API_KEY="$OPENAI_API_KEY")
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    secret_args+=(--from-literal=GITHUB_TOKEN="$GITHUB_TOKEN")
  fi
  if [[ -n "${LOCAL_DEV_API_KEY:-}" ]]; then
    secret_args+=(--from-literal=LOCAL_DEV_API_KEY="$LOCAL_DEV_API_KEY")
  fi
  kubectl "${secret_args[@]}" >/dev/null
  echo "Created Secret centaur-infra-env in namespace $NAMESPACE (env mode, no OP_* keys)"
fi

if secret_exists centaur-firewall-ca && secret_exists centaur-firewall-ca-key && [[ "$FORCE" != "1" ]]; then
  echo "Firewall CA Secrets already exist in namespace $NAMESPACE; leaving unchanged"
else
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT
  CA_KEY="$TMPDIR/ca-key.pem"
  CA_CERT="$TMPDIR/ca-cert.pem"

  openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "$CA_KEY" -sha256 -days 3650 \
    -subj "/CN=centaur iron-proxy CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign" \
    -out "$CA_CERT" >/dev/null 2>&1

  kubectl -n "$NAMESPACE" create secret generic centaur-firewall-ca \
    --from-file=ca-cert.pem="$CA_CERT" >/dev/null
  kubectl -n "$NAMESPACE" create secret generic centaur-firewall-ca-key \
    --from-file=ca-cert.pem="$CA_CERT" \
    --from-file=ca-key.pem="$CA_KEY" >/dev/null
  echo "Created firewall CA Secrets in namespace $NAMESPACE"
fi
