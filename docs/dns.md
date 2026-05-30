# DNS records

All zones live on Cloudflare. Authoritative state is the Cloudflare dashboard; this doc is a snapshot for recovery + diff-review.

---

## `storefronts.studio` zone

### Web routing (A records, proxied=OFF / DNS-only, so Caddy gets the real client IP)

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `@` | `206.81.4.220` (droplet) | DNS only |
| A | `*` | `206.81.4.220` (droplet) | DNS only |

Wildcard handles `ngr.`, `petes.`, `madethecut.`, `claim.`, future subdomains. Caddy at the droplet routes per-host.

### Email (Cloudflare Email Routing + Resend outbound)

| Type | Name | Content | Purpose |
|---|---|---|---|
| MX | `@` | `route1.mx.cloudflarenet`, `route2.mx.cloudflarenet`, `route3.mx.cloudflarenet` (priority 9–17) | Inbound mail → CF routing → forward to `greg.brownnyc@gmail.com` |
| TXT | `@` | `v=spf1 include:_spf.mx.cloudflare.net include:_spf.resend.com ~all` | SPF for inbound (CF) + outbound (Resend) |
| CNAME | `resend._domainkey` | `resend._domainkey.resend.com` | DKIM for Resend outbound |
| CNAME | `send` | `feedback-smtp.us-east-1.amazonses.com` | Return-path / bounce handling (Resend uses SES under the hood) |
| TXT | `_dmarc` | `v=DMARC1; p=none;` | DMARC monitoring (no enforcement) |

**Inbound email routes** (Cloudflare → Email → Routing):
- `greg@storefronts.studio` → `greg.brownnyc@gmail.com`
- `claims@storefronts.studio` → `greg.brownnyc@gmail.com`
- `privacy@storefronts.studio` → `greg.brownnyc@gmail.com`

### Validation / domain ownership

| Type | Name | Content | Purpose |
|---|---|---|---|
| TXT | `_acme-challenge.storefronts.studio` | (rotated; Caddy ACME) | LetsEncrypt DNS-01 challenge for wildcard cert. Caddy writes + tears down automatically using `CF_API_TOKEN`. |

---

## `doneup.us` zone

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `@` | `206.81.4.220` (droplet) | DNS only |
| A | `www` | `206.81.4.220` (droplet) | DNS only |

(No subdomains in use yet. Email handled by Google Workspace separately — MX records there are not part of this infra.)

---

## Cloudflare API tokens (locations, not values)

| Token name | Where it lives | Scope |
|---|---|---|
| `CF_API_TOKEN` | `/etc/default/caddy` on droplet | Zone:DNS:Edit on `storefronts.studio` + `doneup.us` (for DNS-01 ACME challenges) |
| `CF_PURGE_TOKEN` | `/etc/default/caddy` on droplet (used by `/usr/local/bin/storefronts-purge`) | Zone:Cache Purge on `storefronts.studio` + `doneup.us` |

Rotate via Cloudflare → My Profile → API Tokens. After rotating, update `/etc/default/caddy` on the droplet (chmod 644) and `pm2 restart all` is not required — Caddy reads on next renewal.
