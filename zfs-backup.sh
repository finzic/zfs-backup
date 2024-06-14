#!/bin/bash
#set -x
### VARIABLES. 
DEST_ADDR=r4spi.local
SOURCE_BASE=/mnt/raid
SOURCE_ZFS_POOL=zfspool
SOURCE_DATASET=Foto
DEST_DATASET=Foto
DEST_ZFS_POOL=backuppool
REMOTE_USERNAME=finzic

SOURCE_PATH=$SOURCE_BASE/$SOURCE_DATASET
DEST_BASE=/mnt/storage
SNAPSHOT_SOURCE=/mnt/storage/$DEST_DATASET-sv
SNAPSHOT_DEST=/mnt/storage/$DEST_DATASET-snapshots-sv

# Always create a snapshot
echo "##################################################"
echo "### backup script for ZFS pool on MORLA server ###"
echo "##################################################"
echo ""
echo "source base folder      = ${SOURCE_BASE}"
echo "source dataset          = ${SOURCE_DATASET}"
echo "destination address     = ${DEST_ADDR}"
echo "destination base folder = ${DEST_BASE}"
# calculating diff md5sums
echo "Finding modified files and calculating checksums..."
if [ -f /tmp/md5-$DEST_DATASET.txt ]; then 
	echo "Removing old md5-$DEST_DATASET.txt file... "
	rm /tmp/md5-$DEST_DATASET.txt
else 
	echo "No previous md5-$DEST_DATASET.txt file to remove, let's proceed."
fi

cd ${SOURCE_BASE}
# correct if changes are present: 
# rsync -nia --out-format="%i \"%f\"" $SOURCE_DATASET bu@$DEST_ADDR:/home/bu/$DEST_DATASET | egrep '<' | cut -d' ' -f2- | xargs md5sum > /tmp/md5-$DEST_DATASET.txt
#
# find differences and write them in a file: 
# rsync -nia --out-format="%i \"%f\"" $SOURCE_DATASET bu@$DEST_ADDR:/home/bu/$DEST_DATASET | egrep '<' | cut -d' ' -f2- > /tmp/changed-files.txt
# NOTE: the trailing '/' after ${SOURCE_DATASET} is FUNDAMENTAL to compare the right folders. 
echo "rsync -nia --out-format="%i \"%f\"" ${SOURCE_DATASET}/ ${REMOTE_USERNAME}@${DEST_ADDR}:${DEST_BASE}/${DEST_DATASET} " 
rsync -nia --out-format="%i \"%f\"" ${SOURCE_DATASET}/ ${REMOTE_USERNAME}@${DEST_ADDR}:${DEST_BASE}/${DEST_DATASET} | egrep '<' | cut -d' ' -f2- > /tmp/changed-files.txt

#| egrep '<' \
#| cut -d' ' -f2- > /tmp/changed-files.txt

# if changed-files.txt has no lines there are no changed files, so do not do anything - the backup operation stops. 
CHANGES=$(wc -l < /tmp/changed-files.txt) 
if [ $CHANGES -eq 0 ] 
then
	echo "No changed files in $SOURCE_PATH - nothing to backup - operation completed." 
else
	echo "There are $CHANGES changed files - calculating md5sums parallelizing 4x..."
	## sperimentare questo https://www.youtube.com/watch?v=OpaiGYxkSuQ&list=PL284C9FF2488BC6D1&index=1
	
	## cat /tmp/changed-files.txt | time parallel -j+0 --eta '<comando da parallelizzare> {}' ### {} = singola riga di input.

	cat /tmp/changed-files.txt | xargs -L1 -P4 md5sum > /tmp/md5-$DEST_DATASET.txt
	echo "md5sums of modified files: "
	cat /tmp/md5-$DEST_DATASET.txt 
	
	# Create snapshot in server's ZFS dataset
	echo "Creating ZFS snapshot..."
	# zfs snapshot zfspool/Documents@$(date +%Y.%m.%d-%H.%M.%S)
	SNAP_TIMESTAMP=$(date +%Y.%m.%d-%H.%M.%S)
	echo ">>> sudo zfs snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET}@${SNAP_TIMESTAMP}"

	exit 1
	 
	
	# rsync -avzpH --partial --delete -P --progress $SOURCE_PATH bu@$DEST_ADDR:/home/bu/$DEST_DATASET
	THIS=$(pwd)
	cd $SOURCE_PATH
	echo "Sending md5sums of modified files to $DEST_ADDR ..."
	scp /tmp/md5-$DEST_DATASET.txt bu@$DEST_ADDR:/tmp/

	cat << EOF > /tmp/check-md5sums.sh
#!/bin/bash
cd $DEST_DATASET
md5sum -c /tmp/md5-$DEST_DATASET.txt
EOF

	ssh bu@$DEST_ADDR
 "bash -s" < /tmp/check-md5sums.sh
	EXIT_CODE=$?
	echo "result = $EXIT_CODE "

	if [ $EXIT_CODE -eq 0 ]
	then
		echo "remote md5sum is correct."
		if [ $SNAPSHOT == 'true' ]
		then
	        	echo "Creating snapshot on destination"
		        ssh -t finzic@$DEST_ADDR
			 "sudo btrfs subvolume snapshot $SNAPSHOT_SOURCE $SNAPSHOT_DEST/$DEST_DATASET\_$(date +%Y.%m.%d-%H.%M.%S)"
		else
			echo "No snapshot will be created."
		fi	
	else
	        echo "remote md5 check gave error code $EXIT_CODE"
	fi
	cd $THIS
	echo "Backup operation finished successfully."
fi
