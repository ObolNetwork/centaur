#!/usr/bin/env bash
# Step 4 local E2E: spawn an agent sandbox and run centaur-dispatch-pr inside it.
#
# Usage (from centaur repo root, kind cluster running):
#   contrib/scripts/local-dispatch-sandbox-smoke.sh
#   contrib/scripts/local-dispatch-sandbox-smoke.sh --dispatch   # real dispatch, not dry-run
#
# Requires: dv-launchpad in repoCache, obol-centaur-overlay image deployed, GITHUB_TOKEN in centaur-infra-env.

set -euo pipefail

NAMESPACE="${CENTAUR_NAMESPACE:-centaur}"
RELEASE="${CENTAUR_RELEASE:-centaur}"
API_DEPLOY="deploy/${RELEASE}-centaur-api"
REPO="${DISPATCH_TEST_REPO:-ObolNetwork/dv-launchpad}"
BASE_REF="${DISPATCH_TEST_BASE_REF:-main}"
DRY_RUN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dispatch) DRY_RUN=0; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing command: $1" >&2; exit 1; }
}

require_cmd kubectl
require_cmd jq

api_curl() {
  kubectl exec -n "$NAMESPACE" "$API_DEPLOY" -c api -- \
    sh -lc 'curl -sf -H "x-api-key: ${SLACKBOT_API_KEY:?missing SLACKBOT_API_KEY}" "$@"' sh "$@"
}

echo "==> spawning sandbox (harness=claude-code)..."
THREAD_KEY="dispatch-sandbox-$(date +%s)"
SPAWN="$(api_curl -X POST http://localhost:8000/agent/spawn \
  -H "Content-Type: application/json" \
  -d "{\"thread_key\":\"${THREAD_KEY}\",\"harness\":\"claude-code\"}")"
ASSIGNMENT_GENERATION="$(printf '%s' "$SPAWN" | jq -r '.assignment_generation')"
SANDBOX_ID="$(printf '%s' "$SPAWN" | jq -r '.sandbox_id // .session_id // empty')"
if [[ -z "$SANDBOX_ID" ]]; then
  SANDBOX_ID="$(kubectl get pods -n "$NAMESPACE" -l centaur.ai/managed=true \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}')"
fi
echo "    thread_key=$THREAD_KEY sandbox_id=${SANDBOX_ID:-unknown}"

echo "==> waiting for sandbox pod..."
for _ in $(seq 1 90); do
  POD="$(kubectl get pods -n "$NAMESPACE" -l "centaur.ai/managed=true,centaur.ai/sandbox-id=${SANDBOX_ID}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$POD" ]]; then
    POD="$(kubectl get pods -n "$NAMESPACE" -l centaur.ai/managed=true \
      --field-selector=status.phase=Running \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -n "$POD" ]]; then
    phase="$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" ]]; then
      break
    fi
  fi
  sleep 2
done

[[ -n "${POD:-}" ]] || { echo "FATAL: sandbox pod did not become ready" >&2; exit 1; }
echo "    pod=$POD"

OVERLAY_SCRIPT="/home/agent/overlay/org/scripts/centaur-dispatch-pr.sh"
GITHUB_REPO="/home/agent/github/${REPO}"

run_in_sandbox() {
  kubectl exec -n "$NAMESPACE" "$POD" -c sandbox -- bash -lc "$1"
}

echo "==> checking sandbox prerequisites..."
if ! run_in_sandbox "test -x '${OVERLAY_SCRIPT}'"; then
  echo "FATAL: missing ${OVERLAY_SCRIPT}" >&2
  run_in_sandbox 'ls -laR /home/agent/overlay 2>&1 | head -40' || true
  exit 1
fi
if ! run_in_sandbox "test -d '${GITHUB_REPO}/.git'"; then
  echo "FATAL: repo not in sandbox cache: ${GITHUB_REPO}" >&2
  run_in_sandbox 'ls -la /home/agent/github 2>&1; ls -laR /home/agent/github 2>&1 | head -60' || true
  echo "Hint: ensure ${REPO} is in values.obol-local.yaml repoCache and repo-cache pod is 1/1 Ready" >&2
  exit 1
fi

echo "==> git-branch + edit + dispatch..."
SLUG="sandbox-$(date +%s)"
DISPATCH_FLAGS="--repo ${REPO} --base-ref ${BASE_REF} --title 'docs: centaur sandbox dispatch' --body 'Step 4 kind sandbox smoke'"
if [[ "$DRY_RUN" -eq 1 ]]; then
  DISPATCH_FLAGS="--dry-run ${DISPATCH_FLAGS}"
fi

run_in_sandbox "
set -euo pipefail
git-branch '${REPO}' '${SLUG}'
WORKDIR=~/branches/${REPO}
cd \"\$WORKDIR\"
printf '%s\n' '<!-- centaur sandbox step 4 -->' >> docs/LAUNCHPAD_UI_CHANGELOG.md
'${OVERLAY_SCRIPT}' \
  ${DISPATCH_FLAGS} \
  --cwd \"\$WORKDIR\"
"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> dry-run OK. Re-run with --dispatch to fire repository_dispatch."
else
  echo "==> dispatch sent. Check GitHub Actions on ${REPO}."
fi

echo "==> sandbox pod left running: $POD (delete with: kubectl delete pod -n $NAMESPACE $POD)"
