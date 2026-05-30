# Service inventory

Snapshot of every long-running process across the Storefronts Studio production surface, as of 2026-05-30.

---

## DigitalOcean droplet — `206.81.4.220` (NYC1, 2GB)

| PM2 name | Port | Code path | Repo | Serves |
|---|---|---|---|---|
| `ngr-ssr` | 4001 | `/var/www/sites/ngr-auto-schenectady/dist/.../server.mjs` | (no remote — local-only, deployed via rsync) | `ngr.storefronts.studio` |
| `petes-ssr` | 4002 | `/var/www/sites/petes-auto-schenectady/dist/.../server.mjs` | (no remote — local-only) | `petes.storefronts.studio` |
| `madethecut-ssr` | 4003 | `/var/www/sites/madethecut-brooklyn/dist/.../server.mjs` | (no remote — local-only) | `madethecut.storefronts.studio` |
| `claim-svc` | 4100 | `/var/www/sites/storefronts-claim/src/server.ts` | [storefronts-claim](https://github.com/doneup-inc/storefronts-claim) | `claim.storefronts.studio` |

**Reverse proxy:** Caddy 2.x, single Caddyfile at `/etc/caddy/Caddyfile`, wildcard SSL via Cloudflare DNS-01. CF token in `/etc/default/caddy` as `CF_API_TOKEN`. Also serves apex `storefronts.studio` + `doneup.us` as static sites from `/var/www/sites/storefronts-www/` and `/var/www/sites/doneup-www/`.

**Restart pattern:** `pm2 restart <name> --update-env` (always pass `--update-env` after `.env` changes).

**Logs:** `pm2 logs <name> --lines 50` (live) or `/root/.pm2/logs/<name>-{out,err}.log` (persisted).

---

## Cloudflare edge

| Worker | URL | Purpose |
|---|---|---|
| `storefronts-claim-notify` | `https://storefronts-claim-notify.greg-brownnyc.workers.dev` | Receives claim notification payloads from `claim-svc`, forwards to Resend API, sends from `claims@storefronts.studio`. Auth: `X-Claim-Secret` header (shared with `claim-svc`'s `NOTIFY_WORKER_SECRET` env var). |

Worker source: [storefronts-claim/worker/claims-notify-worker.js](https://github.com/doneup-inc/storefronts-claim/blob/main/worker/claims-notify-worker.js).

Deploy: `wrangler deploy` from `storefronts-claim/worker/`.

**Email routing:** Cloudflare Email Routing forwards inbound `greg@storefronts.studio` + `claims@storefronts.studio` + `privacy@storefronts.studio` → `greg.brownnyc@gmail.com`. Configured at Cloudflare → Email → Email Routing.

---

## Local-laptop processes (Greg's MacBook)

| launchd label | Schedule | What it does |
|---|---|---|
| `studio.storefronts.inbox-watcher` | Hourly 8am–10pm, 7 days/wk | Polls Gmail IMAP for new replies from prospects, fires macOS notification + creates Calendar event with 30-min-before lockscreen alarm |

Plist: `~/Library/LaunchAgents/studio.storefronts.inbox-watcher.plist`
Script: `~/.local/bin/storefronts-inbox-watcher.py`
State: `~/.storefronts/inbox-watcher.{db,log}`
Auth: Gmail app password in `~/.storefronts/.env` (chmod 600)

---

## External vendor inventory

| Vendor | Purpose | Auth artifact location |
|---|---|---|
| **DocuSign** (na4 prod) | Envelope creation + signing (JWT bearer auth) | `.env` on droplet + local — see [secrets.md](secrets.md) |
| **Stripe** (live mode) | Invoice creation, subscription billing, webhook events | `.env` on droplet + local |
| **Resend** | Outbound email from `claims@storefronts.studio` | Cloudflare Worker secret (in dashboard) |
| **Lob** (live mode) | Postcard printing + USPS first-class mailing | `storefronts-leads/.env` (Greg's laptop) |
| **Twilio** | Phone line-type lookup (mobile vs landline) | `storefronts-leads/.env` |
| **iPostal1** | Virtual mailbox / return address for postcards | Fresh Meadows NY 11365 (configured per-lead via `SENDER_*` env vars in `storefronts-leads/.env`) |
| **Google Workspace** | `greg.brownnyc@gmail.com` inbox (all Cloudflare email routes terminate here) | App password (16 chars) for IMAP only — `~/.storefronts/.env` |
