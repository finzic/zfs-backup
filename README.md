# zfs-backup
A script and a method for my home personal backup system based on ZFS

## Background

I have a home server with very old hardware, by today's standards. I have been using it for at least 15 years without major hiccups do save all my personal important media: photos, videos, music, documents, the same old stuff you know. 

This system for me is very important because I have never accepted the mainstream widespread idea of "clouds" as services whom I send my personal data to, regardless or not really thinking about "where I am going to send my data" or "who is going to be able to manipulate my data?" or "Are they going to make me pay, someday, some extra to access my own data?" 

Also I am almost obsessed by data loss of my beloved pictures, so I came up with this backup script idea during COVID-19 3-month "forced stay at home", stealing time to my sleep because I needed to do something useful for myself other than working from home and taking care of my family, young 2-year-old toddler included. 

Initially my setup was based on linux's `mdadm` and I had defined a RAID-5 md0 device with 3 2-TB WD RED hard disks, which hosted a total of near 4TB of useable space, since 2TB more or less were used for parity information. 

My backup system is made of the following elements: 

1) Server: my "server" machine, a Linux box with Ubuntu installed, a SSD which hosts the OS, and 3x2TB WD RED HDDs for data storage, which are configured in Software RAID-5 using standard ``mdadm`` tool. 

2) my Raspberry PI 4, with a 4TB WD BLUE disk used for "server" data backup. 

3) A (set of) bash scripts that 

Software RAID-5 has always been working fine for me, except when it came to error detection. One day I saw by chance that my RAID-5 array was running in `degraded mode` because apparently one of the disks was not detected anymore. No previous signal of any strange behaviour. I started preparing a spare disk, and decidded that I would have checked cables first. 

It turned out I was very lucky: a quick unplug/plug again of all HDD's cables and, BOOM, everything was back in place. The apparently missing HDD was immediately recognised and the system "resilvered" (Sorry ZFS for borrowing your teminology) straightforwardly. 

This episode was, let's say, the final straw that I needed to try and go down the ``nerd way``: ZFS! 

I have heard of ZFS since a really long time, but I always believed it was a filesystem used and useful only for immensely large data centers and so on. I was wrong. 

I started reading about ZFS online and quickly found that the system has a great 'user experience' for the average Linux user. 