# Secrets — location map

Where every production secret lives. **No values in this file.** Use this for recovery, rotation, or handing off operational access.

All `.env` files are chmod 600 and gitignored. Never commit them.

---

## `storefronts-claim` (on droplet at `/var/www/sites/storefronts-claim/.env`)

| Env var | Vendor | What it is | How to rotate |
|---|---|---|---|
| `STRIPE_SECRET_KEY` | Stripe | Live API key (`sk_live_…`) | Stripe Dashboard → Developers → API keys → Roll key |
| `STRIPE_WEBHOOK_SECRET` | Stripe | Webhook signing secret (`whsec_…`) for `claim.storefronts.studio/v1/webhooks/stripe` endpoint | Stripe Dashboard → Developers → Webhooks → click endpoint → Roll secret |
| `STRIPE_PRICE_BUILD` | Stripe | Live price ID for the $1,800 build product (`price_…`) | Set once; don't rotate. Re-create only if product changes price. |
| `STRIPE_PRICE_MAINTENANCE` | Stripe | Live price ID for the $250/mo maintenance product (`price_…`) | Same as above |
| `DOCUSIGN_BASE_URL` | DocuSign | API base, region-specific (`https://na4.docusign.net/restapi` for our prod account) | Don't change unless DocuSign migrates account region |
| `DOCUSIGN_ACCOUNT_ID` | DocuSign | Production account UUID | Set once per account |
| `DOCUSIGN_INTEGRATION_KEY` | DocuSign | Integration Key UUID (same in sandbox + prod after Go Live promotion) | DocuSign Admin → Settings → Apps and Keys → can generate new IK but requires Go-Live re-promotion |
| `DOCUSIGN_USER_ID` | DocuSign | API user UUID (the user the JWT impersonates) | Pinned to Greg's account |
| `DOCUSIGN_RSA_PRIVATE_KEY` | DocuSign | RSA private key for JWT bearer auth (multi-line PEM, double-quoted in `.env`) | DocuSign Admin → Apps and Keys → app detail → Generate RSA Keypair (rotates pair; old keys remain valid until deleted) |
| `DOCUSIGN_TEMPLATE_SALE` | DocuSign | Production template UUID for `01-sale-agreement.pdf` | Re-upload template → capture new UUID → update env |
| `DOCUSIGN_TEMPLATE_MAINTENANCE` | DocuSign | Production template UUID for `02-maintenance-agreement.pdf` | Same as above |
| `DOCUSIGN_WEBHOOK_SECRET` | DocuSign Connect | HMAC signing key (base64) for `claim.storefronts.studio/v1/webhooks/docusign` callbacks | DocuSign Admin → Connect → edit config → Generate HMAC key |
| `NOTIFY_WORKER_URL` | (own) | URL of the Cloudflare Worker that forwards to Resend | Re-deploy worker if renamed |
| `NOTIFY_WORKER_SECRET` | (own) | Shared secret in `X-Claim-Secret` header for worker auth | Rotate by updating both the Worker secret (`wrangler secret put CLAIM_SECRET`) AND this env var simultaneously, then `pm2 restart claim-svc` |
| `LEADS_DB_PATH` | (own) | Path to `storefronts-leads` SQLite file (`/var/www/sites/storefront-leads/data/leads.db` on droplet) | Path-only, no secret |

---

## `storefronts-claim-notify` Cloudflare Worker (managed via `wrangler` CLI)

| Secret | What it is |
|---|---|
| `CLAIM_SECRET` | Shared with `claim-svc`'s `NOTIFY_WORKER_SECRET`. Rotate both together. `wrangler secret put CLAIM_SECRET` |
| `RESEND_API_KEY` | Resend API key (`re_…`) for sending `claims@storefronts.studio` outbound. Resend Dashboard → API Keys. |

Set via `wrangler secret put <NAME>` from the `worker/` directory.

---

## `storefronts-leads` (Greg's laptop only — never deployed)

| Env var | Vendor | What it is |
|---|---|---|
| `LOB_API_KEY` | Lob | Test or live API key (`test_…` / `live_…`). Toggle live with `LOB_LIVE=1`. |
| `LOB_LIVE` | (own) | `0` = test mode (renders, no print), `1` = live (real mail + charge) |
| `TWILIO_ACCOUNT_SID` | Twilio | Account SID for Lookup API |
| `TWILIO_AUTH_TOKEN` | Twilio | Auth token (used as basic-auth password) |
| `SENDER_*` | (own) | Return address for postcards (iPostal1 Fresh Meadows) |
| `GOOGLE_PLACES_API_KEY` | Google Maps | Places API key for lead discovery + scoring |

---

## Inbox watcher (Greg's laptop only — `~/.storefronts/.env`)

| Env var | What it is |
|---|---|
| `GMAIL_USER` | `greg.brownnyc@gmail.com` |
| `GMAIL_APP_PASSWORD` | 16-char Gmail app password (NOT account password). Generated at https://myaccount.google.com/apppasswords. Revoke + regenerate if leaked. |

---

## Droplet-level

| Secret | Location | What |
|---|---|---|
| `CF_API_TOKEN` | `/etc/default/caddy` | Cloudflare API token, Zone:DNS:Edit scope — Caddy uses it for DNS-01 ACME wildcard cert renewal |
| `CF_PURGE_TOKEN` | `/etc/default/caddy` | Cloudflare API token, Cache Purge scope — used by `/usr/local/bin/storefronts-purge` |
| Root SSH key | `~/.ssh/authorized_keys/` on droplet | Greg's pubkey only. No other authorized users. |

---

## Rotation policy (recommended)

| Cadence | What to rotate |
|---|---|
| **Annually** | Stripe webhook secrets, DocuSign RSA keypair, Cloudflare API tokens |
| **Quarterly** | `NOTIFY_WORKER_SECRET` / `CLAIM_SECRET` shared secret |
| **On compromise / personnel change** | Everything in this doc |

Per-secret rotation: edit `.env` → `pm2 restart claim-svc --update-env` (or `wrangler secret put` + redeploy Worker). For multi-secret rotation, rotate one at a time and verify with the relevant L3 probe before moving to the next.
