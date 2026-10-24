# Migrating from morla to dimarzio (fresh Nextcloud + zfspool as external storage)

## Goal and approach

- `dimarzio` already runs a fresh, working Nextcloud (Nginx, PHP-FPM, PostgreSQL, Redis, Collabora,
  Memories, Music) published as `nc2.yourdomain.com:8443` behind Caddy. **It stays as it is.**
- The old data lives on `morla` in the 3x4TB ZFS pool `zfspool`
  (Nextcloud datadirectory `/mnt/raid/nextcloud-data`).
- The old database is **not** restored. The two accounts are recreated with the same usernames, and
  the pool is attached to dimarzio as **read-only Local external storage**.
- Phones keep the same hostname (`nc.yourdomain.com:8443`), so photo auto-upload keeps working and
  does not re-upload the library.

Priorities:

1. ZFS data available on dimarzio as external storage (safe move).
2. No re-upload of photos from the phones; minimal upload downtime.
3. Symfonium keeps working without re-adding the server; Music playlists preserved.
4. Past users' settings (shares, calendars, contacts) are best effort.

What is lost by not restoring the old DB: shares, versions, trash, tags, comments, calendars,
contacts, Music playlists/ratings/play counts, app passwords and sessions. Files themselves are kept.

```text
Phones/Symfonium -> Cloudflare -> Caddy LXC :8443 -> dimarzio HTTP :80 -> Nextcloud (fresh)
                                                      \-> /mnt/raid (zfspool, external storage, read-only)
```

## Order of operations

1. Prepare on morla: export playlists, contacts, calendars (section 1).
2. Create the two accounts on dimarzio (section 2).
3. Cut `nc` over in Caddy to dimarzio (section 3).
4. Re-login on each phone; verify new uploads (section 4).
5. Move the pool at your own pace (sections 5-9).
6. Move the live datadirectory onto a new dataset in the pool (section 9a).
7. Attach the old morla data as external storage and scan (section 10).
8. Reconfigure Symfonium, import playlists (section 11).
9. Cleanup (section 12).

Because step 3 happens before the pool move, new uploads land on dimarzio immediately and the disk
move causes no upload downtime. Until step 5 finishes, old photos are simply not visible on the new
server.

Rollback until step 5: point Caddy's `nc` block back at morla and reload Caddy. Photos the phones
uploaded to dimarzio in the meantime stay on dimarzio (morla never sees them) and the phone apps
will not re-upload them. Copy them back manually (download from `nc2`, or `rsync` into the user's
folder on morla followed by `occ files:scan`), or keep them on dimarzio until you retry. After
step 5 the disks are on dimarzio, so rolling back means exporting the pool and moving the disks
back.

### Why the live datadirectory goes on the pool

On morla, `nextcloud-data` sits on ZFS. That is worth keeping on dimarzio:

- Checksums and self-healing from redundancy (silent corruption is detected and repaired).
- Cheap snapshots (accidental deletes, ransomware, bad upgrades).
- `zfs send`/`receive` for incremental backups (the zfs-backup scripts).
- Disk-failure tolerance; optional compression (little gain on photos/music).

If only the old archive were on ZFS, new phone uploads would sit on a single local disk, which is
the most valuable new data. Section 9a puts the live datadirectory on the pool as a **separate**
dataset. It cannot reuse `/mnt/raid/nextcloud-data`: that folder belongs to morla's old database
(file IDs, instance ID), which dimarzio does not use.

## 1. Prepare on morla (while it is still online)

- Record usernames of both accounts exactly (case-sensitive):

  ```bash
  sudo -u www-data php /var/www/nextcloud/occ user:list
  ```

- In the Music app UI, export every playlist to `.m3u` (they are stored in the database, not on the
  pool, so they do not travel with the disks). Save them outside the pool.
- Optional: export contacts (`.vcf`) and calendars (`.ics`) from the UI.
- Note the path of the folder phones upload to (usually `InstantUpload` or `Photos`), and where the
  libraries are inside `/mnt/raid/nextcloud-data/<user>/files/`.

## 2. Create the accounts on dimarzio

```bash
sudo -u www-data php /var/www/nextcloud/occ user:add --display-name="Name" USERNAME
sudo -u www-data php /var/www/nextcloud/occ user:add --display-name="Wife" WIFE_USERNAME
```

Usernames must match morla's exactly; phone apps are configured as `user@nc.yourdomain.com`.

## 3. Cut `nc` over to dimarzio

Follow the Caddy and `occ` steps of the cutover section in
[nextcloud-dimarzio-postgresql.md](./nextcloud-dimarzio-postgresql.md):

- `nc.yourdomain.com:8443` proxies to `http://DIMARZIO_IP:80` with `Host`/`X-Forwarded-*` headers.
- `overwritehost` = `nc.yourdomain.com:8443`, `overwrite.cli.url` = `https://nc.yourdomain.com:8443`.
- `trusted_domains` already lists both `nc` and `nc2` with `:8443`.
- Collabora `aliasgroup1` already includes the `nc` hostname.
- `nc` on morla goes offline once Caddy no longer points to it.

## 4. Phones: avoid re-uploading photos

The mobile apps track what they already uploaded in their own local database, not on the server.

- Use the app's **re-login / "session expired"** prompt on the existing account (tokens are invalid
  because the database is new).
- Do **not** remove the account and do **not** add a second one: that resets the auto-upload
  configuration.
- Keep **"upload existing files"** disabled in the auto-upload settings.
- Do not test by pointing a phone at `nc2`: that creates a new account/auto-upload setup.
- Try one phone first, confirm a new photo uploads and old ones do not, then do the second phone.
- Photos taken while the server is unreachable stay queued on the phone and upload later.

## 5. Pre-move checks (morla)

```bash
zpool status -v zfspool
smartctl -a /dev/sdX | grep -E 'Reallocated|Pending|Uncorrectable|Health'
zpool scrub zfspool
zpool status zfspool        # wait for "scrub repaired 0B ... completed"
zpool get all zfspool | grep feature
zfs version
```

On dimarzio check `zfs version`: its ZFS must be equal or newer than morla's, otherwise import can
fail on feature flags. Upgrade dimarzio first if needed; never downgrade a pool.

## 6. Record identifying information

```bash
zpool status zfspool
ls -la /dev/disk/by-id/ | grep -E "$(zpool status zfspool | grep -oE 'sd[a-z]' | paste -sd'|')"
```

For each of the 3 disks note: serial (`smartctl -i /dev/sdX`), `by-id` path, vdev role, physical
bay. Label each drive.

## 7. Stop users of the pool and export (morla)

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on   # if morla Nextcloud is still up
systemctl stop smbd nfs-server <backup-jobs> ...
lsof +D /mnt/raid | head
zfs list -t snapshot -r zfspool
zpool export zfspool
```

- Do not use `-f` unless it fails and you verified nothing uses the pool.
- After export, `zpool status` should show no pools. Do not write to the disks from morla again.
- Optionally copy the old `config.php` somewhere safe for reference.

## 8. Move the disks

- `shutdown -h now` on morla, unplug power before removing drives, use ESD precautions.
- Install all 3 drives in dimarzio (power it down first), boot, then confirm:

```bash
lsblk
ls /dev/disk/by-id/ | grep -i ata
smartctl -i /dev/sdX        # serials match your notes
```

## 9. Import on dimarzio and verify

```bash
zpool import                                  # list importable pools
zpool import -d /dev/disk/by-id zfspool
# if the name is already taken:
# zpool import -d /dev/disk/by-id zfspool zfspool-morla
zfs set mountpoint=/mnt/raid zfspool
zpool status -v zfspool
zfs list -r zfspool
zpool scrub zfspool
zpool status zfspool        # wait for the scrub; confirm 0 errors
```

- If a warning requires `-f` (not cleanly exported), investigate before forcing.
- Compare the `www-data` UID/GID on both hosts (`id www-data`); both are 33 on Debian/Ubuntu. If
  they differ, fix ownership of the data you need (the mount is read-only, so permissions only
  need to allow reads by `www-data`).
- Ensure the pool imports at boot (`zfs-import-cache`/`zfs-mount` services enabled) and that
  Nextcloud/Nginx start after it.
- Re-enable a scrub timer on dimarzio if it is not global.

## 9a. Move the live datadirectory onto the pool

Do this right after the import and clean scrub (section 9), and before section 10 so the old and
new data are separate datasets from the start. It cannot be done earlier because the pool is not
on dimarzio before section 9.

```bash
zfs create -o acltype=posixacl -o xattr=sa -o atime=off -o compression=lz4 zfspool/nextcloud-new
chown www-data:www-data /mnt/raid/nextcloud-new
chmod 750 /mnt/raid/nextcloud-new
```

Optional first pass while Nextcloud is still running (shortens the downtime):

```bash
rsync -a /srv/nextcloud-data/ /mnt/raid/nextcloud-new/
```

Then stop Nextcloud, do the final sync, switch `datadirectory`, and restart:

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
systemctl stop nginx php8.5-fpm
rsync -a --delete /srv/nextcloud-data/ /mnt/raid/nextcloud-new/
cp -a /var/www/nextcloud/config/config.php /var/backups/nextcloud/config-before-datadir-move.php
sudo -u www-data php /var/www/nextcloud/occ config:system:set datadirectory --value=/mnt/raid/nextcloud-new
systemctl start php8.5-fpm nginx
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
sudo -u www-data php /var/www/nextcloud/occ status
```

If `occ` refuses to change `datadirectory`, edit `'datadirectory'` in `config.php` by hand while
the services are stopped. No rescan is needed because the files are identical.

Make PHP-FPM wait for the pool at boot, otherwise Nextcloud may start with a missing datadirectory:

```bash
systemctl edit php8.5-fpm   # add: [Unit]\nRequiresMountsFor=/mnt/raid
```

Then check that a phone upload lands in `/mnt/raid/nextcloud-new/USERNAME/files/`, set up
snapshots on `zfspool/nextcloud-new` (for example with `sanoid` or a cron job), and delete
`/srv/nextcloud-data` only after a few days of stable operation.

## 10. Attach as external storage

Enable the app and allow Local storage (admin-only, off by default):

```bash
sudo -u www-data php /var/www/nextcloud/occ app:enable files_external
sudo -u www-data php /var/www/nextcloud/occ config:system:set files_external_allow_create_new_local --value=true --type=boolean
```

For each user (one mount per user so each sees only their own archive). The mount name must differ
from the phone's upload folder, e.g. `Archive-morla`:

```bash
sudo -u www-data php /var/www/nextcloud/occ files_external:create /Archive-morla local null::null \
  -c datadir=/mnt/raid/nextcloud-data/USERNAME/files
sudo -u www-data php /var/www/nextcloud/occ files_external:list     # note the mount ID
sudo -u www-data php /var/www/nextcloud/occ files_external:applicable --add-user=USERNAME MOUNT_ID
sudo -u www-data php /var/www/nextcloud/occ files_external:option MOUNT_ID read_only true
sudo -u www-data php /var/www/nextcloud/occ files_external:option MOUNT_ID filesystem_check_changes 1
sudo -u www-data php /var/www/nextcloud/occ files:scan --path="USERNAME/files/Archive-morla"
```

Repeat for the second account. Notes:

- Read-only protects the old library from accidental changes. Remove it later only if you want to
  edit in place.
- `www-data` must be able to read `/mnt/raid/nextcloud-data/USERNAME/files`.
- The old `files_versions`, `files_trashbin`, `appdata_*` and `nextcloud.log` on the pool are not
  used; they only take space.
- Phones keep uploading to the primary storage (`/mnt/raid/nextcloud-new` after section 9a), not
  to the external mount. The old data is at `/mnt/raid/nextcloud-data`, a different dataset path.

### 10.1 Memories (photo timeline)

Memories can be awkward with external storage. If the old photos do not appear in the timeline,
copy them into the user's primary storage on dimarzio instead (needs enough local space), which
does not cause phone re-uploads:

```bash
rsync -a /mnt/raid/nextcloud-data/USERNAME/files/<photo-folder>/ /srv/nextcloud-data/USERNAME/files/OldPhotos/
chown -R www-data:www-data /srv/nextcloud-data/USERNAME/files/OldPhotos
sudo -u www-data php /var/www/nextcloud/occ files:scan --path="USERNAME/files/OldPhotos"
```

Then point Memories at the folder(s) in its settings and index:

```bash
sudo -u www-data php /var/www/nextcloud/occ memories:index
```

### 10.2 Music

```bash
sudo -u www-data php /var/www/nextcloud/occ music:scan USERNAME
```

Run long scans in `tmux`. Music files visible only via external storage are scanned like any other
folder inside the user's file tree.

## 11. Symfonium and playlists

Music's Subsonic API is what Symfonium uses.

- Keep the same hostname and username, so in Symfonium **edit the existing server entry** and change
  only the password; do not add a new server.
- In Nextcloud: Settings -> Security -> create a new app password (or use the key in the Music app
  settings) for Symfonium. Subsonic clients authenticate on every request, so an app password limits
  exposure if a device is lost.
- Song/album IDs are new on the new server, so Symfonium must re-sync its library; play counts and
  ratings stored in the old Music app database are not migrated.
- Import the `.m3u` playlists exported in section 1 using the Music app once the scan has finished.
- Contacts and calendars: import the `.vcf` / `.ics` files via the UI if wanted.

## 12. Cleanup and final checks

- Confirm for both users: login, photo auto-upload (a new photo arrives), Collabora editing, the
  `Archive-morla` folder lists correctly, Music streaming in Symfonium.
- Check Nextcloud admin overview for warnings (`checksetup`).
- Keep morla's `config.php` copy and any exported files until the setup is stable.
- Remove `nc2` from Caddy, Cloudflare DNS and `trusted_domains` once `nc` is stable.
- Keep a backup of the pool elsewhere if possible: the disks are now the only copy of the old data.

## Key safety points

- Always `zpool export` before disconnecting drives; never pull them from an imported pool.
- Scrub before and after the move to bookend the operation with integrity proof.
- dimarzio's ZFS version must be equal or newer than morla's.
- The live datadirectory (`zfspool/nextcloud-new`) is separate from morla's old
  `/mnt/raid/nextcloud-data`; never point the new instance at the old folder.
- Never remove or re-add the account in the phone apps; use the re-login prompt.
- Keep "upload existing files" off in auto-upload settings.
