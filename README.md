# zfs-backup
A script and a method for my home personal backup system based on ZFS

## TL;DR Quick Summary

- Server system: Ubuntu 22.04, 3 x 2TB WD RED HDDs used as ZFS raidz1 vdev pool (pool name: ``zfspool``). Around 4TB total available storage capacity.
- Backup system: Raspberry Pi 4, 4GB RAM, 1 x 4TB WD BLUE used as ZFS simple vdev (just a vdev with a single device) 
- Several dataset defined on this pool such as 
	- zfspool/Documents, 
	- zfspool/Music, 
	- zfspool/Foto
- Datasets are available to my default Windows PC as Samba shares, protected by simple username and password on my LAN.
- Subsequent snapshots on the server are transferred _at file system level_ to the backup system, taking advantage of full bandwidth on your LAN
- The Backup System presents the snapshots as _Windows "Previous Versions"_, as read-only folders, which is extremely useful if I deleted some file during the life of my system and wanted to get back at that file later on. 
- Snapshots on server are created via ``zfs-backup.sh`` script, which transfers the snapshot to the Backup System, along with a list of checksums of the modified files, so that the Backup System could verify all of them at the and of the snapshot transfer. 

## System Initial Configuration
- Install packages on server: 
	- zfstools-linux
	- pv 
	- rsync

- Install packages on backup system: 
	- zfstools-linux
	- rsync

### Create ZFS pool on server 
- Install 3 unformatted disks. They only need a GPT partition table to be created but no partitions. ZFS will handle them all. 

```
zpool create \    # command to create a pool 
-o ashift=12 \    # alignment of data, read somewhere (!)
-f \              # forces use of vdevs
zfspool \         # name of the pool
raidz \           # use raidz1 strategy, similar to RAID 5 of mdadm: you can loose 1 disk.
/dev/disk/by-id/ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M1EDJV8E(1234) \ serial # of 1st disk 
/dev/disk/by-id/ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M6YRK3EE(3456) \ serial # of 2nd disk
/dev/disk/by-id/ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M1EDJVN4(5678) \ serial # of 3rd disk
```

Now we have a pool. Test it with ``zpool status``: 



## Background

I have a home server with very old hardware, by today's standards. I have been using it for at least 15 years without major hiccups do save all my personal important media: photos, videos, music, documents, the same old stuff you know. 

This system for me is very important because I have never accepted the mainstream widespread idea of "clouds" as services whom I send my personal data to. I started getting quite worried by questions such as "where am I going to send my data" or "who is going to be able to manipulate my data?" or "Are they going to make me pay some extra fee someday to access my own data?" 

Also I am almost obsessed by data loss of my beloved pictures, so I came up with this backup script idea during COVID-19 3-month "forced stay at home", stealing time to my sleep because I needed to do something useful for myself other than working from home and taking care of my family, young 2-year-old toddler included. 

## System Description

Initially my setup was based on linux's `mdadm` and I had defined a RAID-5 md0 device with 3 2-TB WD RED hard disks, which hosted a total of near 4TB of useable space, since 2TB more or less were used for parity information. 

My backup system is made of the following elements: 

1) Server: my "server" machine, a Linux box with Ubuntu installed, a SSD which hosts the OS, and 3x2TB WD RED HDDs for data storage, which are configured in Software RAID-5 using standard ``mdadm`` tool.
This system exposes some SMB shares, such as "Foto", "Video", "Music", "Documents", which are mapped to ``/mnt/raid/Foto`` and so on. They are available on my home network and protected with simple username and password.  

2) My Raspberry PI 4 (``raspi``) , with a 4TB WD BLUE disk used for "server" data backup. 

3) The 4TB WD BLUE HDD is formatted with BTRFS, to take advantage of the snapshot feature 

4) A (set of) bash scripts that backup my data to the Raspberry Pi 4 and create snapshots using ``rsync``

5) Backup folders and snapshots are made available through Samba: folders are available as shares and snapshots appear as Windows' "Previous Versions". 

## Why change from MDADM RAID-5 to ZFS? 

Software RAID-5 has always been working fine for me, except when it came to error detection. One day I saw by chance that my RAID-5 array was running in `degraded mode` because apparently one of the disks was not detected anymore. No previous signal of any strange behaviour. I started preparing a spare disk, and decidded that I would have checked cables first. 

It turned out I was very lucky: a quick unplug/plug again of all HDD's cables and everything was back in place. The apparently missing HDD was immediately recognised and the system "resilvered" (Sorry ZFS for borrowing your teminology) straightforwardly. 

No signal, no alert, no sign of problem ahead of the problem itself. 

This episode was, let's say, the final straw that I needed to try and go down the ``nerd way``: ZFS! 

I have heard of ZFS since a really long time, but I always believed it was a filesystem used and useful only for immensely large data centers and so on. I was wrong. 
