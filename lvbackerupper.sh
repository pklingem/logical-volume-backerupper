#!/bin/bash

# Logical Volume Backerupper
# This script backs up logical volumes to an NFS share or a Windows (cifs) share
# To run the script type: /root/backup.sh lv1 lv2 lv3
# where lv1 lv2 and lv3 are logical volume devices located in /dev/${VG_PATH}
# ex: /dev/VolGroup01/LogVol00, or /dev/VolGroup01/NFSHome
# You may backup up any number of logical volumes in succession by listing them as
# arguments to the script.
#
# Requirements:
# 1. 1GB of free space in the Volume Group in which the Logical Volume to be backed
#    up resides.
# 2. A valid NFS/CIFS share to be mounted with free space equaling the the size of
#    the used space in the Logical Volume to be backed up.

#print executed commands and their arguments
set -x
#cause script to exit if any unset variable is referenced
set -u
#cause script to exit if any command returns a non-true value
set -e

#NAS hostname/ip address
NAS_HOST=host
NAS_TYPE=cifs
NAS_USER=username
NAS_PASSWORD=password
NAS_SHARE_PATH=//${NAS_HOST}/backup/

#Volume Group Name
VG_NAME=VolGroup01
#the path to the volume group which contains the logical volume to be backed up
VG_PATH=/dev/${VG_NAME}

#root autofs path of the backup host
NFS_HOST_PATH=/net/${NAS_HOST}
#the path to the root backup directory
BACKUP_PATH=${NFS_HOST_PATH}/path/to/root/backup/dir

#the prefix path where logical volume snapshots will be mounted
TEMP_MOUNT_PATH=/mnt/temporary_backup_mounts

DAY=`date +%A`
YESTERDAY=`date --date='1 day ago' +%A`
DATE=`date +%Y-%m-%d.%H%M%S`

function prepare_snapshot() {
	LV_NAME=$1

	if [ "$NAS_TYPE" == "cifs" ]; then
		BACKUP_PATH=${TEMP_MOUNT_PATH}/${NAS_HOST}
		mkdir -p "${BACKUP_PATH}"
		mount -t cifs "${NAS_SHARE_PATH}" "${BACKUP_PATH}" -o user=${NAS_USER},password=${NAS_PASSWORD}
	else
		#wake up autofs
		ls "${NFS_HOST_PATH}"
	fi

	#take a snapshot of of the volume
	/sbin/lvcreate -L1G -s -n ${LV_NAME}_snapshot "${VG_PATH}/${LV_NAME}"
	mkdir -p "${TEMP_MOUNT_PATH}/${LV_NAME}"

	#mount the snapshot, read-only
	mount -o ro "${VG_PATH}/${LV_NAME}_snapshot" "${TEMP_MOUNT_PATH}/${LV_NAME}"

	if [ ! -e "${BACKUP_PATH}/${LV_NAME}" ]; then
		mkdir "${BACKUP_PATH}/${LV_NAME}"
	fi

	return 0
}

function backup_snapshot() {
	LV_NAME=$1

	#if today is Sunday or if a full backup does not yet exist, do a full backup
	#otherwise do an incremental backup
	if [ "${DAY}" == "Sunday" ] || [ "`ls ${BACKUP_PATH}/${LV_NAME}/ | wc -l`" == "0" ]; then
		mkdir "${BACKUP_PATH}/${LV_NAME}/old"
		if [ "`ls \"${BACKUP_PATH}/${LV_NAME}/\" | egrep -c \".*[.]tar$\"`" -gt "0" ]; then
			mv "${BACKUP_PATH}/${LV_NAME}/"*.tar "${BACKUP_PATH}/${LV_NAME}/old"
		fi
		if [ "`ls \"${BACKUP_PATH}/${LV_NAME}/\" | egrep -c \".*[.]snar$\"`" -gt "0" ]; then
			mv "${BACKUP_PATH}/${LV_NAME}/"*.snar "${BACKUP_PATH}/${LV_NAME}/old"
		fi

		#change directory to path of the snapshot, within the context of the tar
		#command, this effectively removes the absolute path from the archive
		(cd "${TEMP_MOUNT_PATH}/${LV_NAME}";\
		tar --create \
		    --xattrs \
		    --preserve-permissions \
		    --file="${BACKUP_PATH}/${LV_NAME}/incremental_${DATE}.tar" \
		    --listed-incremental="${BACKUP_PATH}/${LV_NAME}/incremental.snar" *)

		#cleanup
		rm -rf "${BACKUP_PATH}/${LV_NAME}/old"
	else
		#change directory to path of the snapshot, within the context of the tar
		#command, this effectively removes the absolute path from the archive
		(cd "${TEMP_MOUNT_PATH}/${LV_NAME}";\
		tar --create \
		    --xattrs \
		    --preserve-permissions \
		    --file="${BACKUP_PATH}/${LV_NAME}/incremental_${DATE}.tar" \
		    --listed-incremental="${BACKUP_PATH}/${LV_NAME}/incremental.snar" *)

		echo "Performing incremental backup of ${LV_NAME} volume"
	fi


	return 0
}

function remove_snapshot() {
	LV_NAME=$1

	#cleanup
	umount "${TEMP_MOUNT_PATH}/${LV_NAME}"
	rmdir "${TEMP_MOUNT_PATH}/${LV_NAME}"
	if [ "$NAS_TYPE" == "cifs" ]; then
		umount ${BACKUP_PATH}
	fi
	rmdir "${BACKUP_PATH}"
	rmdir "${TEMP_MOUNT_PATH}"
	/sbin/lvremove -f "${VG_PATH}/${LV_NAME}_snapshot"

	return 0
}

function backup_volume() {	
	prepare_snapshot "$1"
	backup_snapshot "$1"
	remove_snapshot "$1"

	return 0
}

function recover() {
	set +e

	LV_NAME=$1
	echo "An error occurred during the backup process, restoring the system to it's original state."

	#check to see if the logical volume is mounted, if so, unmount it
	mount | grep "on \"${TEMP_MOUNT_PATH}/${LV_NAME}\" type" > /dev/null
	if [ $? -eq 1 ]; then
		umount "${TEMP_MOUNT_PATH}/${LV_NAME}"
	fi

	#check to see if the mount point was created, if so, remove it.
	if [ -e "${TEMP_MOUNT_PATH}/${LV_NAME}" ]; then
		rmdir "${TEMP_MOUNT_PATH}/${LV_NAME}"
	fi

	#check to see if the cifs filesystem is still mounted and if so, unmount it
	#then remove the temporary backup paths
	if [ "${NAS_TYPE}" == "cifs" ]; then
		if [ "`mount | grep ${BACKUP_PATH} | wc -l`" -eq 1 ]; then
			umount "${BACKUP_PATH}"
		fi
		rmdir "${BACKUP_PATH}"
		rmdir "${TEMP_MOUNT_PATH}"
	fi
	
	#check to see if the logical volume snapshot was created, if so, remove it
	if [ "`/sbin/lvs | grep \"${LV_NAME}_snapshot\" | wc -l`" -eq 1 ]; then
		/sbin/lvremove -f "${VG_PATH}/${LV_NAME}_snapshot"
	fi

	exit
}

mkdir -p /var/log/backup

for i in "$@";
do (
	trap 'recover "${i}"' INT TERM EXIT 
	backup_volume "${i}"
	trap - INT TERM EXIT
   ) &> /var/log/backup/${i}_volume_backup_`date +%Y-%m-%d`.log
done
