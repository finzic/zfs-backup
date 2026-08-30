# Nextcloud on dimarzio with PostgreSQL

This guide installs a new Nextcloud instance on `dimarzio`, publishes it temporarily as
`nc2.yourdomain.com:8443`, then lets you cut over the existing `nc.yourdomain.com:8443` name after
migration and testing.

Recommended topology:

```text
Cloudflare -> Caddy LXC :8443 -> dimarzio HTTP :80 -> Nextcloud
```

Keep `dimarzio` LAN-only. Caddy remains the only public reverse proxy and handles public TLS.

## Migration Plan

This migration happens in three phases:

1. **Prepare the new instance** (sections 1-11): fresh PostgreSQL-backed Nextcloud on `dimarzio`,
   published temporarily as `nc2`, with the Documents/Text, Memories, and Music apps installed.
2. **Migrate Subsonic/Music client configuration** (section 12): point Subsonic-compatible apps
   at the new server and app passwords so they need minimal changes once the library is available.
3. **Physically migrate the `zfspool` ZFS disks** (section 14), only after the new instance is
   confirmed working. The disks are currently used as the core Nextcloud datadirectory
   (`/mnt/raid/nextcloud-data` on `morla`), so once they're moved and imported at `/mnt/raid` on
   `dimarzio`, you relocate the fresh instance's datadirectory to point at it and rescan.

## 1. Prepare DNS and Caddy

Create a temporary Cloudflare DNS record:

| Name | Type | Value | Proxy status |
|---|---|---|---|
| `nc2` | A | `<home public IP>` | Proxied (orange cloud) |

Add this temporary Caddy block on the Caddy LXC:

```caddyfile
nc2.yourdomain.com:8443 {
  redir /.well-known/carddav /remote.php/dav/ 301
  redir /.well-known/caldav /remote.php/dav/ 301

  reverse_proxy http://DIMARZIO_IP:80 {
    header_up Host nc2.yourdomain.com:8443
    header_up X-Forwarded-Host nc2.yourdomain.com:8443
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Port 8443
  }
}
```

Validate and reload Caddy:

```bash
set -a && . /etc/caddy/environment && set +a && caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

## 2. Install Packages on dimarzio

This example uses Ubuntu Server or Debian with Nginx, PHP-FPM, PostgreSQL, Redis, and the official
Nextcloud release archive.

```bash
apt update
apt install -y \
  nginx \
  postgresql postgresql-contrib \
  redis-server \
  php-fpm php-pgsql php-xml php-mbstring php-curl php-gd php-zip php-intl \
  php-bcmath php-gmp php-imagick php-apcu php-redis \
  unzip bzip2 curl
```

Check the installed PHP version:

```bash
php -v
systemctl status php8.5-fpm --no-pager
```

Use a PHP version supported by your chosen Nextcloud release.

## 3. Prepare Storage

The `zfspool` disks (destined for `/mnt/raid`) haven't been physically moved to `dimarzio` yet,
so install Nextcloud's datadirectory on `dimarzio`'s local/normal filesystem for now. Once
Phase 3 completes and the pool is imported and mounted at `/mnt/raid`, you will relocate the
datadirectory there (see section 14).

Create a temporary local data directory:

```bash
mkdir -p /srv/nextcloud-data
chown -R www-data:www-data /srv/nextcloud-data
chmod 750 /srv/nextcloud-data
```

A simple layout is:

```text
/var/www/nextcloud       Nextcloud application code
/srv/nextcloud-data      Nextcloud user data (temporary, until moved to /mnt/raid)
/var/backups/nextcloud   database dumps and migration backups
```

## 4. Create the PostgreSQL Database

Switch to the `postgres` account and create a database user and database:

```bash
sudo -u postgres psql
```

Inside `psql`:

```sql
CREATE USER nextcloud WITH PASSWORD 'replace-with-a-strong-password';
CREATE DATABASE nextcloud TEMPLATE template0 ENCODING 'UTF8' OWNER nextcloud;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
\q
```

Confirm local password authentication works:

```bash
psql -h localhost -U nextcloud -d nextcloud -c 'SELECT version();'
```

## 5. Download Nextcloud

```bash
cd /tmp
curl -LO https://download.nextcloud.com/server/releases/latest.tar.bz2
curl -LO https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256
sha256sum -c latest.tar.bz2.sha256

tar -xjf latest.tar.bz2
mv nextcloud /var/www/nextcloud
chown -R www-data:www-data /var/www/nextcloud
```

## 6. Configure Nginx on dimarzio

Nginx replaces the Apache virtual host on `dimarzio`, but it should not copy the old Apache
`*:80 -> https://nc.yourdomain.com:8443/` redirect or the local Cloudflare certificate. Public
HTTPS stays on the Caddy LXC, and Caddy proxies to `dimarzio` over LAN HTTP.

First find the active PHP-FPM socket:

```bash
ls /run/php/php*-fpm.sock
```

Example output:

```text
/run/php/php8.5-fpm.sock
```

Use that path in the `fastcgi_pass` line below. If your output shows a different PHP version,
adjust the socket path accordingly.

Nginx's bundled `mime.types` has no `.mjs` entry, so browsers get `application/octet-stream` for
Nextcloud's JS module scripts and refuse to load them. Add `mjs` to the existing JavaScript line
in the system-wide file (do not add a `types { }` block inside the site's `server` block — that
directive replaces rather than merges the mime-type table, breaking every other file type for
that vhost):

```bash
grep -n 'application/javascript\|text/javascript' /etc/nginx/mime.types
sudo sed -i '/application\/javascript/ s/js;/js mjs;/' /etc/nginx/mime.types
```

Create `/etc/nginx/sites-available/nextcloud`:

```nginx
server {
    listen 80;
    server_name nc2.yourdomain.com nc.yourdomain.com yourdomain.com;

    root /var/www/nextcloud;
    index index.php index.html /index.php$request_uri;

    access_log /var/log/nginx/nc.yourdomain.com_access.log;
    error_log /var/log/nginx/nc.yourdomain.com_error.log;

    client_max_body_size 10G;
    fastcgi_buffers 64 4K;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-Download-Options "noopen" always;

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation { try_files $uri $uri/ =404; }
        return 301 /index.php$request_uri;
    }

    location / {
        rewrite ^ /index.php$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        return 404;
    }

    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        return 404;
    }

    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|ocs-provider/.+|.+/richdocumentscode/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
        fastcgi_param HTTP_X_FORWARDED_HOST $host;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:/run/php/php8.5-fpm.sock;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_max_temp_file_size 0;
        # /settings/ajax/checksetup runs several checks, including outbound
        # connectivity tests, and can exceed Nginx's 60s default timeout.
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
    }

    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        expires 6M;
        access_log off;
    }

    location ~ \.(?:otf|woff2?)$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }

    location /remote {
        return 301 /remote.php$request_uri;
    }
}
```

If `dimarzio` has multiple network interfaces and you want Nginx bound only to the LAN address, use
this instead of `listen 80;`:

```nginx
listen DIMARZIO_IP:80;
```

Enable the site and disable the default Nginx page:

```bash
ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
rm -f /etc/nginx/sites-enabled/default
```

Make sure PHP-FPM and Nginx are enabled and running:

```bash
systemctl enable --now nginx php8.5-fpm
systemctl status nginx --no-pager
systemctl status php8.5-fpm --no-pager
```

Validate and reload Nginx:

```bash
nginx -t
systemctl reload nginx
```

Before testing through Caddy, verify that `dimarzio` answers locally on port 80:

```bash
curl -I -H 'Host: nc2.yourdomain.com' http://127.0.0.1/status.php
curl -I -H 'Host: nc2.yourdomain.com' http://DIMARZIO_IP/status.php
```

The first command tests Nginx locally on `dimarzio`; the second confirms it is reachable on the LAN
from the address Caddy will proxy to. If the second command fails from the Caddy LXC, check the
firewall on `dimarzio` and make sure Nginx is listening on the LAN interface:

```bash
ss -ltnp | grep ':80'
```

If `dimarzio` uses `ufw`, allow HTTP only from the Caddy LXC:

```bash
ufw allow from 10.20.1.222 to any port 80 proto tcp
ufw status verbose
```

## 7. Run the Nextcloud Installer

Run the initial install with PostgreSQL:

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database pgsql \
  --database-host localhost \
  --database-name nextcloud \
  --database-user nextcloud \
  --database-pass 'replace-with-a-strong-password' \
  --admin-user admin \
  --admin-pass 'replace-with-a-temporary-admin-password' \
  --data-dir /srv/nextcloud-data
```

## 8. Configure Reverse Proxy Settings

Set the temporary `nc2` hostname first:

```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 0 --value=nc2.yourdomain.com:8443
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value=nc.yourdomain.com:8443
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_proxies 0 --value=10.20.1.222
sudo -u www-data php /var/www/nextcloud/occ config:system:set forwarded_for_headers 0 --value=HTTP_X_FORWARDED_FOR
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwritehost --value=nc2.yourdomain.com:8443
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwriteprotocol --value=https
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwrite.cli.url --value=https://nc2.yourdomain.com:8443
```

## 9. Configure Redis and Background Jobs

Enable APCu local cache and Redis file locking:

```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.local --value='\OC\Memcache\APCu'
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
sudo -u www-data php /var/www/nextcloud/occ config:system:set redis host --value=127.0.0.1
sudo -u www-data php /var/www/nextcloud/occ config:system:set redis port --value=6379 --type=integer
systemctl restart redis-server php8.5-fpm
```

Using TCP (`127.0.0.1:6379`) rather than a Unix socket avoids depending on Redis's `unixsocket`
directive being enabled in `/etc/redis/redis.conf`, which it isn't by default on Debian/Ubuntu —
pointing Nextcloud at a socket path that doesn't exist causes `RedisException: No such file or
directory` on every file-lock attempt (visible in `nextcloud.log` as `acquireLock` failures), which
silently breaks anything that needs locking, including WOPI `GetFile` requests from Collabora
(returned as a 403 to the client with no useful error).

Use cron background jobs:

```bash
sudo -u www-data php /var/www/nextcloud/occ background:cron
crontab -u www-data -e
```

Add:

```cron
*/5 * * * * php -f /var/www/nextcloud/cron.php
```

## 10. Tune PHP

Edit the active PHP-FPM `php.ini`, for example `/etc/php/8.5/fpm/php.ini`:

```ini
memory_limit = 512M
upload_max_filesize = 10G
post_max_size = 10G
max_execution_time = 3600
max_input_time = 3600
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=60
```

Reload PHP-FPM:

```bash
systemctl reload php8.5-fpm
```

## 11. Install Core Apps (Documents, Memories, Music)

Install these apps as part of Phase 1 (preparing the new instance) so the fresh `nc2` instance
already has the apps your clients depend on, before any data or disks move over.

The **Text** app (in-browser document creation/editing for `.md`/`.txt`) ships bundled with
Nextcloud and is enabled by default; verify with:

```bash
sudo -u www-data php /var/www/nextcloud/occ app:list --enabled | grep -i text
```

If you also want full office document editing (Writer/Calc/Impress via Collabora Online), see
section 16 for setting that up alongside this instance.

Install **Memories** (photo timeline) and **Music**:

```bash
apt install -y exiftool ffmpeg
sudo -u www-data php /var/www/nextcloud/occ app:install memories
sudo -u www-data php /var/www/nextcloud/occ app:install music
sudo -u www-data php /var/www/nextcloud/occ app:enable memories
sudo -u www-data php /var/www/nextcloud/occ app:enable music
```

`exiftool` and `ffmpeg` are required by Memories for metadata extraction and video thumbnails.

Both apps rely on scanning files that live under each user's Nextcloud file tree. Since your
photo/music libraries currently live in the core datadirectory on the `zfspool` ZFS pool
(`/mnt/raid/nextcloud-data` on `morla`), indexing (`occ files:scan`, `occ music:scan`) only needs
to run **after** Phase 3, once that pool is imported on `dimarzio` and the datadirectory is
relocated to `/mnt/raid` (see section 14). For now, just get the apps installed and enabled so no
separate app-install step is needed later.

## 12. Migrate Subsonic / Music App Configuration

The **Music** app exposes a Subsonic-compatible API, which is what Subsonic-client apps (e.g.
DSub, Ultrasonic, play:Sub, Sonixd) use to stream your library. To keep those clients working with
minimal changes:

1. In each client, update the **server URL** to the new instance:
   - During testing: `https://nc2.yourdomain.com:8443`
   - After cutover (section 15): `https://nc.yourdomain.com:8443`
2. Generate a dedicated **app password** for each Subsonic client instead of reusing your main
   account password (Nextcloud Settings -> Security -> "Devices & sessions" -> Create new app
   password). Subsonic clients authenticate on every request, so an app password limits exposure
   if a client device is lost.
3. Keep the same **username** on `dimarzio` as on the old instance so clients don't need their
   username field changed, only the server URL and app password.
4. Playlists created inside the Music app are stored in the Nextcloud database, not as files, so
   they do not travel with the ZFS pool. If you want to preserve them, export playlists to
   `.m3u` from the Music app UI on the old instance before decommissioning it, then re-import them
   on the new instance once the library is scanned (section 14.3).
5. Music library scanning depends on the audio files being visible under the user's files, which
   only happens after Phase 3 (datadirectory relocated to `/mnt/raid` on `dimarzio`). Until then,
   clients will authenticate successfully but see an empty/stale library.

## 13. Test nc2

From a machine outside the LAN, test through Cloudflare and Caddy:

```bash
curl -vkI https://nc2.yourdomain.com:8443
curl -vkI https://nc2.yourdomain.com:8443/.well-known/carddav
```

Expected results:

- The main URL returns `200`, `302`, or another valid Nextcloud response.
- `/.well-known/carddav` returns a redirect to `/remote.php/dav/`.
- Nextcloud admin overview's setup/security check finishes instead of staying on "Checking
  server..." or failing with "Failed to run setup checks".

### 13.1 Troubleshoot "Failed to run setup checks"

If the external scanner works but the built-in Nextcloud admin Overview check fails, debug the
`checksetup` endpoint itself. The browser message is generic; the real cause is in the HTTP status
and `nextcloud.log`.

First confirm that `dimarzio` can reach both the old working hostname and the temporary hostname:

```bash
curl -vkI https://nc.yourdomain.com:8443/status.php
curl -vkI https://nc2.yourdomain.com:8443/status.php
curl -vkI https://nc2.yourdomain.com:8443/.well-known/carddav
```

Then, in the browser DevTools Network tab, reload **Settings > Administration > Overview** and
inspect the `checksetup` request:

```text
https://nc2.yourdomain.com:8443/settings/ajax/checksetup
```

Record its status code (`500`, `504`, `403`, etc.) and response body. At the same time, tail the
Nextcloud and PHP-FPM logs on `dimarzio`:

```bash
tail -f /srv/nextcloud-data/nextcloud.log
journalctl -u php8.5-fpm -f
tail -f /var/log/nginx/nc.yourdomain.com_error.log
```

Known causes encountered during this migration:

- `504 Gateway Timeout`: raise the Nginx FastCGI timeouts in section 6, then reload Nginx.
- `RedisException: No such file or directory`: Nextcloud is pointed at a Redis Unix socket that
  does not exist. Use the TCP Redis configuration from section 9 (`127.0.0.1:6379`) and verify
  with `redis-cli -h 127.0.0.1 -p 6379 ping`.
- `checksetup` stays pending for one or more minutes: ensure every `trusted_domains` entry includes
  the public `:8443` port. The `Data directory protected` check tests `overwrite.cli.url` and every
  trusted domain using both HTTP and HTTPS; a hostname without `:8443` makes it wait on the unused
  default ports 80 and 443. Check the active list with `occ config:system:get trusted_domains`.
- Wrong proxy/source IP in logs: confirm `trusted_proxies` contains the Caddy LXC IP and that
  Caddy forwards `X-Forwarded-Proto https` and `X-Forwarded-Host` for `nc2`.
- Self-connectivity mismatch: compare `curl -vkI` results for `nc` and `nc2` from `dimarzio`, not
  only from your laptop or phone. The built-in check runs from the server side.

## 14. Phase 3: Full Migration from nc on morla

This is a complete migration: the old database plus its matching data directory are moved to
`dimarzio`. It preserves users, shares, versions, trashbin, calendars, contacts, Music playlists,
and app configuration. Do **not** use a file-only scan for this goal.

Keep the working `dimarzio` Nginx, Caddy, PHP-FPM, Redis, and reverse-proxy configuration. The
old instance identity (`instanceid`, `secret`, and `passwordsalt`) must move with its database and
data directory. Merge those values into the target config; never blindly replace the whole file.

### 14.1 Match versions and save rollbacks

The old `nc` code and `nc2` code must be on the exact same Nextcloud version, with compatible app
versions. Record the state on both hosts, then upgrade the old instance if necessary:

```bash
sudo -u www-data php /var/www/nextcloud/occ status
sudo -u www-data php /var/www/nextcloud/occ app:list
```

On `dimarzio`, retain the successful fresh database/configuration before replacing it:

```bash
mkdir -p /var/backups/nextcloud
sudo -u postgres pg_dump -Fc nextcloud > /var/backups/nextcloud/nc2-fresh-before-migration.dump
cp -a /var/www/nextcloud/config/config.php /var/backups/nextcloud/nc2-config-before-migration.php
```

On `morla`, confirm the database name and PostgreSQL versions before the cutover. The destination
PostgreSQL version must be equal to or newer than the source version:

```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:get dbname
psql --version
```

Run `psql --version` on `dimarzio` too. Replace `nextcloud` below with the database name reported
by `occ` if it differs.

### 14.2 Dump and restore nc's PostgreSQL database

On `morla`, start the maintenance window, keep it enabled for the remainder of the cutover, and
create a consistent PostgreSQL dump plus a copy of the configuration:

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
sudo -u www-data php /var/www/nextcloud/occ status
sudo install -d -m 700 /root/nextcloud-migration
sudo cp -a /var/www/nextcloud/config/config.php /root/nextcloud-migration/morla-config.php
sudo -u postgres pg_dump -Fc --no-owner --no-privileges -d nextcloud \
  > /root/nextcloud-migration/morla-nextcloud-postgres.dump
```

Copy both files to `dimarzio` before moving the disks. Use an SSH account that can read the
source backup and write to `/var/backups/nextcloud`; for example, from `morla` as root:

```bash
scp /root/nextcloud-migration/morla-config.php \
  /root/nextcloud-migration/morla-nextcloud-postgres.dump \
  dimarzio:/var/backups/nextcloud/
```

On `dimarzio`, create a dedicated target database and restore the dump. This does not touch the
working fresh `nextcloud` database, which remains a rollback option:

```bash
sudo -u postgres psql <<'SQL'
CREATE USER nextcloud_migration WITH PASSWORD 'replace-with-a-strong-password';
CREATE DATABASE nextcloud_migration TEMPLATE template0 ENCODING 'UTF8' OWNER nextcloud_migration;
SQL
sudo -u postgres pg_restore --no-owner --no-privileges \
  -d nextcloud_migration /var/backups/nextcloud/morla-nextcloud-postgres.dump
sudo -u postgres psql -d nextcloud_migration -c 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO nextcloud_migration;'
sudo -u postgres psql -d nextcloud_migration -c 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO nextcloud_migration;'
```

Leave `nc` on `morla` in maintenance mode. The dump is now a stable point-in-time copy, so no
later change on `morla` can be missing from the restored database.

### 14.3 Move zfspool

Stop `nc` and keep it in maintenance mode. Export and move the pool using
[zfspool-move-morla-to-dimarzio.md](./zfspool-move-morla-to-dimarzio.md), then import it on
`dimarzio` at `/mnt/raid` and complete the post-move scrub. The old datadirectory must be at
`/mnt/raid/nextcloud-data`.

### 14.4 Merge configuration and start the migrated instance

On `dimarzio`, stop the fresh test instance and retain both configuration files:

```bash
sudo systemctl stop nginx php8.5-fpm
cp -a /var/www/nextcloud/config/config.php /var/backups/nextcloud/nc2-config-pre-cutover.php
```

Edit `config.php`. Keep target values for `trusted_domains`, `trusted_proxies`,
`forwarded_for_headers`, `overwritehost`, `overwriteprotocol`, `overwrite.cli.url`, and Redis
(`127.0.0.1:6379`). Bring across from `/var/backups/nextcloud/morla-config.php` only:

```php
'instanceid' => 'value-from-morla',
'passwordsalt' => 'value-from-morla',
'secret' => 'value-from-morla',
'data-fingerprint' => 'value-from-morla',
'datadirectory' => '/mnt/raid/nextcloud-data',
'dbtype' => 'pgsql',
'dbname' => 'nextcloud_migration',
'dbhost' => 'localhost',
'dbuser' => 'nextcloud_migration',
'dbpassword' => 'the-migration-database-password',
```

Start the services and validate before switching the canonical hostname:

```bash
chown -R www-data:www-data /mnt/raid/nextcloud-data
sudo systemctl start php8.5-fpm nginx
sudo -u www-data php /var/www/nextcloud/occ status
sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
sudo -u www-data php /var/www/nextcloud/occ files:scan --all
sudo -u www-data php /var/www/nextcloud/occ music:scan --all
```

Test through `nc2`: files, shares, calendars/contacts, Memories, Music playlists, and a Collabora
edit. Then follow section 15 for the public `nc` cutover. Keep the rollback backups until stable.
## 15. Cut Over from nc2 to nc

After `nc2.yourdomain.com:8443` is fully tested, switch the canonical hostname back to `nc`.

On the Caddy LXC, update the `nc.yourdomain.com:8443` block so it proxies to `dimarzio`:

```caddyfile
nc.yourdomain.com:8443 {
  redir /.well-known/carddav /remote.php/dav/ 301
  redir /.well-known/caldav /remote.php/dav/ 301

  reverse_proxy http://DIMARZIO_IP:80 {
    header_up Host nc.yourdomain.com:8443
    header_up X-Forwarded-Host nc.yourdomain.com:8443
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Port 8443
  }
}
```

Validate and reload Caddy:

```bash
set -a && . /etc/caddy/environment && set +a && caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

On `dimarzio`, update the canonical Nextcloud URL:

```bash
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwritehost --value=nc.yourdomain.com:8443
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwrite.cli.url --value=https://nc.yourdomain.com:8443
```

Then test:

```bash
curl -vkI https://nc.yourdomain.com:8443
curl -vkI https://nc.yourdomain.com:8443/.well-known/carddav
```

Keep `nc2` temporarily as a rollback/testing hostname, then remove it from Caddy, Cloudflare DNS,
and `trusted_domains` once `nc` is stable.

## 16. Set Up Document Editing (Collabora Online)

This adds real Word/Excel/PowerPoint editing via Collabora Online (CODE), running as its own
Docker container on `dimarzio`, alongside the Nextcloud instance from the earlier sections. It
can be done at any point once `nc2`/`nc` is up and reachable.

### 16.1 Install Docker on dimarzio

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

### 16.2 Run the Collabora Online container

Bind it to `dimarzio`'s LAN address (not `127.0.0.1`), since Caddy on its own LXC needs to reach
it over the network, same as it reaches Nginx on port 80. List every hostname Nextcloud is or
will be served under in `aliasgroup1`:

```bash
docker run -d --name collabora --restart=always \
  -p DIMARZIO_IP:9980:9980 \
  -e 'aliasgroup1=https://nc2.yourdomain.com:8443,https://nc.yourdomain.com:8443' \
  -e 'extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.post_allow.host[0]=10\\.20\\.1\\.222' \
  --cap-add MKNOD \
  --cap-add SYS_ADMIN \
  collabora/code
```

Collabora terminates TLS itself normally, but since Caddy already handles public TLS and talks to
`dimarzio` over plain LAN HTTP (same pattern as the rest of this guide), `ssl.termination=true`
tells Collabora to trust the `X-Forwarded-*` headers from the proxy instead of expecting HTTPS
directly.

`net.post_allow.host` is Collabora's own IP allow-list for its conversion/admin endpoints
(separate from `aliasgroup1`, which only covers WOPI host trust). Without it you'll see log lines
like `Conversion requests not allowed from this address` even though the container is otherwise
reachable. Replace `10\\.20\\.1\\.222` with the Caddy LXC's actual LAN IP if different (dots
escaped since this is a regex).

Collabora's LibreOffice "Kit" rendering process needs `coolmount` to set up a chroot jail per
document, which requires the `CAP_SYS_ADMIN` capability. Without it, every Kit process fails
immediately (`Failed to exec coolmount ... needs CAP_SYS_ADMIN`, `Unknown child has exited, with
status: 71` in a tight crash loop), so documents never actually render for editing. An
`--o:mount_jail_tree=false` extra_param does **not** reliably disable this requirement in current
Collabora releases, so grant the capability directly instead.

Restrict access to just the Caddy LXC, the same way section 6 restricts Nginx:

```bash
ufw allow from 10.20.1.222 to any port 9980 proto tcp
```

### 16.3 Publish it through Caddy

Add a dedicated hostname (e.g. `office.yourdomain.com:8443`) in Cloudflare DNS (same proxied A
record pattern as `nc2` in section 1), then add a Caddy block:

```caddyfile
office.yourdomain.com:8443 {
  reverse_proxy http://DIMARZIO_IP:9980 {
    header_up -X-Forwarded-For
  }
}
```

Collabora evaluates `net.post_allow.host` against the `X-Forwarded-For` header when present,
which by default would otherwise contain Cloudflare's edge IP (since that's who connects to
Caddy), not Caddy's own address — causing the same `Requesting address is denied` warning even
with the container's allow-list configured correctly. Stripping the header makes Collabora fall
back to the real TCP peer, which is the Caddy LXC's IP allow-listed in section 16.2.

Caddy's `reverse_proxy` handles the WebSocket upgrade Collabora needs automatically. Validate and
reload as in section 1:

```bash
set -a && . /etc/caddy/environment && set +a && caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

### 16.4 Install and configure richdocuments in Nextcloud

```bash
sudo -u www-data php /var/www/nextcloud/occ app:install richdocuments
sudo -u www-data php /var/www/nextcloud/occ app:enable richdocuments
sudo -u www-data php /var/www/nextcloud/occ config:app:set richdocuments wopi_url --value=https://office.yourdomain.com:8443
```

In the Nextcloud admin UI, go to **Settings > Nextcloud Office** and confirm the server URL shows
a green checkmark. If it fails, check that:

- `office.yourdomain.com` resolves and is reachable the same way `nc2`/`nc` are (Cloudflare +
  Caddy + `dimarzio`).
- The `ufw` rule in 16.2 allows the Caddy LXC's IP.
- The container is actually running: `docker ps`, `docker logs collabora`.

### 16.5 Test

Create or open a `.docx`/`.xlsx`/`.pptx` file from the Nextcloud web UI; it should open inline in
the Collabora editor instead of downloading.

## Notes

- Do not make `nc.yourdomain.com` permanently redirect to `nc2.yourdomain.com`.
- The canonical URL should be the one users and clients actually use.
- Keep `forwarded_for_headers` to `HTTP_X_FORWARDED_FOR` only.
- Keep `dimarzio` behind Caddy; no public router rule should point directly to it.
- If the Cloudflare token was previously printed in logs, rotate it before treating the setup as final.
