#!/bin/bash
function usage(){
    echo "Usage: $(basename $0) [-s | -b ] <Backup_Descriptor> "
    echo "where: "
    echo "          -s : create a snapshot now, if needed, on the local ZFS filesystem described in <Backup_Descriptor>."
    echo "          -b : launch a backup operation as specified in <Backup_Descriptor>" 
    echo "          -h : print this message" 
    echo "          <Backup_Descriptor> is mandatory."
}

function die () {
    echo "ERROR: $*. Aborting." >&2
    exit 1
}

echo "### getopts test ###" 
echo "Dollar zero is $0" 
SNAP_OPT="s"
BACK_OPT="b" 
DO_SNAP=false
DO_BACK=false
while getopts "s:b:h" opt; do
  case $opt in
      s ) ${DO_BACK} && die "Cannot specify option '-s' after specifying option '-b'"
          DO_SNAP=true
          BACKUP_DESCRIPTOR=$OPTARG
          echo "B_D=${BACKUP_DESCRIPTOR}" 
          echo "SNAP_OPT=${SNAP_OPT}"
          if [[ ${BACKUP_DESCRIPTOR} == "-${BACK_OPT}" ]]  || [[ ${BACKUP_DESCRIPTOR} == "${BACK_OPT}" ]]; then die "cannot specify the two options together"; fi
          ;;
      b ) ${DO_SNAP} && die "Cannot specify option '-b' after specifying option '-s'"
          DO_BACK=true
          BACKUP_DESCRIPTOR=$OPTARG
          if [[ ${BACKUP_DESCRIPTOR} == "-${SNAP_OPT}" ]] || [[ ${BACKUP_DESCRIPTOR} == "${SNAP_OPT}" ]] ; then die "cannot specify the two options together"; fi
          ;;
      h ) usage
          exit 1
          ;;
      \?) usage
          die "Invalid option: -$OPTARG. Abort"
          ;;
  esac
done
shift $(($OPTIND - 1))
echo "DO_SNAP=${DO_SNAP}"
echo "DO_BACKUP=${DO_BACK}"
echo "BACKUP_DESCRIPTOR=${BACKUP_DESCRIPTOR}"
REST=$1
echo "REST = ${REST}" 


