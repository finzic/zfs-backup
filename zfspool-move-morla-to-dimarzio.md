# Moving the `zfspool` ZFS Pool from morla to dimarzio

This guide covers physically relocating the 3x4TB disk `zfspool` ZFS pool from `morla` to
`dimarzio` as safely as possible.

## 1. Pre-move health check (on morla)

```bash
zpool status -v zfspool
smartctl -a /dev/sdX | grep -E 'Reallocated|Pending|Uncorrectable|Health'
```

Confirm no faulted/degraded vdevs and no unresolved errors.

Run a scrub now if one hasn't completed recently, and let it finish clean:

```bash
zpool scrub zfspool
zpool status zfspool   # wait until scan: scrub repaired 0B ... completed
```

Check ZFS feature flags/version compatibility, since `dimarzio` needs to support at least the
same feature set:

```bash
zpool get all zfspool | grep feature
zfs version
```

On `dimarzio`, check `zfs version` too — if `dimarzio`'s ZFS is older, it may refuse to import a
pool using newer feature flags. Upgrade `dimarzio`'s ZFS/kernel first if needed (never downgrade
a pool).

## 2. Record identifying information

```bash
zpool status zfspool
ls -la /dev/disk/by-id/ | grep -E "$(zpool status zfspool | grep -oE 'sd[a-z]' | paste -sd'|')"
```

Write down, for each of the 3 disks:

- Serial number (from `smartctl -i /dev/sdX` or the label on the drive)
- Its current `by-id` device path (e.g. `ata-WDC_WD40.....`)
- Its role in the pool (which vdev, e.g. raidz1 member 1/2/3)
- Physical bay/slot position, if labeled

This lets you confirm nothing got mixed up after reinsertion and diagnose any bay/cable issue
later.

## 3. Stop everything using the pool

```bash
# Stop any services/containers/shares that read/write the pool
systemctl stop smbd nfs-server <your-backup-jobs> ...
lsof +D /zfspool | head       # confirm nothing has open files
zfs list -t snapshot -r zfspool   # note snapshots you want to keep (they travel with the pool automatically)
```

## 4. Cleanly export the pool

```bash
zpool export zfspool
```

- This flushes everything, unmounts datasets, and marks the pool as exportable — do **not** use
  `-f` unless it fails and you've verified nothing is still using it.
- After export, `zpool status` on `morla` should show no pools (or "no pools available").
- Do not touch/write to those disks again from `morla` after this point.

## 5. Power down and physically remove disks

- Shut down `morla` cleanly: `shutdown -h now`.
- Unplug power before removing SATA/SAS drives, even hot-swappable ones — safer given a full
  physical relocation.
- Handle drives with ESD precautions (touch grounded metal, avoid static-prone surfaces/carpet).
- Label each drive immediately (masking tape/sticker) with the serial you recorded, so you don't
  need to guess later.
- Transport flat or vertically as designed, avoid shocks/drops.

## 6. Install into dimarzio

- Insert into `dimarzio`'s bays/slots, connect SATA/SAS + power.
- If `dimarzio` is running, it can often detect hot-plugged SATA disks, but for a first-time move
  it's cleaner to power `dimarzio` down, install all 3 drives, then boot.
- Boot `dimarzio` and confirm the OS sees all 3 disks:

```bash
lsblk
ls /dev/disk/by-id/ | grep -i ata
smartctl -i /dev/sdX   # confirm serials match your notes
```

## 7. Import the pool on dimarzio

First do a dry-run/list to make sure it's detected correctly, then import using stable `by-id`
paths so it isn't sensitive to future device renaming:

```bash
zpool import
```

This lists any importable pools. If it shows `zfspool` with the right name/GUID, and if
`dimarzio` doesn't already have a pool with that name:

```bash
zpool import -d /dev/disk/by-id zfspool
```

If `dimarzio` already uses that pool name for something else, import under a new name instead:

```bash
zpool import -d /dev/disk/by-id zfspool zfspool-morla
```

If it complains the pool was not cleanly exported (shouldn't happen since you exported it), you'd
see a warning requiring `-f` — investigate before forcing.

## 8. Verify integrity after import

```bash
zpool status -v zfspool
zfs list -r zfspool
zpool scrub zfspool
zpool status zfspool   # wait for scrub to complete, confirm 0 errors
```

Scrubbing after a physical move is the most important safety step — it verifies every block
against checksums and confirms the move didn't introduce any corruption or bad cabling/connector
issues.

## 9. Reattach to the system

- Set/verify mountpoints (`zfs get mountpoint zfspool`), adjust if `dimarzio`'s layout differs
  from `morla`'s.
- Fix ownership (`chown`) if UID/GID mapping differs between machines (compare `/etc/passwd` UID
  for e.g. `www-data`, backup users, etc.).
- Update any `fstab`, systemd mount units, Samba/NFS exports, or app configs to point at the
  pool's new location on `dimarzio`.
- Re-enable/restart the services you stopped in step 3, now pointed at `dimarzio`.

## 10. Cleanup

- Keep your pre-move backup (if you have one elsewhere) until you've used the pool on `dimarzio`
  for a while and are confident.
- Set `zpool set autoexpand=on zfspool` only if relevant; not needed just for a relocation.
- Consider re-enabling any scheduled scrub cron/systemd timer on `dimarzio` if it isn't already
  global.

## Key safety points

- Always `zpool export` before disconnecting drives — never yank them from a still-imported pool.
- Never mix up which physical disk goes in which slot in a way that matters — for ZFS it doesn't
  matter (it self-identifies via labels), but keeping track avoids confusion when
  troubleshooting.
- Scrub before and after the move to bookend the operation with integrity proof.
- Make sure `dimarzio`'s ZFS/kernel version is equal or newer than `morla`'s to avoid
  feature-flag import failures.
