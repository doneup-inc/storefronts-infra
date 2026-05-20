#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-shot droplet setup for storefronts.studio
# -----------------------------------------------------------------------------
# Target:  fresh Ubuntu 24.04 LTS droplet, run as root.
# Result:  Node 22 + Caddy (with Cloudflare DNS plugin, for wildcard SSL)
#          + PM2 (Node process manager) + UFW firewall + standard dirs.
# Idempotent: re-running this script is safe.
#
# REQUIRED PREREQUISITES (do these BEFORE running):
#   1. Droplet created (Ubuntu 24.04, $12/2GB Basic, NYC region recommended)
#   2. SSH'd in as root
#   3. Domain (storefronts.studio) using Cloudflare nameservers
#   4. Cloudflare wildcard A record (*.storefronts.studio → droplet IP)
#   5. Cloudflare API token created with permissions:
#        Zone → DNS → Edit  (scoped to storefronts.studio only)
#      Copy the token, you'll set it as CF_API_TOKEN below.
#
# USAGE:
#   export CF_API_TOKEN=cf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   export ROOT_DOMAIN=storefronts.studio
#   export ADMIN_EMAIL=greg.brownnyc@gmail.com
#   bash bootstrap.sh
# =============================================================================

set -euo pipefail

# ---------- pretty output ----------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; RST='\033[0m'
log()    { echo -e "${BLU}›${RST} $*"; }
ok()     { echo -e "${GRN}✓${RST} $*"; }
warn()   { echo -e "${YLW}!${RST} $*"; }
err()    { echo -e "${RED}✗${RST} $*" >&2; }
section(){ echo; echo -e "${BLU}── $* ──${RST}"; }

# ---------- preflight --------------------------------------------------------
section "Preflight"

if [[ "$(id -u)" -ne 0 ]]; then
  err "Must run as root. Re-run with: sudo -E bash bootstrap.sh"
  exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu 24" /etc/os-release; then
  warn "Not Ubuntu 24.04 — proceeding anyway, but YMMV."
fi

: "${CF_API_TOKEN:?CF_API_TOKEN env var required (Cloudflare token with Zone:DNS:Edit on storefronts.studio)}"
: "${ROOT_DOMAIN:?ROOT_DOMAIN env var required (e.g. storefronts.studio)}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL env var required (for ACME / cert registration)}"

ok "root user"
ok "CF_API_TOKEN set (length: ${#CF_API_TOKEN})"
ok "ROOT_DOMAIN=$ROOT_DOMAIN"
ok "ADMIN_EMAIL=$ADMIN_EMAIL"

# ---------- system update + base packages ------------------------------------
section "System update + base packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg lsb-release \
  build-essential git unattended-upgrades \
  ufw \
  >/dev/null
ok "base packages installed"

# enable automatic security upgrades
dpkg-reconfigure --priority=low unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled"

# ---------- UFW firewall -----------------------------------------------------
section "UFW firewall (ssh + http + https)"

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH        >/dev/null
ufw allow 80/tcp         >/dev/null   # HTTP (for Caddy automatic redirect to HTTPS)
ufw allow 443/tcp        >/dev/null   # HTTPS
ufw --force enable       >/dev/null
ok "ufw allows: ssh, 80, 443"

# ---------- Node 22 (NodeSource apt repo) ------------------------------------
section "Node 22"

node_major=0
if command -v node >/dev/null 2>&1; then
  node_major=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
fi
if [[ "$node_major" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y --no-install-recommends nodejs >/dev/null
  ok "node $(node -v) / npm $(npm -v) installed"
else
  ok "node $(node -v) already present"
fi

# ---------- Caddy (built with Cloudflare DNS plugin via xcaddy) --------------
section "Caddy with Cloudflare DNS plugin"

# Install Go (needed for xcaddy build)
if ! command -v go >/dev/null; then
  apt-get install -y --no-install-recommends golang-go >/dev/null
  go_ver=$(go version | cut -d' ' -f3)
  ok "go installed: $go_ver"
fi

# Install xcaddy if not present
if ! command -v xcaddy >/dev/null; then
  log "installing xcaddy..."
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >/dev/null
  cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
  ok "xcaddy installed"
fi

# Install standard Caddy package first (gets the systemd unit, user, dirs)
if ! command -v caddy >/dev/null; then
  log "installing base Caddy package (for systemd unit + user + dirs)..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y caddy >/dev/null
  ok "base Caddy installed"
fi

# Build Caddy with Cloudflare DNS plugin, replacing the default binary
section "Building Caddy with cloudflare DNS plugin"
log "this takes ~2 min..."
cd /tmp
xcaddy build --with github.com/caddy-dns/cloudflare 2>&1 | tail -5
systemctl stop caddy || true
mv ./caddy /usr/bin/caddy
chmod +x /usr/bin/caddy
ok "Caddy rebuilt with cloudflare DNS plugin"

# Persist CF_API_TOKEN for systemd-managed Caddy
mkdir -p /etc/caddy
cat > /etc/default/caddy <<EOF
# Loaded by /lib/systemd/system/caddy.service
# The cloudflare DNS plugin in Caddy reads CF_API_TOKEN for ACME DNS-01.
CF_API_TOKEN=$CF_API_TOKEN
EOF
chmod 600 /etc/default/caddy
ok "Cloudflare API token saved to /etc/default/caddy (mode 600)"

# Patch the systemd unit to load /etc/default/caddy
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/default/caddy
EOF
systemctl daemon-reload
ok "systemd configured to load /etc/default/caddy"

# ---------- Initial Caddyfile (no sites yet — just a placeholder) ------------
section "Initial Caddyfile"

cat > /etc/caddy/Caddyfile <<EOF
# =============================================================================
#  Caddyfile — storefronts.studio
#  Edit this file to add per-site reverse-proxy blocks. Reload with:
#    sudo systemctl reload caddy
# =============================================================================

{
    email $ADMIN_EMAIL
}

# Wildcard SSL via Cloudflare DNS-01 challenge.
# Each customer site = one @hostname block below.
*.$ROOT_DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }

    # ── add per-site routes here ──
    # Example:
    #   @ngr  host ngr.$ROOT_DOMAIN
    #   handle @ngr { reverse_proxy localhost:4001 }

    # Catch-all when no site is matched (helpful during initial setup)
    handle {
        respond "storefronts.studio — no site configured at this host yet" 404
    }
}

# Apex (storefronts.studio root, no subdomain) — show simple page or redirect.
$ROOT_DOMAIN {
    respond "storefronts.studio — pitches.live" 200
}
EOF

caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null
caddy validate --config /etc/caddy/Caddyfile
ok "Caddyfile written + validated"

systemctl restart caddy
systemctl enable caddy >/dev/null 2>&1 || true
sleep 2
if systemctl is-active --quiet caddy; then
  ok "Caddy running (systemctl status caddy)"
else
  err "Caddy failed to start — check: journalctl -u caddy -n 50"
  exit 1
fi

# ---------- PM2 process manager ----------------------------------------------
section "PM2 (Node process manager)"

npm install -g pm2 >/dev/null
ok "pm2 $(pm2 -v) installed"

# Configure PM2 to start on boot
pm2 startup systemd -u root --hp /root >/dev/null
pm2 save --force >/dev/null
ok "pm2 systemd unit installed (will resurrect on reboot)"

# ---------- Standard directories ---------------------------------------------
section "Directory layout"

mkdir -p /var/www/sites /opt/storefronts /var/log/storefronts
chmod 755 /var/www/sites /opt/storefronts
ok "/var/www/sites      — clone customer site repos here"
ok "/opt/storefronts    — for future deploy/add-site scripts"
ok "/var/log/storefronts — for PM2 + per-site logs"

# ---------- Summary ----------------------------------------------------------
section "Done"

# Pre-compute version strings to keep the heredoc free of nested quoting
caddy_ver=$(caddy version | cut -d' ' -f1-2)
node_ver=$(node -v)
npm_ver=$(npm -v)
pm2_ver=$(pm2 -v)

cat <<EOF

  ${GRN}OK${RST}  Droplet bootstrapped.

  Caddy:      $caddy_ver
  Node:       $node_ver
  npm:        $npm_ver
  pm2:        $pm2_ver

  Caddyfile:  /etc/caddy/Caddyfile
  Sites dir:  /var/www/sites
  PM2:        pm2 list / pm2 logs
  Caddy:      systemctl status caddy / journalctl -u caddy -f

  ${YLW}Next: add your first site manually${RST}
  See: storefronts-infra/README.md -> "Adding a site"

EOF
