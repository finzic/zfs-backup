# Headscale + Caddy Setup for ZFS Offsite Backup (3-2-1)

## Architecture Overview

```
[HOME NETWORK 10.20.1.0/24 - Procione]   [INTERNET - Cloudflare orange cloud]   [FRIEND'S HOUSE - LTE Router 192.168.8.0/24]
┌────────────────────────────────────┐                             ┌──────────────────────────────┐
│  LXC: caddy (10.20.1.222)          │◄─ port 8443 fwd ────────│   Backup Server              │
│  ├─ nc.domain → morla Nextcloud   │   (both nc + hs   │   192.168.8.x                │
│  └─ hs.domain → headscale :8080   │    via CF proxy)   │   (tailscale client)         │
│                                    │                   │   Headscale IP: 100.64.0.2   │
│  LXC: headscale (10.20.1.200)      │                   └──────────────────────────────┘
│  Headscale IP: 100.64.0.1          │
│  morla: Nextcloud (10.20.1.x)      │
└────────────────────────────────────┘
         ▲
         │ Headscale control plane
         ▼
    All nodes register here via HTTPS (Cloudflare → Caddy → Headscale)
```

**Result**: `DST_ADDR` in your `.bkp` files becomes the stable Headscale IP (e.g. `100.64.0.2`),
regardless of where the backup server physically is.

---

## Prerequisites

- Both `nc.yourdomain.com` and `hs.yourdomain.com` as Cloudflare A records, **both orange cloud (proxied)** — your home IP stays hidden
- Port **8443** forwarded on your home router → Caddy LXC `10.20.1.222` (change existing rule from morla to Caddy)
- Port 3478/UDP forwarded for STUN/DERP (optional, improves direct P2P performance)
- Proxmox (or similar) to create LXC containers on Procione
- A Cloudflare API token with `Zone:DNS:Edit` permission (created in Step 0 below)

---

## Step 0 — Cloudflare DNS Configuration

### Architecture: one port, two services, IP fully hidden

Caddy sits in front of both services on port 8443. It distinguishes `nc` from `hs` via the
`Host` header (after Cloudflare terminates TLS between the client and its edge). Both DNS records
point to the same public IP but are **orange cloud (proxied)** — Cloudflare's edge is what the
client actually connects to, so your home IP never appears in DNS.

**This replaces the existing direct router rule** `8443 → morla`. After this setup the rule
becomes `8443 → Caddy LXC (10.20.1.222)`, and Caddy internally forwards Nextcloud traffic to morla.

> **Cloudflare WebSocket timeout caveat**: Cloudflare's free-tier proxy enforces a ~100-second
> idle timeout on proxied connections. Headscale uses persistent connections for push updates;
> these will be periodically dropped and reconnected. Tailscale clients handle reconnects
> automatically, so backups are not affected, but expect occasional log noise.
> If this becomes a problem, the alternative is to move `hs` to grey cloud (DNS-only) and use
> a separate port as described in the previous revision — at the cost of exposing your IP for `hs`.

### Cloudflare Dashboard Changes

**SSL/TLS → Overview**: set mode to **Full (Strict)**. Caddy will have a valid Let's Encrypt cert
so strict validation works. Do this *before* switching morla off the direct rule.

**DNS Records:**

| Subdomain | Type | Value | Proxy status |
|---|---|---|---|
| `nc` | A | `<your home public IP>` | Proxied (orange cloud) — existing, already set |
| `hs` | A | `<your home public IP>` | Proxied (orange cloud) — add this |

Both records point to the same IP. Cloudflare routes each to your home, Caddy splits them by hostname.

### Cloudflare API Token (for DNS-01 certificate challenge)

Caddy needs to modify DNS records to complete the ACME DNS-01 challenge. This avoids needing
port 80 inbound (likely also ISP-blocked) and works entirely via the Cloudflare API.

1. Go to **My Profile → API Tokens → Create Token**
2. Use the **Edit zone DNS** template (pre-fills the permission below)
3. Under **Permissions**: confirm it shows `Zone → DNS → Edit`
4. Under **Zone Resources** (separate section, just below Permissions): change from
   `Include — All zones` to `Include — Specific zone — yourdomain.com`
5. Click **Continue to summary**, then **Create Token**
6. Copy the generated token — you will put it in `/etc/caddy/environment` on the Caddy LXC

```bash
# On the Caddy LXC (10.20.1.222) — store the token securely
cat > /etc/caddy/environment << 'EOF'
CF_API_TOKEN=paste_your_token_here
EOF
chmod 600 /etc/caddy/environment
chown caddy:caddy /etc/caddy/environment
```

Then make the systemd service load it:

```bash
mkdir -p /etc/systemd/system/caddy.service.d/
cat > /etc/systemd/system/caddy.service.d/override.conf << 'EOF'
[Service]
EnvironmentFile=/etc/caddy/environment
ExecStart=
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
systemctl daemon-reload
```

The `ExecStart` override above intentionally removes `--environ` to avoid writing environment
variables (including `CF_API_TOKEN`) to journald.

---

## Step 1 — LXC Container Setup on Procione

Before creating containers, download the Debian template to Proxmox storage:

```bash
# On Proxmox host
pveam update
pveam available | grep debian-12-standard
pveam download local debian-12-standard_12.12-1_amd64.tar.zst
pveam list local
```

Create two LXC containers (or one combined) on Proxmox. Using static IPs on the home LAN (`10.20.1.0/24`):

```bash
# On Proxmox host — create Debian 12 LXC for headscale
pct create 200 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname headscale \
  --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=10.20.1.200/24,gw=10.20.1.1 \
  --storage local-lvm \
  --rootfs local-lvm:4 \
  --unprivileged 1 \
  --start 1

pct stop 200
pct set 200 -features nesting=1,keyctl=1
pct start 200


# Create Debian 12 LXC for caddy
pct create 201 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname caddy \
  --memory 256 \
  --net0 name=eth0,bridge=vmbr0,ip=10.20.1.222/24,gw=10.20.1.1 \
  --storage local-lvm \
  --rootfs local-lvm:8 \
  --unprivileged 1 \
  --start 1
```

Adjust the IPs (`.200`, `.222`) and gateway (`.1`) to match your actual Procione setup.
For Caddy builds with Go plugins, keep at least `8G` rootfs (10G recommended).

### Accessing the containers

If the Proxmox console shows a login prompt and you do not know the password yet, enter from the
Proxmox host directly:

```bash
# Start containers (if not already running)
pct start 200
pct start 201

# Open a shell directly inside each container
pct enter 200
pct enter 201
```

Then set a root password so console login works:

```bash
passwd
```

Or set it from the Proxmox host without entering the container:

```bash
pct exec 200 -- passwd
pct exec 201 -- passwd
```

---

## Step 2 — Install Headscale (LXC 200)

```bash
# Inside the headscale LXC
apt update && apt install -y curl

# Download latest headscale release (check https://github.com/juanfont/headscale/releases)
HEADSCALE_VERSION="0.29.3"
curl -Lo /tmp/headscale.deb \
  "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64.deb"

dpkg -i /tmp/headscale.deb
```

### Headscale Configuration

Edit `/etc/headscale/config.yaml`:

```yaml
server_url: "https://hs.yourdomain.com:8443"

listen_addr: "0.0.0.0:8080"
metrics_listen_addr: "127.0.0.1:9090"
grpc_listen_addr: "127.0.0.1:50443"
grpc_allow_insecure: true
trusted_proxies: []

private_key_path: "/var/lib/headscale/private.key"
noise:
  private_key_path: "/var/lib/headscale/noise_private.key"

prefixes:
  v4: "100.64.0.0/10"
  v6: "fd7a:115c:a1e0::/48"
  allocation: sequential

derp:
  server:
    enabled: false
  urls:
    - "https://controlplane.tailscale.com/derpmap/default"
  paths: []
  auto_update_enabled: true
  update_frequency: "24h"

database:
  type: sqlite
  sqlite:
    path: "/var/lib/headscale/db.sqlite"
    write_ahead_log: true

disable_check_updates: false

log:
  level: info
  format: text

policy:
  mode: file
  path: ""

dns:
  magic_dns: true
  base_domain: "headnet.internal"
  override_local_dns: true
  nameservers:
    global:
      - "1.1.1.1"
      - "1.0.0.1"
      - "2606:4700:4700::1111"
      - "2606:4700:4700::1001"
    split: {}
  search_domains: []
  extra_records: []

unix_socket: "/var/run/headscale/headscale.sock"
unix_socket_permission: "0770"

oidc:
  only_start_if_oidc_is_available: false

logtail:
  enabled: false

taildrop:
  enabled: true

auto_update:
  enabled: false
```

Port safety note: `listen_addr`, `metrics_listen_addr`, and `grpc_listen_addr` must use distinct
IP:port bindings. Do not reuse `:8080` for metrics or gRPC.

Canonical copy for reuse is in `headscale-config-0.29.3.yaml` in this repository.

```bash
# Enable and start
systemctl enable --now headscale
systemctl status headscale
```

Because Caddy runs in a separate LXC, Headscale must listen on the LAN interface
(`0.0.0.0:8080` or `10.20.1.200:8080`), not on `127.0.0.1:8080`.

---

## Step 3 — Install and Configure Caddy (LXC 201)

The standard Caddy package does not include the Cloudflare DNS plugin. Install the package first
(it sets up the systemd service, user, and directories), then replace the binary with a custom build.

If you hit `no space left on device`, first free temporary build/cache files and retry:

```bash
df -h /
rm -rf /tmp/go.tgz /tmp/caddy-cloudflare /root/go/pkg/mod /root/.cache/go-build
apt clean
df -h /
```

If space is still low, expand the LXC disk from Proxmox host (recommended):

```bash
pct stop 201
pct resize 201 rootfs +6G
pct start 201
```

```bash
# Inside the caddy LXC
apt update && apt install -y debian-keyring debian-archive-keyring apt-transport-https curl

# Install a modern Go toolchain (Debian 12 default Go 1.19 is too old for current Caddy/plugin builds)
GO_VERSION=1.24.6
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
export PATH=/usr/local/go/bin:$PATH
go version

# Install caddy package to get the service unit, user, and /etc/caddy skeleton
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# Install xcaddy and build Caddy with the Cloudflare DNS provider module
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
XCADDY=${HOME}/go/bin/xcaddy
${XCADDY} build --with github.com/caddy-dns/cloudflare --output /tmp/caddy-cloudflare

# Replace system binary and restore capabilities
mv /tmp/caddy-cloudflare /usr/bin/caddy
setcap cap_net_bind_service=+ep /usr/bin/caddy

# Ensure log directory is writable by caddy service user
install -d -o caddy -g caddy -m 750 /var/log/caddy

# Verify the module is compiled in
caddy list-modules | grep cloudflare
```

### Caddyfile

Edit `/etc/caddy/Caddyfile`.

> **morla internal port**: Caddy needs to reach Nextcloud on morla over the LAN. If morla's web server
> currently listens on HTTPS:8443 with a self-signed cert, use the commented-out option below.
> The cleanest long-term setup is to make morla's Nextcloud listen on plain HTTP on a LAN-only port
> (e.g. `http://morla-ip:80`) and let Caddy own all TLS — but that requires reconfiguring morla.
> If `curl -I -H 'Host: nc.yourdomain.com' http://<MORLA_IP>` returns `301` to `https://...:8443`,
> use Option B to avoid proxy-redirect loops.

```caddyfile
# /etc/caddy/Caddyfile
# Replace yourdomain.com and <MORLA_IP> with actual values

{
    # DNS-01 via Cloudflare for all sites — no inbound port 80/443 needed
    acme_dns cloudflare {env.CF_API_TOKEN}
}

nc.yourdomain.com:8443 {
  # Nextcloud service discovery endpoints live in the nc site block.
  redir /.well-known/carddav /remote.php/dav/ 301
  redir /.well-known/caldav /remote.php/dav/ 301

  # Option A: morla exposes plain HTTP internally (preferred when available)
  # reverse_proxy http://<MORLA_IP>:80

  # Option B: morla keeps its own HTTPS and redirects HTTP -> HTTPS
  reverse_proxy https://<MORLA_IP>:443 {
    transport http {
      tls_server_name nc.yourdomain.com
      tls_insecure_skip_verify
    }
    header_up Host nc.yourdomain.com:8443
    header_up X-Forwarded-Host nc.yourdomain.com:8443
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Port 8443
  }
}

hs.yourdomain.com:8443 {
    reverse_proxy 10.20.1.200:8080 {
        transport http {
            read_timeout  0
            write_timeout 0
        }
        flush_interval -1
    # Only add header_up directives here if your upstream explicitly requires them.
  }

    log {
        output file /var/log/caddy/headscale-access.log
        format console
    }
}
```

### Nextcloud reverse-proxy settings on morla

Use these values in `config/config.php` on morla:

```php
'trusted_domains' =>
array (
  0 => 'nc.yourdomain.com',
),
'trusted_proxies' =>
array (
  0 => '10.20.1.222',
),
'forwarded_for_headers' =>
array (
  0 => 'HTTP_X_FORWARDED_FOR',
),
'overwritehost' => 'nc.yourdomain.com:8443',
'overwriteprotocol' => 'https',
'overwrite.cli.url' => 'https://nc.yourdomain.com:8443',
```

Then reload Apache on morla:

```bash
systemctl reload apache2
```

These are the working reverse-proxy settings:

- `trusted_domains` should include `nc.yourdomain.com`
- `trusted_proxies` should include the Caddy container IP (`10.20.1.222`)
- `forwarded_for_headers` should include only the header that carries the client IP, usually `HTTP_X_FORWARDED_FOR`

If you want to confirm what Nextcloud has loaded, re-run:

```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:get trusted_proxies
sudo -u www-data php /var/www/nextcloud/occ config:system:get forwarded_for_headers
```

> Caddy uses the Cloudflare DNS-01 ACME challenge to provision and auto-renew certificates for
> both domains. The `acme_dns` global block applies to all sites, so no per-site `tls` block is
> needed. No inbound port 80 or 443 is required.

```bash
systemctl enable --now caddy
systemctl status caddy
# Check cert was issued:
journalctl -u caddy -f
```

### 5-command validation (Cloudflare -> Caddy -> Headscale)

Run these commands in order after Caddy and Headscale are up.

```bash
# 1) On headscale LXC: confirm backend is listening
ss -ltnp | grep -E '0.0.0.0:8080|127.0.0.1:50443|127.0.0.1:9090'

# 2) On caddy LXC: validate config syntax
set -a && . /etc/caddy/environment && set +a && caddy validate --config /etc/caddy/Caddyfile

# 3) On caddy LXC: restart and confirm healthy service
systemctl restart caddy && systemctl status caddy --no-pager

# 4) From any external client (not inside your LAN): verify public HTTPS endpoint through Cloudflare
curl -vkI https://hs.yourdomain.com:8443

# 5) On headscale LXC: verify headscale stayed healthy after external probe
journalctl -u headscale -n 30 --no-pager
```

Expected outcome:

- Command 1 shows listeners on `0.0.0.0:8080`, `127.0.0.1:50443`, `127.0.0.1:9090`.
- Commands 2 and 3 complete without errors.
- Command 4 returns an HTTPS response (HTTP status can be 200/301/302/401/404 depending on endpoint path).
- Command 5 shows no startup crash and no repeated fatal errors.

---

## Step 4 — Create a Headscale Namespace (User)

In Headscale terminology, a "user" groups nodes together. Create one for your backup network:

```bash
# On the headscale LXC (or via CLI from Procione if grpc is reachable)
headscale users create backup-net

# Verify
headscale users list
```

---

## Step 5 — Install Tailscale on the Backup SOURCE (Morla / Procione)

```bash
# On your backup source machine
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to YOUR headscale instance instead of Tailscale's servers
tailscale up \
  --login-server https://hs.yourdomain.com:8443 \
  --accept-routes \
  --hostname backup-source
```

This prints a registration URL. Register it on the headscale server:

```bash
# On headscale LXC — approve the node
headscale nodes list                        # find the node ID
headscale nodes register --user backup-net --key <NODE_KEY>

# Or use a pre-auth key to skip manual approval (recommended for automation):
headscale preauthkeys create --user backup-net --reusable --expiration 90d
# Use the printed key:
tailscale up --login-server https://hs.yourdomain.com:8443 --authkey <PREAUTH_KEY>
```

---

## Step 6 — Install Tailscale on the Backup DESTINATION (Friend's House / LTE Router)

On the backup server at the friend's house (connected to LTE router):

```bash
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your headscale
tailscale up \
  --login-server https://hs.yourdomain.com:8443 \
  --authkey <PREAUTH_KEY_FROM_STEP_5> \
  --hostname backup-dest \
  --accept-routes
```

Register it on headscale (if not using a pre-auth key):

```bash
# On headscale LXC
headscale nodes register --user backup-net --key <NODE_KEY>
headscale nodes list
```

You should now see both nodes with their `100.64.x.x` IPs:

```
ID | Hostname       | IPs           | User       | Online
1  | backup-source  | 100.64.0.1    | backup-net | yes
2  | backup-dest    | 100.64.0.2    | backup-net | yes
```

Test connectivity:

```bash
# From backup-source
ping 100.64.0.2
ssh zfs-admin@100.64.0.2
```

---

## Step 7 — Update .bkp Descriptor Files

In your `.bkp` files, change `DST_ADDR` from the local hostname to the Headscale IP:

```bash
# Example: Documents.bkp
DST_ADDR=100.64.0.2      # was: r4spi.local or friend-server.local
```

The connection now routes through the encrypted Headscale VPN tunnel regardless of
where the backup server physically sits.

---

## Step 7b — Subnet Routes (Optional but Recommended)

If you want Tailscale nodes to reach the full home LAN (`10.20.1.0/24`) or the remote LAN
(`192.168.8.0/24`) — not just individual VPN IPs — advertise subnet routes:

```bash
# On backup-source (home): advertise home LAN
tailscale up --login-server https://hs.yourdomain.com:8443 \
  --advertise-routes=10.20.1.0/24 \
  --authkey <PREAUTH_KEY>

# On backup-dest (friend's house): advertise remote LAN
tailscale up --login-server https://hs.yourdomain.com:8443 \
  --advertise-routes=192.168.8.0/24 \
  --authkey <PREAUTH_KEY>
```

Approve the routes on headscale:

```bash
# On headscale LXC
headscale routes list
headscale routes enable --route <ROUTE_ID>
```

This is **not required** for the ZFS backup use case (which targets VPN IPs directly), but useful
if you want to SSH into other devices on the remote LAN.

---

## Step 8 — SSH Key Setup Across the VPN

Ensure passwordless SSH from source to destination over the VPN:

```bash
# On backup-source
ssh-keygen -t ed25519 -f ~/.ssh/id_backup -C "zfs-backup@backup-source"
ssh-copy-id -i ~/.ssh/id_backup.pub zfs-admin@100.64.0.2

# Test
ssh -i ~/.ssh/id_backup zfs-admin@100.64.0.2 hostname
```

Update your `.bkp` descriptor:

```bash
DST_SSH_KEY=/home/finzic/.ssh/id_backup
DST_ADDR=100.64.0.2
DST_USERNAME=zfs-admin
```

---

## Step 9 — ZFS Permissions on Destination (Delegated Admin)

To avoid running full `sudo` on the destination, delegate ZFS permissions:

```bash
# On backup-dest, as root
useradd -m -s /bin/bash zfs-admin
zfs allow zfs-admin create,receive,mount,destroy,rollback,snapshot backuppool
# Still need sudo for 'zfs recv' with -F — add a targeted sudoers entry:
echo "zfs-admin ALL=(ALL) NOPASSWD: /sbin/zfs recv *" >> /etc/sudoers.d/zfs-backup
echo "zfs-admin ALL=(ALL) NOPASSWD: /sbin/zfs set readonly=on *" >> /etc/sudoers.d/zfs-backup
chmod 440 /etc/sudoers.d/zfs-backup
```

---

## Firewall Notes

| Location | Port | Protocol | Purpose |
|---|---|---|---|
| Home router | 8443 | TCP | Single entry point: Caddy routes `nc` → morla and `hs` → headscale; both proxied by Cloudflare |
| Home router | 3478 | UDP | STUN/DERP (optional, improves P2P) |
| Headscale LXC | 8080 | TCP | Internal only (Caddy → Headscale) |
| Destination server | 22 | TCP | SSH (via VPN, not exposed to internet) |

SSH to the backup destination is **only accessible over the Headscale VPN** — it never needs to be exposed to the public internet.

Keep router NAT as `WAN 8443 -> Caddy:8443` unless you also change Caddy to listen on `:443`.
The current Caddyfile listens on `:8443`, so forwarding to internal `:443` would break routing.

---

## Testing the Full Flow

```bash
# 1. Verify VPN is up
tailscale status

# 2. Verify SSH works over VPN
ssh -i ~/.ssh/id_backup zfs-admin@100.64.0.2 zfs list

# 3. Run a test backup with the Test descriptor
./zfs-backup-copy.sh -b Test

# 4. Check backup arrived
ssh -i ~/.ssh/id_backup zfs-admin@100.64.0.2 zfs list -t snapshot backuppool/Test
```

---

## LTE Router Test Scenario

To simulate the "friend's house" with your LTE router:

| Network | Subnet | Role |
|---|---|---|
| Home (Procione) | `10.20.1.0/24` | Headscale server + backup source |
| Remote (LTE router) | `192.168.8.0/24` | Simulated friend's house |
| Headscale VPN | `100.64.0.0/10` | Overlay — crosses both NATs |

1. Connect the backup destination machine to the LTE router's LAN (`192.168.8.0/24`), not your home LAN
2. The machine gets a `192.168.8.x` IP behind LTE NAT — no port forwarding needed on the LTE side
3. Bring up Tailscale: `tailscale up --login-server https://hs.yourdomain.com:8443 --authkey <KEY>`
4. Verify it appears in `headscale nodes list` with a `100.64.x.x` IP and is reachable: `ping 100.64.0.2`

Headscale's DERP relay handles the double-NAT (home router + LTE carrier NAT) automatically.
Once direct P2P is negotiated, traffic flows directly between `10.20.1.x` and `192.168.8.x` without
passing through the relay.

---

## Headscale CLI Quick Reference

```bash
# List nodes
headscale nodes list

# List pre-auth keys
headscale preauthkeys list --user backup-net

# Create expiring pre-auth key
headscale preauthkeys create --user backup-net --expiration 30d

# Expire/revoke a node
headscale nodes expire --identifier <ID>

# View routes
headscale routes list
```
