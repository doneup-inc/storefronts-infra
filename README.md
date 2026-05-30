# storefronts-infra

DigitalOcean droplet infra for `storefronts.studio` — the pitch-stage hosting surface for spec sites built with [storefronts-starter](https://github.com/doneup-inc/storefronts-starter) on leads from [storefronts-leads](https://github.com/doneup-inc/storefronts-leads), with the customer claim flow handled by [storefronts-claim](https://github.com/doneup-inc/storefronts-claim).

One droplet hosts every customer site as a subdomain (`{slug}.storefronts.studio`). Caddy handles wildcard SSL automatically via Cloudflare DNS-01.

---

## Architecture

```
                 ┌─────────────────────────────┐
                 │  Cloudflare DNS             │
                 │  *.storefronts.studio  →    │
                 │  → DO droplet IP            │
                 └─────────────┬───────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │  DO Droplet — Ubuntu 24.04 · $12/mo Basic 2GB · NYC    │
   │                                                        │
   │   Caddy (443, wildcard SSL)                            │
   │     storefronts.studio           → static              │
   │     ngr.storefronts.studio       → :4001               │
   │     petes.storefronts.studio     → :4002               │
   │     madethecut.storefronts.studio → :4003              │
   │     claim.storefronts.studio     → :4100               │
   │     doneup.us                    → static              │
   │                                                        │
   │   PM2                                                  │
   │     ngr-ssr        :4001  ← Angular SSR (spec site)   │
   │     petes-ssr      :4002  ← Angular SSR (spec site)   │
   │     madethecut-ssr :4003  ← Angular SSR (spec site)   │
   │     claim-svc      :4100  ← Express claim API          │
   │                                                        │
   │   /var/www/sites/    ← git clones live here            │
   │   /opt/storefronts/  ← infra scripts                   │
   └────────────────────────────────────────────────────────┘

   Edge:
     Cloudflare Worker: storefronts-claim-notify
       → Resend API → claims@storefronts.studio outbound
```

---

## Prerequisites (one-time, before running `bootstrap.sh`)

### 1. Create the droplet
- **OS:** Ubuntu 24.04 (LTS) x64
- **Plan:** Basic · Regular SSD · 2 GB / 1 vCPU / 50 GB ($12/mo)
- **Datacenter:** NYC1 or NYC3 (closest to current Brooklyn / Schenectady leads)
- **Auth:** SSH key (paste your `~/.ssh/id_ed25519.pub` content)
- **Hostname:** `storefronts-studio-01` (any name)

Note the droplet's public IPv4 address — you'll need it next.

### 2. Cloudflare DNS

- Sign in to https://dash.cloudflare.com (free account is fine).
- Add `storefronts.studio` as a site → free plan.
- Cloudflare gives you two nameservers. Go to your domain registrar and change the nameservers to those two values. DNS propagation typically completes in 5–60 minutes.
- In Cloudflare → DNS → Records, add:

  | Type | Name | Content | Proxy |
  |------|------|---------|-------|
  | A | `@` | `<droplet-ip>` | DNS only (gray cloud) |
  | A | `*` | `<droplet-ip>` | DNS only (gray cloud) |

  The wildcard (`*`) is the critical one — it points every `<anything>.storefronts.studio` to the droplet.

  Leave the cloud **gray** (DNS only, not orange-proxied) initially. Caddy needs to see real connections for HTTPS to work cleanly. We can flip to orange-proxied later for CDN/DDoS once the basics are working.

### 3. Cloudflare API token

This is what lets Caddy auto-renew the wildcard SSL cert.

- Cloudflare → My Profile → API Tokens → **Create Token**
- Use the **Custom token** template:
  - Permissions: `Zone` → `DNS` → `Edit`
  - Zone Resources: `Include` → `Specific zone` → `storefronts.studio`
  - TTL: leave default (never)
- Click **Continue → Create Token**.
- **Copy the token immediately** (only shown once). It looks like `cf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.

This token is least-privilege: it can only edit DNS for `storefronts.studio`, nothing else. Safe to keep on the droplet.

---

## Running the bootstrap

SSH into the fresh droplet:

```bash
ssh root@<droplet-ip>
```

Set your env vars + paste-execute the script:

```bash
export CF_API_TOKEN=cf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export ROOT_DOMAIN=storefronts.studio
export ADMIN_EMAIL=greg.brownnyc@gmail.com

# Pull the script straight from this repo and execute
curl -fsSL https://raw.githubusercontent.com/doneup-inc/storefronts-infra/main/bootstrap/bootstrap.sh | bash
```

The script is **idempotent** — safe to re-run if anything fails or you change settings later.

Takes ~5–10 minutes. The slowest step is the Caddy rebuild with the Cloudflare DNS plugin (~2 min).

When it's done you'll have:
- Node 22, npm, PM2 installed
- Caddy built with `caddy-dns/cloudflare` plugin, running under systemd, with `/etc/caddy/Caddyfile` configured
- UFW firewall allowing SSH + 80 + 443 only
- Standard dirs: `/var/www/sites/`, `/opt/storefronts/`, `/var/log/storefronts/`
- Apex `storefronts.studio` returning a tiny placeholder

Hit `https://storefronts.studio` in a browser — the wildcard cert should be valid and you should see the placeholder response. If yes, you're ready to add sites.

---

## Adding a site (manual, until we automate it)

Walkthrough using `ngr.storefronts.studio` as the example. Subsequent sites follow the same pattern with a different slug + port.

### 1. Get the site code onto the droplet

The customer site repos are currently local-only on your laptop. Easiest path: push to GitHub first (private repo under `doneup-inc`), then clone on the droplet.

On your laptop:
```bash
cd ~/github/storefront-sites/ngr-auto-schenectady
gh repo create doneup-inc/ngr-auto-schenectady --private --source=. --push
```

On the droplet:
```bash
cd /var/www/sites
git clone https://github.com/doneup-inc/ngr-auto-schenectady.git
cd ngr-auto-schenectady
npm ci
npm run build
```

### 2. Start the SSR server with PM2 on a unique port

Each site gets its own port. Convention: start at `4001`, increment by 1 per site.

```bash
PORT=4001 pm2 start "node dist/ngr-auto-schenectady/server/server.mjs" \
  --name ngr-ssr \
  --log /var/log/storefronts/ngr.log
pm2 save
```

Verify it's running and listening:
```bash
pm2 list
curl http://localhost:4001     # should return prerendered HTML
```

### 3. Add the Caddy block

Edit `/etc/caddy/Caddyfile` and add a new `@slug + handle` block inside the `*.storefronts.studio { }` group:

```caddy
@ngr host ngr.storefronts.studio
handle @ngr {
    reverse_proxy localhost:4001
}
```

(The bootstrap script left a commented-out example showing exactly this. Just uncomment and fill in.)

Reload Caddy (zero-downtime):
```bash
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### 4. Verify

```bash
curl -I https://ngr.storefronts.studio   # expect HTTP/2 200 + valid SSL
```

Open in browser. You should see the NGR site, with the DRAFT banner at top, fully styled, scrolling correctly.

That URL is now the pitch link — short, branded, easy to text.

### 5. Re-deploy after a content edit

When you tweak `site.config.ts` on your laptop, push to GitHub, then on the droplet:

```bash
cd /var/www/sites/ngr-auto-schenectady
git pull
npm ci
npm run build
pm2 restart ngr-ssr
```

That's the manual deploy loop. Once you've done it 3–5 times and the pattern is clear, we can extract a `deploy.sh <slug>` script.

---

## Removing a site (when the customer signs / leaves / changes domain)

```bash
# Stop and remove the PM2 process
pm2 delete ngr-ssr
pm2 save

# Remove the Caddy block (edit /etc/caddy/Caddyfile, delete the @ngr + handle)
sudo systemctl reload caddy

# Archive the code (optional — keep for reference)
mv /var/www/sites/ngr-auto-schenectady /var/www/sites/_archive/
```

When a customer accepts and moves to their own domain (`ngrtires.com`), the subdomain is freed. Their actual production site can either:
- Stay on this droplet (just point `ngrtires.com` DNS at the droplet, add a Caddy block for `ngrtires.com`, set `preview: false` in `site.config.ts`)
- Move to their own hosting

---

## Operational essentials

| Want to… | Command |
|---|---|
| See what's running | `pm2 list` |
| Tail a site's logs | `pm2 logs ngr-ssr` |
| Tail Caddy logs | `journalctl -u caddy -f` |
| Reload Caddy after Caddyfile edit | `sudo systemctl reload caddy` |
| Validate Caddyfile before reload | `sudo caddy validate --config /etc/caddy/Caddyfile` |
| Check disk usage | `df -h /` and `du -sh /var/www/sites/*` |
| Check droplet health | `htop` (after `apt install htop`) |
| Reboot the droplet | `sudo reboot` — PM2 + Caddy come back automatically |

---

## What this repo intentionally does NOT do (yet)

- **No CI/CD.** Deploys are manual `git pull + build + restart` on the droplet. Add a GitHub Actions workflow if/when 3+ sites are being updated weekly.
- **No `add-site.sh` / `deploy.sh` scripts.** Documented manually above so you understand each step. Extract to scripts once the pattern hardens.
- **No backups.** Add DO automated snapshots ($2.40/mo on a $12 droplet) the moment you have a paying customer. Trivial.
- **No monitoring.** Add UptimeRobot (free) per subdomain once you have multiple live sites.
- **No staging environment.** Each customer site IS its own pre-launch surface; that's enough for now.

These all become real when revenue justifies the time. Not before.

---

## Files in this repo

| Path | Purpose |
|---|---|
| `bootstrap/bootstrap.sh` | One-shot droplet provisioning. Run once on a fresh Ubuntu 24.04 droplet. Idempotent. |
| `caddy/Caddyfile.example` | Reference Caddyfile showing the per-site block pattern. The droplet's actual `/etc/caddy/Caddyfile` is the source of truth; this is for editing on your laptop and scp'ing up. |
| `README.md` | This file. |
