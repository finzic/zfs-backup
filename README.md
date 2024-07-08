# zfs-backup
A script and a method for my home personal backup system based on ZFS

## Quick Summary
- Use your Linux box as a NAS Server with powerful features
- Use your leftover Raspberry Pi or similar as a NAS Backup server
- Harness the power of ZFS Snapshots and Samba to have all history at your fingertips that is available in Windows as "Previous Versions" - just like Windows Restore Points!
- Easily configure different backup destinations for multiple backup copies
- ZFS enables to have a secure upgrade path when more disk capacity is needed
- Monitor backup progress with a simple progress bar

## Example usage
`./zfs-backup.sh Music` 

Loads the `Music.bkp` configuration file, which is something like this: 

```
SRC_POOL=zfspool
SRC_DATASET=Music

DST_POOL=backuppool
DST_DATASET=Music

DST_USERNAME=remoteuser
DST_ADDR=raspberry-server.local
```

This would back up the `zfspool/Music` ZFS dataset to the `backuppool/Music` dataset on `raspberry-server.local` as the user `remoteuser`. 

That's it. 


