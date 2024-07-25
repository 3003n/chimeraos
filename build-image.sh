#! /bin/bash

set -e
set -x

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be run as root"
	exit 1
fi

BUILD_USER=${BUILD_USER:-}
OUTPUT_DIR=${OUTPUT_DIR:-}


source manifest

if [ -z "${SYSTEM_NAME}" ]; then
  echo "SYSTEM_NAME must be specified"
  exit
fi

if [ -z "${VERSION}" ]; then
  echo "VERSION must be specified"
  exit
fi

DISPLAY_VERSION=${VERSION}
LSB_VERSION=${VERSION}
VERSION_NUMBER=${VERSION}

if [ -n "$1" ]; then
	DISPLAY_VERSION="${VERSION} (${1})"
	VERSION="${VERSION}_${1}"
	LSB_VERSION="${LSB_VERSION}　(${1})"
	BUILD_ID="${1}"
fi

BUILD_DATE=$(date +%Y%m%d)

export BUILD_ID=${BUILD_DATE}_${BUILD_ID}
export FULL_VERSION=${VERSION}
export DISPLAY_VERSION=${DISPLAY_VERSION}
export LSB_VERSION=${LSB_VERSION}
export VERSION_NUMBER=${VERSION_NUMBER}

MOUNT_PATH=/tmp/${SYSTEM_NAME}-build
BUILD_PATH=${MOUNT_PATH}/subvolume
SNAP_PATH=${MOUNT_PATH}/${SYSTEM_NAME}-${VERSION}
BUILD_IMG=/output/${SYSTEM_NAME}-build.img

mkdir -p ${MOUNT_PATH}

fallocate -l ${SIZE} ${BUILD_IMG}
mkfs.btrfs -f ${BUILD_IMG}
mount -t btrfs -o loop,nodatacow ${BUILD_IMG} ${MOUNT_PATH}
btrfs subvolume create ${BUILD_PATH}

# copy the makepkg.conf into chroot
cp /etc/makepkg.conf rootfs/etc/makepkg.conf

# bootstrap using our configuration
pacstrap -K -C rootfs/etc/pacman.conf ${BUILD_PATH}

# copy the builder mirror list into chroot
mkdir -p rootfs/etc/pacman.d
cp /etc/pacman.d/mirrorlist rootfs/etc/pacman.d/mirrorlist

# copy files into chroot
cp -R manifest postinstall all-install.sh rootfs/. ${BUILD_PATH}/

mkdir ${BUILD_PATH}/own_pkgs
mkdir ${BUILD_PATH}/extra_pkgs

cp -rv aur-pkgs/*.pkg.tar* ${BUILD_PATH}/extra_pkgs
cp -rv pkgs/*.pkg.tar* ${BUILD_PATH}/own_pkgs

if [ -n "${PACKAGE_OVERRIDES}" ]; then
	wget --directory-prefix=/tmp/extra_pkgs ${PACKAGE_OVERRIDES}
	cp -rv /tmp/extra_pkgs/*.pkg.tar* ${BUILD_PATH}/own_pkgs
fi


# chroot into target
mount --bind ${BUILD_PATH} ${BUILD_PATH}
arch-chroot ${BUILD_PATH} /bin/bash -c "cd / && /all-install.sh"
rm ${BUILD_PATH}/all-install.sh
rm ${BUILD_PATH}/postinstall

# copy files into chroot again
cp -R rootfs/. ${BUILD_PATH}/
rm -rf ${BUILD_PATH}/extra_certs

echo "${SYSTEM_NAME}-${VERSION}" > ${BUILD_PATH}/build_info
echo "" >> ${BUILD_PATH}/build_info
cat ${BUILD_PATH}/manifest >> ${BUILD_PATH}/build_info
rm ${BUILD_PATH}/manifest

# freeze archive date of build to avoid package drift on unlock
# if no archive date is set
if [ -z "${ARCHIVE_DATE}" ]; then
	export TODAY_DATE=$(date +%Y/%m/%d)
	echo "Server=https://archive.archlinux.org/repos/${TODAY_DATE}/\$repo/os/\$arch" > \
	${BUILD_PATH}/etc/pacman.d/mirrorlist
fi

# show free space before snapshot
echo "Free space"
df -h

COMRESS_ON_THE_FLY=false

btrfs subvolume snapshot -r ${BUILD_PATH} ${SNAP_PATH}

IMG_FILENAME_WITHOUT_EXT="${SYSTEM_NAME}-${VERSION}"
if [ -z "${NO_COMPRESS}" ]; then
	if [[ $COMRESS_ON_THE_FLY == true ]];then
		IMG_FILENAME="${IMG_FILENAME_WITHOUT_EXT}.img.xz"
		btrfs send ${SNAP_PATH} | xz -9 -T0 > ${IMG_FILENAME}
	else
		IMG_FILENAME="${IMG_FILENAME_WITHOUT_EXT}.img.tar.xz"
		btrfs send -f ${IMG_FILENAME_WITHOUT_EXT}.img ${SNAP_PATH}
		tar -c -I"xz -9 -T0" -f ${IMG_FILENAME} ${IMG_FILENAME_WITHOUT_EXT}.img
		rm ${IMG_FILENAME_WITHOUT_EXT}.img
	fi
else
	btrfs send -f ${IMG_FILENAME_WITHOUT_EXT}.img ${SNAP_PATH}
fi

# 如果文件大于 1.5GiB，那么就分割文件
# split_size=$((1.5 * 1024 * 1024 * 1024))
split_size=1610612736
if [ $(stat -c %s ${IMG_FILENAME}) -gt $split_size ]; then
	split -b 1536MiB -d -a 3 ${IMG_FILENAME} ${IMG_FILENAME}-
	rm ${IMG_FILENAME}
fi

cp ${BUILD_PATH}/build_info build_info.txt

# clean up
umount -l ${BUILD_PATH}
umount -l ${MOUNT_PATH}
rm -rf ${MOUNT_PATH}
rm -rf ${BUILD_IMG}

if [ -z "${NO_COMPRESS}" ]; then
	if [ -f ${IMG_FILENAME}-* ]; then
		for file in ${IMG_FILENAME}-*; do
			split_serial=$(echo ${file} | awk -F'-' '{print $NF}')
			sha256sum ${file} > sha256sum-${split_serial}.txt
			cat sha256sum-${split_serial}.txt
		done
	else
		sha256sum ${IMG_FILENAME} > sha256sum.txt
		cat sha256sum.txt
	fi

	# Move the image to the output directory, if one was specified.
	if [ -n "${OUTPUT_DIR}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv ${IMG_FILENAME}* ${OUTPUT_DIR} || true
		mv build_info.txt ${OUTPUT_DIR}
		mv sha256sum*.txt ${OUTPUT_DIR} || true
	fi

	# set outputs for github actions
	if [ -f "${GITHUB_OUTPUT}" ]; then
		echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_version=${DISPLAY_VERSION}" >> "${GITHUB_OUTPUT}"
		echo "display_name=${SYSTEM_DESC}" >> "${GITHUB_OUTPUT}"
		echo "image_filename=${IMG_FILENAME}" >> "${GITHUB_OUTPUT}"
	else
		echo "No github output file set"	
	fi
else
	echo "Local build, output IMG directly"
	if [ -n "${OUTPUT_DIR}" ]; then
		mkdir -p "${OUTPUT_DIR}"
		mv ${SYSTEM_NAME}-${VERSION}.img ${OUTPUT_DIR}
	fi
fi
