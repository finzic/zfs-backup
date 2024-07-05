#!/bin/bash
#set -x
### VARIABLES. 
DEBUG=false				# set it to false for normal operation

## ERROR CODES
ERR_LESS_THAN_2_SNAPS=100
ERR_SNAPSHOT=101
ERR_SETTING_DST_READONLY=102
ERR_BAD_MD5_CHECK=103
ERR_ZFS_SEND_RECV=104
ERR_DEST_MOUNTPOINT_RETRIEVAL=105
ERR_BAD_POOL_DESCR=106
ERR_SEND_DATASET=107
ERR_DESTROY_SNAPSHOT=108
ERR_LAST_BACKUP_SNAPSHOT_DATE_NOT_AVAILABLE_LOCALLY=109


##############
# Functions  #
##############
## usage - description of usate
function usage() {
	echo "zfs-backup.sh - a tool for backing up datasets on a remote server"
	echo "========="
	echo "usage : zfs.backup.sh <pool_descriptor>"
	echo ""
	echo "Pool descriptor file is a text file whose name shall end in '.bkp'. "
	echo "It contains the following shell variables: "
	echo "SRC_POOL=<source ZFS pool name> 
SRC_DATASET=<source dataset name>
DST_POOL=<destination ZFS pool name>
DST_DATASET=<destination ZFS dataset name> 
DST_USERNAME=<destination username>
DST_ADDR=<destination address>"
}
###################################
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
###################################
## compute_size - calculates approximate size of files being transferred as difference between snapshots
## $1 shall be the path of a file containing result of zfs diff -F -H -h ${LAST_SNAP}
function compute_size() {
	# sudo zfs diff -F -H -h $1 $2  \
	cat $1 \
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
###################################

function destroy_snapshot() {
	EXIT_CODE=$1
	echo "Destroying last snapshot... "
	sudo zfs destroy ${CURRENT_LOCAL_SNAPSHOT}
	RES=$?
	if [ ${RES} -eq 0 ]; then 
		echo "... destroyed. Exiting. " 
		exit ${EXIT_CODE}
	else 
		echo "... ERROR in destroying snapshot ${CURRENT_LOCAL_SNAPSHOT} - error code : ${RES} - exiting..." 
		exit ${ERR_DESTROY_SNAPSHOT}
	fi
}
###################################

function parallel_md5sum () {
	LIST_OF_FILES=$1
	## calculating md5sum in parallel with eta display: 
	echo "Calculating md5sums parallelizing 4x..."
	# LIST_OF_FILES = /tmp/changed-files.txt or /tmp/all-files.txt
	cat ${LIST_OF_FILES} \
		| parallel -j+0 --eta md5sum {} > /tmp/md5-${DST_DATASET}.txt 
	# Need to remove '${SRC_BASE}/' from paths in md5 file because ${DST_BASE} might be different. 
	echo "Fixing paths in md5sums file..."
	sed -i "s|${SRC_BASE}/||" /tmp/md5-${DST_DATASET}.txt
	echo "Substituting ${SRC_DATASET} with ${DST_DATASET} in md5sums file..."
	sed -i "s|${SRC_DATASET}|${DST_DATASET}|" /tmp/md5-${DST_DATASET}.txt 
}
###################################

function check_md5sum_on_remote() {
	echo "Sending md5sums file to remote system..."
	THIS=$(pwd)	
	cd ${SRC_PATH}
	scp /tmp/md5-${DST_DATASET}.txt ${DST_USERNAME}@${DST_ADDR}:/tmp/
	cat << EOF > /tmp/check-md5sums.sh
#!/bin/bash
cd ${DST_BASE}
md5sum -c /tmp/md5-${DST_DATASET}.txt
RES=$?
# rm /tmp/md5-${DST_DATASET}.txt
exit ${RES}
EOF
	echo "Checking remote md5sums, please wait..."
	ssh ${DST_USERNAME}@${DST_ADDR} "bash -s" < /tmp/check-md5sums.sh
	EXIT_CODE=$?
	echo "result = $EXIT_CODE "
	if [ $EXIT_CODE -eq 0 ]
	then
		echo "remote md5sum are correct."
	else
	    echo "remote md5 check gave error code $EXIT_CODE"
		exit ${ERR_BAD_MD5_CHECK}
	fi
	cd $THIS
}
###################################

function retrieve_remote_dataset_mountpoint() {
	echo "Retrieving mountpoint for remote backup system dataset..." 
	DB=$(ssh ${DST_USERNAME}@${DST_ADDR} "zfs get -H mountpoint -o value ${DST_POOL}/${DST_DATASET}")
	RES=$?
	if [ ! ${RES} -eq 0 ]; then 
		echo "Error retrieving destination dataset mountpoint: ${RES}"
		[ ${ARE_THERE_DIFFERENCES} == true ] && destroy_snapshot ${ERR_DEST_MOUNTPOINT_RETRIEVAL}
	fi
	DST_BASE=${DB%/*}
	echo "Remote backup system dataset mountpoint is: ${DST_BASE}"
}
######################################################################################

########
# Main #
########

echo "##################################################"
echo "### backup script for ZFS pool on $(hostname) server ###"
echo "##################################################"
echo ""

# checking input
if [ ! $# -eq 1 ]; then 
	usage 
	exit 1
fi
# reading data file with variables that configure the snapshot operation
DATA_FILE=$1
source $1.bkp
if $DEBUG ; then 
	echo "==== SRC_POOL     = ${SRC_POOL}"
	echo "==== SRC_DATASET  = ${SRC_DATASET}"
	echo "==== DST_POOL     = ${DST_POOL}"
	echo "==== DST_DATASET  = ${DST_DATASET}"
	echo "==== DST_USERNAME = ${DST_USERNAME}"
	echo "==== DST_ADDR     = ${DST_ADDR}"
fi

## checking for sourced variables 

if [ x${SRC_POOL} = x ]; then 
	echo "ERROR: No SRC_POOL variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

if [ x${SRC_DATASET} = x ]; then 
	echo "ERROR: No SRC_DATASET variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

if [ x${DST_POOL} = x ]; then 
	echo "ERROR: No DST_POOL variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

if [ x${DST_DATASET} = x ]; then 
	echo "ERROR: No DST_DATASET variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

if [ x${DST_USERNAME} = x ]; then 
	echo "ERROR: No DST_USERNAME variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

if [ x${DST_ADDR} = x ]; then 
	echo "ERROR: No DST_ADDR variable defined"
	exit ${ERR_BAD_POOL_DESCR}
fi 

## COMPUTED VARIABLES
SB=$(zfs get -H mountpoint -o value ${SRC_POOL}/${SRC_DATASET})
SRC_BASE=${SB%/*}
SRC_PATH=${SRC_BASE}/${SRC_DATASET}

# display of initial data: 

echo "source base folder      = ${SRC_BASE}"
echo "source pool             = ${SRC_POOL}"
echo "source dataset          = ${SRC_DATASET}"
echo "destination address     = ${DST_ADDR}"
echo "destination username    = ${DST_USERNAME}"
echo "destination base folder = ${DST_BASE}"
echo "destination pool        = ${DST_POOL}"
echo "destination dataset     = ${DST_DATASET}"
echo "======================================================"

# set variables
ARE_THERE_DIFFERENCES=
REMOTE_ALIGNED_WITH_LOCAL=

## Get latest snapshot
LATEST_LOCAL_SNAPSHOT=$(zfs list -t snapshot ${SRC_POOL}/${SRC_DATASET} | tail -n 1 | awk '{print $1}')
echo "Latest Snapshot is ${LATEST_LOCAL_SNAPSHOT}"

[[ -f /tmp/diff0.txt ]] && rm /tmp/diff0.txt
echo "Finding differences between ${LATEST_LOCAL_SNAPSHOT} and current status of ${SRC_POOL}/${SRC_DATASET} - this could take some time..."
sudo zfs diff -F -H -h ${LATEST_LOCAL_SNAPSHOT} > /tmp/diff0.txt

if $DEBUG; then 
	cat /tmp/diff0.txt
fi

#if there are NO differences then we will set CURRENT_LOCAL_SNAPSHOT=LATEST_LOCAL_SNAPSHOT, 
# otherwise a snapshot will be created. 
# the /tmp/diff.txt file is anyway OK if there are differences. 

RES=$(cat /tmp/diff0.txt | wc -l)
if [ ${RES} -eq 0 ]; then 
	echo "There are no local differences -> the latest local snapshot will be considered as current snapshot."
	ARE_THERE_DIFFERENCES=false 
	CURRENT_LOCAL_SNAPSHOT=${LATEST_LOCAL_SNAPSHOT}
else 
	echo "There are differences -> creating a snapshot..."
	ARE_THERE_DIFFERENCES=true
	## Performing snapshot to start off.
	echo "Creating snapshot..."
	SNAP_TIMESTAMP=$(date +%Y.%m.%d-%H.%M.%S)
	CURRENT_LOCAL_SNAPSHOT=${SRC_POOL}/${SRC_DATASET}@${SNAP_TIMESTAMP}
	sudo zfs snapshot ${CURRENT_LOCAL_SNAPSHOT}
	RES=$?
	if [ ${RES} -eq 0 ]; then 
		echo "Snapshot performed correctly: ${CURRENT_LOCAL_SNAPSHOT}"
	else
		echo "Error: snapshot not performed. Return code: ${RES}"
		exit ${ERR_SNAPSHOT}
	fi
fi
echo ""
echo "Current local snapshot = ${CURRENT_LOCAL_SNAPSHOT}"
echo ""

## Checking if the dataset is already present at the backup server: 
OUTPUT=$(ssh ${DST_USERNAME}@${DST_ADDR} zfs list -t snapshot ${DST_POOL}/${DST_DATASET} 2>&1 ) 
echo ${OUTPUT} | grep 'dataset does not exist'
RES=$?
if [ ${RES} -eq 0 ]; then 
	# Dataset is NOT present on remote system -> need to transfer it with all snapshots.
	echo "The dataset ${DST_DATASET} is not present in the remote system."
	echo "Calculating MD5SUMs for all files on the local server - please wait..." 
	cd ${SRC_BASE}
	# find Test -type f | parallel -j+0 --eta md5sum {} > /tmp/md5-Test-all.tx
	# Delete /tmp/all-files.txt if it exists
	[ -f /tmp/all-files.txt ] && rm /tmp/all-files.txt 
	find ${SRC_DATASET} -type f > /tmp/all-files.txt
	parallel_md5sum /tmp/all-files.txt
	echo "... MD5SUMs done."

	echo "Preparing to send the whole dataset with all its snapshots..." 
	## Get size of dataset 
	OUTPUT=$(zfs list -t snapshot ${SRC_POOL}/${SRC_DATASET} | tail -n 1)
	## retrieve length and convert into something good for PV
	ORIG_SIZE=$(echo $OUTPUT | awk '{print $4}') 
	PV_SIZE=$(parse_size ${ORIG_SIZE})
	echo "Estimated size of ${SRC_POOL}/${SRC_DATASET} is : ${PV_SIZE}" 
	echo "Current LOCAL snapshot is ${CURRENT_LOCAL_SNAPSHOT}" 

	## send the snapshots to the backup server
	## sudo zfs send -R zfspool/Test@2024.06.27-10.43.07 | pv | ssh finzic@r4spi.local sudo zfs receive testpool/Test-2
    echo "Sending all dataset to backup system..." 
	sudo zfs send -R ${CURRENT_LOCAL_SNAPSHOT} | pv -ptebar -s ${PV_SIZE} | ssh ${DST_USERNAME}@${DST_ADDR} sudo zfs recv ${DST_POOL}/${DST_DATASET}
	RES=$?
	if [ ${RES} -eq 0 ]; then 
		echo "... Everything OK"
	else
		echo "... Error in sending dataset: ${RES}"
		if [ ${ARE_THERE_DIFFERENCES} == true ] ; then
			destroy_snapshot ${ERR_SEND_DATASET} 
		else 
			echo "No differences on local system between last snapshot and present situation, so not going to remove any snapshot." 
		fi
    fi
	# Need to find DST_BASE for the remote checksum verification
	retrieve_remote_dataset_mountpoint

	# check all md5sums on remote server
	check_md5sum_on_remote

	# IF previous check is OK, then we set the remote dataset as readonly is necessary for subsequent snapshot sending.
	echo -n "Setting remote dataset as readonly..." 
	ssh ${DST_USERNAME}@${DST_ADDR} sudo zfs set readonly=on ${DST_POOL}/${DST_DATASET}
	RES=$?
	if [ ${RES} -eq 0 ]; then
		echo "... OK"
	else
		echo "Error setting ${DST_POOL}/${DST_DATASET} as readonly"
		exit ${ERR_SETTING_DST_READONLY}   
	fi
else 
	# BIG CASE: ongoing backup, already sent once.
	echo "The dataset \"${SRC_DATASET}\" is already present in the backup system."
	## >> else normal case: 
	#
	# Retrieving mountpoint for remote backup system dataset
	retrieve_remote_dataset_mountpoint
	
	cd ${SRC_BASE}
	# Removing temp files
	[ -f /tmp/changed-files.txt ] && rm /tmp/changed-files.txt
	[ -f /tmp/deleted-files.txt ] && rm /tmp/deleted-files.txt
	[ -f /tmp/moved-files.txt ] && rm /tmp/moved-files.txt
	[ -f /tmp/md5-${DST_DATASET}.txt ] && rm /tmp/md5-${DST_DATASET}

	# check there are at least 2 snapshots: 
	N_SNAPS=$(zfs list -t snapshot ${SRC_POOL}/${SRC_DATASET} | grep ${SRC_DATASET} | tail -n 2 | wc -l)
	if [ $N_SNAPS -lt 2 ]; then 
		echo "There are less than 2 snapshots:" 
		zfs list -t snapshot ${SRC_POOL}/${SRC_DATASET} 
		exit $ERR_LESS_THAN_2_SNAPS
    fi

	# Finding last snapshot on the backup system 
	echo "=== Checking snapshot alignment between REMOTE and LOCAL systems:"
	LAST_SNAPSHOT_DATE_ON_REMOTE=$(ssh ${DST_USERNAME}@${DST_ADDR} zfs list -H -t snapshot ${DST_POOL}/${DST_DATASET} | awk '{print $1}' |  sort | sed "s/^\(.*\)\/\(.*\)@\(.*\)$/\3/" | tail -n 1 )
	echo "Last snapshot date on REMOTE system is : ${LAST_SNAPSHOT_DATE_ON_REMOTE}"
	LAST_SNAPSHOT_DATE_ON_LOCAL=$( zfs list -H -t snapshot ${SRC_POOL}/${SRC_DATASET} | awk '{print $1}' |  sort | sed "s/^\(.*\)\/\(.*\)@\(.*\)$/\3/" | tail -n 1  )
	echo "Last snapshot date on LOCAL  system is : ${LAST_SNAPSHOT_DATE_ON_LOCAL}"
	if [ ${LAST_SNAPSHOT_DATE_ON_REMOTE} == ${LAST_SNAPSHOT_DATE_ON_LOCAL} ]; then
		REMOTE_ALIGNED_WITH_LOCAL=true
	else
		REMOTE_ALIGNED_WITH_LOCAL=false
	fi

	# if there are no differences and last snapshot dates are equal, then there is nothing to do -> we exit. 
	if [ !{ARE_THERE_DIFFERENCES} ] && [ ${REMOTE_ALIGNED_WITH_LOCAL} == true ] ; then
		echo "No differences have been found; last snapshot date on backup is equal to last snapshot date on server"
		echo "-> no backup action is needed."
		exit 0
	fi

	# Check that LAST_SNAPSHOT_DATE_ON_REMOTE exists locally
	RES=$(zfs list -H -t snapshot ${SRC_POOL}/${SRC_DATASET} | awk '{print $1}' | sed "s/^\(.*\)\/\(.*\)@\(.*\)$/\3/" | grep ${LAST_SNAPSHOT_DATE_ON_REMOTE})
	# if the backup snapshot date is not present locally, we have an inconsistent situation so we bail out. 
	if [ x${RES} == x ] ||  [ ${RES} != ${LAST_SNAPSHOT_DATE_ON_REMOTE} ]; then 
		echo "Hmm - remote snapshot ${LAST_SNAPSHOT_DATE_ON_REMOTE} is not present locally... this is a problem."
		if [${ARE_THERE_DIFFERENCES} == true ]; then
			destroy_snapshot ${ERR_LAST_BACKUP_SNAPSHOT_DATE_NOT_AVAILABLE_LOCALLY}
		else
			echo "No differences -> no snapshot has been created -> no snapshot is going to be destroyed."
		fi
	else 
		echo "There is a snapshot with the same date on LOCAL system." 
	fi

	# From now on, the real 'backup' operation begins.

	# FROM_SNAPSHOT is the local snap with date equal to LAST_SNAPSHOT_DATE_ON_REMOTE
	FROM_SNAPSHOT=${SRC_POOL}/${SRC_DATASET}@${LAST_SNAPSHOT_DATE_ON_REMOTE}
	
	if $DEBUG ; then 
		echo "==== first snapshot               = ${FROM_SNAPSHOT}"
		echo "==== second snapshot              = ${CURRENT_LOCAL_SNAPSHOT}"
		echo "==== last snapshot date on server = ${LAST_SNAPSHOT_DATE_ON_LOCAL}"
	fi

	# now we transfer to the REMOTE system from FROM_SNAPSHOT to CURRENT_LOCAL_SNAPSHOT 
	## /tmp/diff.txt will contain differences from last snapshot to present situation. 
	
	echo "Finding all modifications from ${FROM_SNAPSHOT} to ${CURRENT_LOCAL_SNAPSHOT}..."
	sudo zfs diff -F -H -h ${FROM_SNAPSHOT} ${CURRENT_LOCAL_SNAPSHOT} > /tmp/diff.txt
    
	echo "Determining changed files..."
	# sudo zfs diff -F -H -h ${LAST_SNAP}  \
	cat /tmp/diff.txt \
		| grep -v /$'\t' \
		| grep -v "^-" \
		| grep -v "^R" \
		| awk 'BEGIN { FS = "\t" } ; { print $3 }' \
		| sort > /tmp/changed-files.txt
	
	echo "Determining moved files..."
	cat /tmp/diff.txt \
		| grep -v /$'\t' \
		| grep "^R" \
		| sort > /tmp/moved-files.txt
	
	echo "Determining deleted files..." 
	cat /tmp/diff.txt \
		| grep -v /$'\t' \
		| grep "^-" \
		| awk 'BEGIN { FS = "\t" } ; { print $3 }' \
		| sort > /tmp/deleted-files.txt

	CHANGES=$(wc -l < /tmp/changed-files.txt) 
	DELETES=$(wc -l < /tmp/deleted-files.txt)
	MOVED=$(wc -l < /tmp/moved-files.txt)
	if [ $CHANGES -eq 0 ] && [ $DELETES -eq 0 ] && [ $MOVED -eq 0 ] && [ ${REMOTE_ALIGNED_WITH_LOCAL} == true ]
	then
		echo "No changed or deleted files in $SRC_PATH AND backup is aligned with server - nothing to backup" 
	else
		# >> parallelize md5sum calculation and prepare a file with a list of checksums and files; 
		echo "There are $CHANGES changed files, $DELETES deleted files and $MOVED moved files." 
		if $DEBUG ; then 
			echo "==== Changed files are:"
			cat /tmp/changed-files.txt
			echo ""
			echo "==== Deleted files are:"
			cat /tmp/deleted-files.txt
			echo ""
			echo "==== Moved files are: "
			cat /tmp/moved-files.txt
			echo ""
		fi

		echo "Remote is aligned with local? ${REMOTE_ALIGNED_WITH_LOCAL}"
		
		## calculating md5sum in parallel with eta display: 
		parallel_md5sum /tmp/changed-files.txt

		if $DEBUG ; then 
			echo "==== md5sums of changed files:"
			cat /tmp/md5-${DST_DATASET}.txt
		fi	

		if $DEBUG ; then 
			echo "==== list of ZFS snapshots available: " 
			zfs list -t snapshot ${SRC_POOL}/${SRC_DATASET}
		fi

		# Calculating size of the increment between first snapshot and second snapshot
		echo "Calculating data transfer size approximation..."
		SIZE=$( compute_size /tmp/diff.txt )
		if $DEBUG ; then
			echo "==== Computed size is $SIZE" 
		fi
		PV_SIZE=$( parse_size ${SIZE} )
		echo "Approximate transfer size is ${PV_SIZE}"
			  
		# Sending out the snapshot increment 
		echo "Sending snapshot..."
		if $DEBUG; then 
			echo "==== zfs send -I ${FROM_SNAPSHOT} ${CURRENT_LOCAL_SNAPSHOT} | pv -ptebar -s ${PV_SIZE} | ssh ${DST_USERNAME}@${DST_ADDR} sudo zfs recv ${DST_POOL}/${DST_DATASET}"
		fi
		sudo zfs send -I ${FROM_SNAPSHOT} ${CURRENT_LOCAL_SNAPSHOT} \
			| pv -ptebar -s ${PV_SIZE} \
			| ssh ${DST_USERNAME}@${DST_ADDR} sudo zfs recv ${DST_POOL}/${DST_DATASET}
		RES=$?
		if [ ! ${RES} -eq 0 ]; then
			echo "Error in zfs send | zfs recv: ${RES} - destroying snapshot... "
			if [ ${ARE_THERE_DIFFERENCES} == true ]; then 
			destroy_snapshot ${ERR_ZFS_SEND_RECV}
			fi
		fi
		if $DEBUG ; then 
			echo "Result of zfs send | zfs recv is: ${RES}"
		fi
		check_md5sum_on_remote
	fi
fi
echo "Backup operations completed successfully."
