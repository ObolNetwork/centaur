# Obol local Centaur setup

Team runbook for kind + Slack E2E on a laptop. Full guide (with troubleshooting tables):

**[docs/pages/obol-local-setup.mdx](../docs/pages/obol-local-setup.mdx)** — also published in the Centaur docs site under *Start → Obol local setup*.

## Quick start

```bash
# Sibling repos
#   centaur/
#   obol-centaur-overlay/

kubectl config use-context kind-centaur
cd centaur
cp .env.obol-local.example .env   # fill Slack, Anthropic, GITHUB_TOKEN, SLACKBOT_API_KEY

just build && just build-obol-overlay && just kind-load
just bootstrap-secrets && just deploy
just smoke
```

Slack: `kubectl port-forward -n centaur svc/centaur-centaur-slackbot 3001:3001` + `ngrok http 3001` → webhook `/api/webhooks/slack`.

**Never** deploy with `kubectl` pointed at GKE unless you intend to. Always verify `kubectl config current-context`.
