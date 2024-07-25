# zfs-backup
A script and a method for my home personal backup system based on ZFS

## Quick Summary
- Use your Linux box as a NAS Server with powerful features
- Use your leftover Raspberry Pi or similar as a NAS Backup server
- Harness the power of ZFS Snapshots and Samba to have all history of both your NAS _AND_ your backup server at your fingertips, available in Windows as "Previous Versions" - just like Windows Restore Points!
- Easily configure different backup destinations for multiple backup copies
- ZFS enables to have a secure upgrade path when more disk capacity is needed
- Monitor backup progress on the shell with a simple progress bar

## Example usage
```
Usage: zfs-backup.sh [-s | -b ] <Backup_Descriptor> 

    -s : create a snapshot now, if needed, on the local ZFS filesystem described in <Backup_Descriptor>.
    -b : launch a backup operation as specified in <Backup_Descriptor>
    -h : print this message

    <Backup_Descriptor> file is a text file whose name shall end in '.bkp'. 
    It contains the following shell variables: 
            SRC_POOL=<source ZFS pool name>
            SRC_DATASET=<source dataset name>
            DST_POOL=<destination ZFS pool name>
            DST_DATASET=<destination ZFS dataset name> 
            DST_USERNAME=<destination username>
            DST_ADDR=<destination address>
```
## Complete Information 
Check the project's WIKI! 



