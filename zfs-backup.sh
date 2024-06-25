#!/bin/bash
#set -x
### VARIABLES. 
DEBUG=true				# set it to false for normal operation

SOURCE_BASE=/mnt/raid
SOURCE_ZFS_POOL=zfspool
SOURCE_DATASET=Test

DEST_BASE=/mnt/test
#DEST_BASE=/mnt/storage
#DEST_ZFS_POOL=testpool
DEST_ZFS_POOL=testpool
DEST_DATASET=Test
DEST_ADDR=r4spi.local
DEST_USERNAME=finzic

## COMPUTED VARIABLES
SOURCE_PATH=${SOURCE_BASE}/${SOURCE_DATASET}

## ERROR CODES
ERR_LESS_THAN_2_SNAPS=100
ERR_FIRST_SNAPSHOT=101
ERR_SETTING_DEST_READONLY=102
ERR_BAD_MD5_CHECK=103
ERR_ZFS_SEND_RECV=104

##############
# Functions  #
##############

## parse_size - provide a simple modification of the size passed so that it will be integer multiple of K,M,G,T for pv to correctly set max size and progress bar. 
function parse_size() {
    size=$1
    suffix="${size: -1}"
    num="${size%$suffix}"
    integer_part="${num%%.*}"

    if [ x${integer_part} = x${num} ];
    then
        echo "${size}"
    else
        value="$(echo "${num}*1024" | bc)"
        case "$suffix" in
                "K")
                    echo "${value%%.*}"
                    ;;
                "M")
                    echo "${value%%.*}K"
                    ;;
                "G")
                    echo "${value%%.*}M"
                    ;;
                "T")
                    echo "${value%%.*}G"
                    ;;
                *)
                    echo "Invalid size. Please enter a size in K, M, or G."
                    ;;
        esac
    fi
}

## compute_size - calculates approximate size of files being transferred as difference between snapshots
function compute_size() {
	sudo zfs diff -F -H -h $1 $2  \
	| grep -v /$'\t' \
	| grep -v "^-" \
	| grep -v "^R" \
	| awk 'BEGIN { FS = "\t" } ; { print $3 }'  \
	| sort \
    | tr '\n' '\0' \
	| du -ch --files0-from=- \
	| tail -1 \
	| awk '{print $1}'

}
######################################################################################3

########
# Main #
########

## First thing is to check if this is the first backup and first snapshot or not. 


echo "##################################################"
echo "### backup script for ZFS pool on MORLA server ###"
echo "##################################################"
echo ""
echo "source base folder      = ${SOURCE_BASE}"
echo "source dataset          = ${SOURCE_DATASET}"
echo "destination address     = ${DEST_ADDR}"
echo "destination base folder = ${DEST_BASE}"
# calculating diff md5sums

## TODO the corner case is the initial case: 
## first snapshot ever: need to check if the dataset is available at the destination, and if there are no snapshots present at the source.
## In this case, 
## 1) perform the first snapshot;  
## 2) transfer the dataset with the first type of command 
## sudo zfs send zfspool/Test@2024.06.03-09.56.26 | pv -ptebar -s <size> | ssh finzic@r4spi.local  sudo zfs recv backup

## Checking if the dataset is already present at the backup server: 
OUTPUT=$(ssh ${DEST_USERNAME}@${DEST_ADDR} zfs list -t snapshot ${DEST_ZFS_POOL}/${DEST_DATASET} 2>&1 ) 
echo ${OUTPUT} | grep 'dataset does not exist'
RES=$?

if [ ${RES} -eq 0 ]; then 
	echo "The dataset ${SOURCE_DATASET} is not present in the backup system -> performing first snapshot and transfer."
	## Perform first snapshot
	SNAP_TIMESTAMP=$(date +%Y.%m.%d-%H.%M.%S)
	sudo zfs snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET}@${SNAP_TIMESTAMP}
	## retrieve its tag 
	OUTPUT=$(zfs list -t snapshot zfspool/Test | tail -n 1)
	SNAPSHOT=$(echo $OUTPUT | awk '{print $1}')
	echo "Snapshot is ${SNAPSHOT}" 
	## retrieve length and convert into something good for PV
	ORIG_SIZE=$(echo $OUTPUT | awk '{print $4}') 
	PV_SIZE=$(parse_size ${ORIG_SIZE})
	
	if  ${DEBUG} ; then 
		echo "ORIG_SIZE = ${ORIG_SIZE}; PV_SIZE = ${PV_SIZE}" 
	fi
	## send the snapshot to the backup server
	##sudo zfs send zfspool/Test@2024.06.03-09.56.26 | pv -ptebar -s 5500M | ssh finzic@r4spi.local  sudo zfs recv backuppool/Test
    echo "Sending first snapshot to backup system..." 
	sudo zfs send ${SNAPSHOT} | pv -ptebar -s ${PV_SIZE} | ssh ${DEST_USERNAME}@${DEST_ADDR} sudo zfs recv ${DEST_ZFS_POOL}/${DEST_DATASET}
	RES=$?
	if [ ${RES} -eq 0 ]; then 
		echo "... Everything OK"
	else
		echo "... Error in sending first snapshot: ${RES}"
		exit ${ERR_FIRST_SNAPSHOT}
    fi

	# Setting the dataset as readonly is necessary for subsequent snapshot sending.
	echo -n "Setting dataset as readonly..." 
	ssh ${DEST_USERNAME}@${DEST_ADDR} sudo zfs set readonly=on ${DEST_ZFS_POOL}/${DEST_DATASET}
	RES=$?
	if [ ${RES} -eq 0 ]; then
		echo "... OK"
	else
		echo "Error setting ${DEST_ZFS_POOL}/${DEST_DATASET} as readonly"
		exit ${ERR_SETTING_DEST_READONLY}   
	fi
else 
	echo "The dataset \"${SOURCE_DATASET}\" is already present in the backup system -> a new snapshot will be created and incrementally transmitted."
	## >> else normal case: 
	#
	## >> compute the size as an integer with unity of measure (K,M,G,T) for pv to display eta correctly; 
	## >> launch zfs snapshot send and receive at the backup machine; 
	## >> check all transferred files' checksum with the ones previously calculated.  

	cd ${SOURCE_BASE}
	# Removing temp files
	if [ -f /tmp/changed-files.txt ]; then
		echo "Removing old changed files file..."
		rm /tmp/changed-files.txt
	else
		echo "No previous 'changed-files.txt' file to remove, let's proceed."
	fi

	if [ -f /tmp/deleted-files.txt ]; then
		echo "Removing old deleted files file..."
		rm /tmp/deleted-files.txt
	else
		echo "No previous 'changed-files.txt' file to remove, let's proceed."
	fi


	if [ -f /tmp/md5-$DEST_DATASET.txt ]; then 
		echo "Removing old md5-$DEST_DATASET.txt file... "
		rm /tmp/md5-$DEST_DATASET.txt
	else 
		echo "No previous md5-$DEST_DATASET.txt file to remove, let's proceed."
	fi

	# 
	#TODO - weak - need to compute the differences with last snapshot to actually know if any file has been changed. 
    # 
	### OLD METHOD - using RSYNC. 
	## >> rsync prepares the list of differences between server and backup machine;  
	# rsync -nia --out-format="%i \"%f\"" $SOURCE_DATASET bu@$DEST_ADDR:/home/bu/$DEST_DATASET | egrep '<' | cut -d' ' -f2- > /tmp/changed-files.txt
	# NOTE: the trailing '/' after ${SOURCE_DATASET} is FUNDAMENTAL to compare the right folders.
	# if ${DEBUG}; then
	#	echo "==== rsync -nia --out-format="%i \"%f\"" ${SOURCE_DATASET}/ ${DEST_USERNAME}@${DEST_ADDR}:${DEST_BASE}/${DEST_DATASET} ..." 
	# fi 
	############################################################################################################################################################################### 
	### rsync -nia --out-format="%i \"%f\"" ${SOURCE_DATASET}/ ${DEST_USERNAME}@${DEST_ADDR}:${DEST_BASE}/${DEST_DATASET} | egrep '<' | cut -d' ' -f2- > /tmp/changed-files.txt ###
    ############################################################################################################################################################################### 
	### NEW METHOD - get differences from zfs diff on the server
	LAST_SNAP=$(zfs list -t snapshot  ${SOURCE_ZFS_POOL}/${SOURCE_DATASET} | tail -n 1 | awk '{print $1}' )
	if $DEBUG; then
		echo "==== LAST SNAP = ${LAST_SNAP} "
	fi

	## changed files are added or modified; 
	## moved files are renamed or moved to a different path; 
	## deleted are... well, deleted. 
	## BUG there is a problem with the awk expression with files that have multiple spaces in their name. 

	echo "Determining changed files..."
	sudo zfs diff -F -H -h ${LAST_SNAP}  \
		| grep -v /$'\t' \
		| grep -v "^-" \
		| grep -v "^R" \
		| awk 'BEGIN { FS = "\t" } ; { print $3 }' \
		| sort > /tmp/changed-files.txt
	
	echo "Determining moved files..."
	sudo zfs diff -F -H -h ${LAST_SNAP} \
		| grep -v /$'\t' \
		| grep "^R" \
		| sort > /tmp/moved-files.txt
	
	echo "Determining deleted files..." 
	sudo zfs diff -F -H -h ${LAST_SNAP}  \
		| grep -v /$'\t' \
		| grep "^-" \
		| awk 'BEGIN { FS = "\t" } ; { print $3 }' \
		| sort > /tmp/deleted-files.txt

	CHANGES=$(wc -l < /tmp/changed-files.txt) 
	DELETES=$(wc -l < /tmp/deleted-files.txt)
	MOVED=$(wc -l < /tmp/moved-files.txt)
	if [ $CHANGES -eq 0 ] && [ $DELETES -eq 0 ] && [ $MOVED -eq 0 ]
	then
		echo "No changed or deleted files in $SOURCE_PATH - nothing to backup - operation completed." 
	else
		# >> parallelize md5sum calculation and prepare a file with a list of checksums and files; 
		echo "There are $CHANGES changed files and $DELETES deleted files." 
		if $DEBUG ; then 
			echo "==== Deleted files are:"
			cat /tmp/deleted-files.txt
			echo ""
			echo "==== Moved files are: "
			cat /tmp/moved-files.txt
		fi
		
		## calculating md5sum in parallel with eta display: 
		echo "Calculating md5sums parallelizing 4x..."
		cat /tmp/changed-files.txt \
			| parallel -j+0 --eta md5sum {} > /tmp/md5-${DEST_DATASET}.txt 
		echo "Fixing paths in md5sums file..."
		sed -i "s|${SOURCE_BASE}/||" /tmp/md5-${DEST_DATASET}.txt

		if $DEBUG ; then 
			echo "==== md5sums of modified files: "
			cat /tmp/md5-$DEST_DATASET.txt
		fi	

		# Create snapshot in server's ZFS dataset
		echo "Creating ZFS snapshot..."
		# zfs snapshot zfspool/Documents@$(date +%Y.%m.%d-%H.%M.%S)
		SNAP_TIMESTAMP=$(date +%Y.%m.%d-%H.%M.%S)
		if $DEBUG ; then
			echo "==== sudo zfs snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET}@${SNAP_TIMESTAMP}"
		fi 
		sudo zfs snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET}@${SNAP_TIMESTAMP}

		if $DEBUG ; then 
			echo "==== list of ZFS snapshots available: " 
			zfs list -t snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET}
		fi

		# check there are at least 2 snapshots: 
		N_SNAPS=$(zfs list -t snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET} | grep ${SOURCE_DATASET} | tail -n 2 | wc -l)
		if [ $N_SNAPS -lt 2 ]; then 
			echo "There are less than 2 snapshots:" 
			zfs list -t snapshot ${SOURCE_ZFS_POOL}/${SOURCE_DATASET} 
			exit $ERR_LESS_THAN_2_SNAPS
        fi

		FIRST_SNAP=$(zfs list -t snapshot  ${SOURCE_ZFS_POOL}/${SOURCE_DATASET} | tail -n 2 | head -n 1 | awk '{print $1}' )
		SECOND_SNAP=$(zfs list -t snapshot  ${SOURCE_ZFS_POOL}/${SOURCE_DATASET} | tail -n 1 | awk '{print $1}' )

		if $DEBUG ; then 
			echo "==== first snapshot = $FIRST_SNAP"
			echo "==== second snapshot = $SECOND_SNAP"
		fi
		# Calculating size of the increment between first snapshot and second snapshot
		echo "Calculating data transfer size approximation..."
		SIZE=$( compute_size ${FIRST_SNAP} ${SECOND_SNAP} )
		if $DEBUG ; then
			echo "==== Computed size is $SIZE" 
		fi
		PV_SIZE=$( parse_size ${SIZE} )
		if $DEBUG ; then 
			echo "==== Parsed size for PV is $PV_SIZE"
		fi
		  
		# Sending out the snapshot increment 
		echo "Sending snapshot"
		if $DEBUG; then 
			echo "==== zfs send -i ${FIRST_SNAP} ${SECOND_SNAP} | pv -ptebar -s ${PV_SIZE} | ssh ${DEST_USERNAME}@${DEST_ADDR} sudo zfs recv ${DEST_ZFS_POOL}/${DEST_DATASET}"
		fi
		
		sudo zfs send -i ${FIRST_SNAP} ${SECOND_SNAP} \
			| pv -ptebar -s ${PV_SIZE} \
			| ssh ${DEST_USERNAME}@${DEST_ADDR} sudo zfs recv ${DEST_ZFS_POOL}/${DEST_DATASET}
		
		RES=$?
		if [ ! ${RES} -eq 0 ]; then
			echo "Error in zfs send | zfs recv: ${RES}"
			exit ${ERR_ZFS_SEND_RECV}
		fi
		if $DEBUG ; then 
			echo "Result of zfs send | zfs recv is: ${RES}"
		fi

		THIS=$(pwd)
		cd ${SOURCE_PATH}
		echo "Sending md5sums of modified files to ${DEST_ADDR} ..."
		scp /tmp/md5-${DEST_DATASET}.txt ${DEST_USERNAME}@${DEST_ADDR}:/tmp/

		cat << EOF > /tmp/check-md5sums.sh
#!/bin/bash
cd ${DEST_BASE}
md5sum -c /tmp/md5-${DEST_DATASET}.txt
EOF

		ssh ${DEST_USERNAME}@${DEST_ADDR} "bash -s" < /tmp/check-md5sums.sh
		EXIT_CODE=$?
		echo "result = $EXIT_CODE "

		if [ $EXIT_CODE -eq 0 ]
		then
			echo "remote md5sum is correct."
		else
		    echo "remote md5 check gave error code $EXIT_CODE"
			exit ${ERR_BAD_MD5_CHECK}
		fi
		cd $THIS
		echo "Backup operation finished successfully."
	fi

fi


