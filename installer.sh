#!/bin/sh
set -e
product="\033[33mWii Linux \033[1;36mArchPOWER\033[0m PC Installer"
version="0.0.6"
printf "$product v$version\n"

boot_blkdev=""
boot_mnt=""
rootfs_blkdev=""
rootfs_mnt=""
all_bdevs=""
seperate_sd_and_rootfs=""
UDISKS_WAS_RUNNING=""


selection=""
selection_info=""

bug_report() {
	exec >&2
	echo "Please attach everything below this line!"
	printf "=== $product - BUG REPORT ===\n"
	echo "VERSION: $version"
	for arg in "$@"; do
		printf "$arg\n"
	done
	echo "=== END OF BUG REPORT ==="
	echo "Now exiting.  Please attach the following bug report and submit a GitHub issue."
	exit 1
}

cleanup() {
	# Only attempt cleanup if variables are set
	if [ -n "$boot_mnt" ] && mountpoint -q "$boot_mnt" 2>/dev/null; then
		umount "$boot_mnt" 2>/dev/null || true
		rmdir "$boot_mnt" 2>/dev/null || true
	fi

	if [ -n "$rootfs_mnt" ] && mountpoint -q "$rootfs_mnt" 2>/dev/null; then
		umount "$rootfs_mnt" 2>/dev/null || true
		rmdir "$rootfs_mnt" 2>/dev/null || true
	fi

	# Remove loop device if it was created
	if [ -n "$loopdev" ] && losetup "$loopdev" >/dev/null 2>&1; then
		losetup -d "$loopdev" 2>/dev/null || true
	fi

	# Ensure udisks2 is restarted if we crashed while it was stopped
	if [ "$UDISKS_WAS_RUNNING" = "true" ]; then
		if command -v systemctl >/dev/null 2>&1; then
			systemctl start udisks2 2>/dev/null || true
		fi
		unset UDISKS_WAS_RUNNING
	fi
}
# Trap INT/TERM separately to ensure exit is called, preventing loop traps
trap cleanup EXIT
trap "exit 1" INT TERM

check_dependencies() {
	missing_deps=""

	# Core utilities (should always be present)
	for cmd in find grep cat basename sort mktemp mount umount sync sleep dd; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing_deps="$missing_deps $cmd"
		fi
	done

	# Partitioning and filesystem tools
	for cmd in sfdisk wipefs mkfs.ext4 mkfs.vfat blkid losetup; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing_deps="$missing_deps $cmd"
		fi
	done

	# Download tool
	if ! command -v wget >/dev/null 2>&1; then
		missing_deps="$missing_deps wget"
	fi

	# tar with required capabilities
	if ! command -v tar >/dev/null 2>&1; then
		missing_deps="$missing_deps tar"
	fi

	# mountpoint (part of util-linux)
	if ! command -v mountpoint >/dev/null 2>&1; then
		missing_deps="$missing_deps mountpoint"
	fi

	# Optional but recommended tools
	for cmd in partprobe udevadm; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			printf "\033[1;33mWARNING: $cmd not found (recommended but optional)\033[0m\n"
		fi
	done

	if [ -n "$missing_deps" ]; then
		printf "\033[1;31mERROR: Missing required dependencies:$missing_deps\033[0m\n"
		printf "\nPlease install the following packages:\n"
		printf "  Debian/Ubuntu: apt install util-linux e2fsprogs dosfstools wget tar\n"
		printf "  Fedora/RHEL:   dnf install util-linux e2fsprogs dosfstools wget tar\n"
		printf "  Arch/Garuda:   pacman -S util-linux e2fsprogs dosfstools wget tar\n"
		printf "  Gentoo:        emerge sys-apps/util-linux sys-fs/e2fsprogs sys-fs/dosfstools net-misc/wget\n"
		exit 1
	fi
}

rescan_bdevs() {
	all_bdevs=$(find /sys/block/ -mindepth 1 -maxdepth 1 \
		! -name "loop*" ! -name "sr*" ! -name "ram*" ! -name "zram*" -exec basename {} \;)
}


formatSize() {
	size=$1
	suffix=""
	while [ "$size" -gt "1000" ]; do
		size=$((size / 1000))
		case $suffix in
			"") suffix="K" ;;
			"K") suffix="M" ;;
			"M") suffix="G" ;;
			"G") suffix="T" ;;
		esac
	done

	echo "${size}${suffix}"
}

select_disk() {
	i=1
	for dev in $all_bdevs; do
		size=$(cat "/sys/block/$dev/size")
		size=$((size * 512))
		size=$(formatSize $size)

		echo "[$i] /dev/$dev - $size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a disk (or 'q' to quit): "
	read -r devnum

	if [ "$devnum" = "q" ] || [ "$devnum" = "Q" ]; then
		printf "\033[33mInstallation cancelled by user.\033[0m\n"
		exit 0
	fi

	for dev in $all_bdevs; do
		if [ "$i" = "$devnum" ]; then
			selection=$dev
			return 0
		fi
		i=$((i + 1))
	done

	return 1
}


get_parts() {
	find "/sys/block/$1/" -mindepth 1 -maxdepth 1 -name "${1}*" -exec basename {} \; | sort
}

select_part() {
	all_parts=$(get_parts "$1")

	i=1
	for part in $all_parts; do
		size=$(cat "/sys/block/$1/$part/size")
		size=$((size * 512))
		size="$(formatSize "$size")"

		echo "[$i] /dev/$part - $size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a partition (or 'q' to quit): "
	read -r partnum

	if [ "$partnum" = "q" ] || [ "$partnum" = "Q" ]; then
		printf "\033[33mInstallation cancelled by user.\033[0m\n"
		exit 0
	fi

	for part in $all_parts; do
		if [ "$i" = "$partnum" ]; then
			selection=$part

			# give caller the partition size
			selection_info=$(cat "/sys/block/$1/$part/size")
			selection_info=$((selection_info * 512))

			return 0
		fi
		i=$((i + 1))
	done

	return 1
}

show_disk_info() {
	disk="$1"

	printf "\033[1;33m=== Disk Information ===\033[0m\n"
	printf "Device: /dev/$disk\n"

	# Show size
	size=$(cat "/sys/block/$disk/size")
	size=$((size * 512))
	size=$(formatSize $size)
	printf "Size: $size\n"

	# Show model if available
	if [ -f "/sys/block/$disk/device/model" ]; then
		model=$(cat "/sys/block/$disk/device/model" | tr -d ' ')
		printf "Model: $model\n"
	fi

	# Show if removable
	if [ -f "/sys/block/$disk/removable" ]; then
		removable=$(cat "/sys/block/$disk/removable")
		if [ "$removable" = "1" ]; then
			printf "Type: Removable\n"
		else
			printf "Type: Fixed disk\n"
		fi
	fi

	# Show existing partitions
	parts=$(get_parts "$disk")
	if [ -n "$parts" ]; then
		printf "\nExisting partitions:\n"
		for part in $parts; do
			part_size=$(cat "/sys/block/$disk/$part/size")
			part_size=$((part_size * 512))
			part_size=$(formatSize "$part_size")
			printf "  /dev/$part - $part_size"

			# Show filesystem type if detectable
			if blkid "/dev/$part" >/dev/null 2>&1; then
				eval "$(blkid --output=export "/dev/$part" 2>/dev/null)"
				[ -n "$TYPE" ] && printf " ($TYPE)"
				[ -n "$LABEL" ] && printf " [label: $LABEL]"
			fi
			printf "\n"
		done
	else
		printf "\nNo existing partitions\n"
	fi

	printf "\033[1;33m========================\033[0m\n"
}

# $1 = "root" or "boot"
validate_part_selection() {
	# sanity checks

	if [ "$1" = "root" ]; then
		size="$((2 * 1024 * 1024 * 1024))"
		size_readable="2GB"
		name="rootfs"
		name2="rootfs"
		correct_type="ext4"
	elif [ "$1" = "boot" ]; then
		size="$((256 * 1024 * 1024))"
		size_readable="256MB"
		name="boot files"
		name2="boot"
		correct_type="vfat"
	else
		printf "\033[1;31mInternal error - parameter 1 not boot or root"
		bug_report "Step: validate_part" "Param1: $1"
	fi

	# size >=256M for boot or >=2GB for root?
	if [ "$selection_info" -lt "$size" ]; then
		printf "\033[1;31mThis partition is not large enough to hold the $name!\nIt should be $size_readable or larger.\033[0m\n"
		return 1
	fi

	# is vfat?
	(
		eval "$(blkid --output=export "/dev/$selection")"
		if [ "$TYPE" != "$correct_type" ]; then
			printf "\033[1;33mWe must \033[31mFORMAT\033[33m this partition in order to make it usable for a $name2 partition.\n"
			printf "Are you \033[31mSURE\033[33m that you want to \033[31mFORMAT\033[33m this partition, and lose \033[31mALL DATA\033[33m on it?\033[0m [y/N] "

			read -r yesno
			case $yesno in
				y|Y|yes|YES)
					if [ "$1" = "root" ]; then
						mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "/dev/$selection"
					elif [ "$1" = "boot" ]; then
						mkfs.vfat -F 32 "/dev/$selection"
					fi
					ret="$?"

					if [ "$ret" != "0" ]; then
						printf "\033[1;31mFATAL ERROR - Failed to format $name2 partition!\033[0m\n"
						bug_report "Step: format_part" "Return code: $?"
					fi

					printf "\033[32mPartition formatted!\033[0m\n"
					;;
				n|N|no|NO)   return 2 ;;
				*)           return 3 ;;
			esac
		fi
	)

	ret="$?"
	if [ "$ret" = "0" ]; then
		return 0
	elif [ "$ret" = "1" ]; then
		# failed format
		exit 1
	elif [ "$ret" = "3" ] || [ "$ret" = "2" ]; then
		# invalid option / not confirmed
		return 1
	else
		# ???
		bug_report "Step: validate_$1" "Return code: $ret"
	fi
}

validate_and_select_part() {
	while true; do
		select_part "$1" || {
			case "$?" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
					bug_report "Step: select_part" "Return code: $ret" ;;
			esac
		}

		validate_part_selection "$2" || {
			case "$?" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				2) printf "\033[1;31mNot confirmed.\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n";
					bug_report "Step: validate_part" "Return code: $ret" ;;
			esac
		}

		printf "\033[32mPartition validated!\033[0m\n"
		break
	done
}

select_root_disk() {
	while true; do
		printf "\033[33mYou can store \033[32mthe rootfs\033[33m (the actual system files and user data) on a different device.\n"
		printf "This, however, is highly experimental, and will disable the auto-partitioning feature of this script.\n"
		printf "Would you like to store the boot files and rootfs on seperate devices?\033[0m [y/N/q] "
		read -r yesno
		case "$yesno" in
			y|Y|yes|YES) seperate_sd_and_rootfs=true; break ;;
			n|N|no|NO|"") seperate_sd_and_rootfs=false; break ;;
			q|Q|quit|QUIT) printf "\033[33mInstallation cancelled by user.\033[0m\n"; exit 0 ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n" ;;
		esac
	done

	if [ "$seperate_sd_and_rootfs" = "true" ]; then
		while ! select_disk; do
			printf "\033[1;31mInvalid option, please try again\033[0m\n"
			rescan_bdevs
		done
		rootfs_blkdev="$selection"
	else
		rootfs_blkdev="$boot_blkdev"
	fi
}

clean_disk() {
	for dev in $(get_parts "$1") "$1"; do
		if grep -qw "/dev/$dev" /proc/mounts; then
			umount "/dev/$dev"
			ret="$?"

			if [ "$ret" != "0" ]; then
				printf "\033[1;31mFATAL ERROR: Failed to unmount /dev/$dev\033[0m\n"
				bug_report "Step: auto_install_unmount" "Return code: $ret"
			fi
		fi

		# known unmounted successfully
		wipefs -a "/dev/$dev"
	done
}

mount_in_tmpdir_or_die() {
	tmp="$(mktemp -d /tmp/wii-linux-installer.XXXXXX)" || {
		ret="$?"

		printf "\033[1;31mFATAL ERROR: Failed to create temporary directory\033[0m\n"
		bug_report "Step: mount_in_tmpdir__make_tmpdir" "Return code: $ret"
	}

	mount "$1" "$tmp" || {
		ret="$?"
		printf "\033[1;31mFATAL ERROR: Failed to mount $1\033[0m\n"
		[ -d "$tmp" ] && rmdir "$tmp" || true

		bug_report "Step: mount_in_tmpdir__do_mnt" "Return code: $ret" "To be mounted: $1" "TempDir: $tmp"
	}

	# success
	echo "$tmp"
}

# Check if pv (pipe viewer) is available
has_pv() {
	command -v pv >/dev/null 2>&1
}

# Get file size for pv
get_file_size() {
	if [ -f "$1" ]; then
		stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "0"
	else
		echo "0"
	fi
}

spinner() {
	pid=$!
	msg="$1"

	# Check if PID is valid (process might have finished already)
	if ! kill -0 "$pid" 2>/dev/null; then
		printf "\r[✓] %s complete!       \n" "$msg"
		return 0
	fi

	spin='|/-\'
	i=0
	while kill -0 "$pid" 2>/dev/null; do
		i=$(( (i+1) %4 ))
		printf "\r[%c] %s..." "${spin:$i:1}" "$msg"
		sleep .1
	done
	printf "\r[✓] %s complete!       \n" "$msg"
}

# $1 = "stop" or "start"
toggle_udisks() {
	if command -v systemctl >/dev/null 2>&1; then
		if [ "$1" = "stop" ]; then
			if systemctl is-active --quiet udisks2; then
				echo "Suspending udisks2 monitoring..."
				systemctl stop udisks2
				UDISKS_WAS_RUNNING=true
			fi
		elif [ "$1" = "start" ]; then
			if [ "$UDISKS_WAS_RUNNING" = "true" ]; then
				echo "Resuming udisks2 monitoring..."
				systemctl start udisks2
				unset UDISKS_WAS_RUNNING
			fi
		fi
	fi
}

download_or_use_local() {
	url="$1"
	filename="$2"

	# Check if local file exists
	if [ -f "./$filename" ]; then
		printf "\033[33mFound local file: $filename\033[0m\n"
		printf "Use local file? [Y/n] "
		read -r use_local
		case "$use_local" in
			n|N|no|NO)
				printf "Removing local file to re-download...\n"
				rm -f "./$filename"
				;;
			*)
				printf "\033[1;32mUsing local file!\033[0m\n"
				return 0
				;;
		esac
	fi

	# Download file
	printf "Downloading $filename...\n"
	if ! wget --continue --show-progress --progress=bar:force "$url"; then
		printf "\033[1;31mFATAL ERROR: Failed to download $filename\033[0m\n"
		exit 1
	fi

	printf "\033[32mDownload complete!\033[0m\n"
	return 0
}

install_boot() {
	tarball_name="wii_linux_sd_files_archpower-latest.tar.gz"
	base_url="https://wii-linux.org/files"

	download_or_use_local "$base_url/$tarball_name" "$tarball_name"

	boot_mnt="$(mount_in_tmpdir_or_die "$boot_blkdev")"
	echo "Now installing the boot files..."

	if has_pv; then
		file_size=$(get_file_size "$tarball_name")
		pv -p -t -e -r -b -s "$file_size" "$tarball_name" | tar xz -C "$boot_mnt/"
	else
		(tar xzf "$tarball_name" -C "$boot_mnt/") &
		spinner "Extracting"
	fi

	printf "\033[32mBoot files installed!\033[0m\n"
}

install_root() {
	tarball_name="wii_linux_rootfs_archpower-latest.tar.gz"
	base_url="https://wii-linux.org/files"

	download_or_use_local "$base_url/$tarball_name" "$tarball_name"

	rootfs_mnt="$(mount_in_tmpdir_or_die "$rootfs_blkdev")"
	echo "Now installing the rootfs... (this may take a while depending on storage speed)"

	if has_pv; then
		file_size=$(get_file_size "$tarball_name")
		pv -p -t -e -r -b -s "$file_size" "$tarball_name" | \
			tar -xzP --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -C "$rootfs_mnt/"
	else
		echo "Extracting... (this might take a while)"
		(tar -xzP --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -f "$tarball_name" -C "$rootfs_mnt/") &
		spinner "Extracting"
	fi

	echo "Syncing to disk (this WILL take a while)..."
	sync "$rootfs_mnt" &
	spinner "Syncing"
	printf "\033[32mRootfs installed!\033[0m\n"
}


do_configure() {
	printf "\033[32mSuccess!  Your Wii Linux install has been written to disk!\n"
	printf "It's now time to configure your install, if you would like to.\033[0m\n"

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
		printf "\033[33mWould you like to copy NetworkManager profiles from your host system?\033[0m [Y/n] "
		read -r yesno
		case "$yesno" in
			y|Y|yes|YES|"") copy_nm=true ;;
			n|N|no|NO) copy_nm=false ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$copy_nm" = "true" ]; then
		if [ -d /etc/NetworkManager/system-connections ] &&
		! [ -z "$(ls -A /etc/NetworkManager/system-connections)" ]; then
			cp -a /etc/NetworkManager/system-connections/* "$rootfs_mnt/etc/NetworkManager/system-connections/"
		fi
	fi

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
		printf "\033[33mWould you like to enable the SSH daemon to start automatically for remote login?\033[0m [Y/n] "
		read -r yesno
		case "$yesno" in
			y|Y|yes|YES|"") ssh=true ;;
			n|N|no|NO) ssh=false ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$ssh" = "true" ]; then
		ln -sf "/usr/lib/systemd/system/sshd.service" "$rootfs_mnt/etc/systemd/system/multi-user.target.wants/sshd.service"
	fi

	# Detect default hostname from the extracted rootfs
	if [ -f "$rootfs_mnt/etc/hostname" ]; then
		default_hostname=$(head -n 1 "$rootfs_mnt/etc/hostname" | tr -d '[:space:]')
	else
		default_hostname="unknown"
	fi

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true

		printf "\033[33mThe current hostname is '\033[1;36m$default_hostname\033[33m'.\n"
		printf "Would you like to set a custom hostname for this Wii?\033[0m [Y/n] "

		read -r yesno
		case "$yesno" in
			n|N|no|NO) set_hostname=false ;;
			y|Y|yes|YES|"") set_hostname=true ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$set_hostname" = "true" ]; then
		while true; do
			printf "Enter hostname (e.g., 'mywii', 'wii-living-room'): "
			read -r hostname

			# Validate hostname
			if [ -z "$hostname" ]; then
				printf "\033[1;31mHostname cannot be empty.\033[0m\n"
				continue
			fi

			# Check for valid hostname characters (RFC 1123)
			# Allow: a-z, A-Z, 0-9, hyphens (not at start/end)
			if ! echo "$hostname" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
				printf "\033[1;31mInvalid hostname.\033[0m\n"
				printf "Hostnames must:\n"
				printf "  - Be 1-63 characters long\n"
				printf "  - Contain only letters, numbers, and hyphens\n"
				printf "  - Not start or end with a hyphen\n"
				continue
			fi

			# Convert to lowercase for consistency
			hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')

			printf "Set hostname to '\033[1;32m$hostname\033[0m'? [Y/n] "
			read -r confirm
			case "$confirm" in
				n|N|no|NO) continue ;;
				*) break ;;
			esac
		done

		# Set hostname in /etc/hostname
		echo "$hostname" > "$rootfs_mnt/etc/hostname"

		# Update /etc/hosts
		# Remove old hostname entries and add new one
		if [ -f "$rootfs_mnt/etc/hosts" ]; then
			# Backup original
			cp "$rootfs_mnt/etc/hosts" "$rootfs_mnt/etc/hosts.bak"

			# Remove lines with 127.0.1.1 (local hostname)
			grep -v "^127.0.1.1" "$rootfs_mnt/etc/hosts.bak" > "$rootfs_mnt/etc/hosts" || true
		fi

		# Add new hostname entry
		echo "127.0.1.1	$hostname" >> "$rootfs_mnt/etc/hosts"

		printf "\033[32mHostname set to '$hostname'!\033[0m\n"
	fi

	# TODO: More here.... set up user account?
}

unmount_and_cleanup() {
	printf "\033[32mSuccess!  Now syncing to disk and cleaning up, please wait...\n"
	sync &
	spinner "Final sync"

	umount "$boot_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to unmount boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$boot_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	umount "$rootfs_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to unmount rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$rootfs_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}
}

manual_install() {
	printf "\033[33mWe now need to know \033[32mwhat partition to store the boot files\033[33m in.\033[0m\n"
	validate_and_select_part "$boot_blkdev" "boot"
	boot_blkdev="/dev/$selection"

	printf "\033[33mWe now need to know \033[32mwhat partition to store the root filesystem\033[33m in.\033[0m\n"
	validate_and_select_part "$rootfs_blkdev" "root"
	rootfs_blkdev="/dev/$selection"

	echo
	printf "\033[1;33m╔════════════════════════════════════════════════════════════╗\033[0m\n"
	printf "\033[1;33m║              \033[1;32mReady to Install\033[1;33m                         ║\033[0m\n"
	printf "\033[1;33m╚════════════════════════════════════════════════════════════╝\033[0m\n"
	echo

	printf "Boot partition: $boot_blkdev\n"
	printf "Root partition: $rootfs_blkdev\n"
	echo
	printf "\033[1;33mThe installer will now:\033[0m\n"
	printf "  1. Format $boot_blkdev as FAT32 (if needed)\n"
	printf "  2. Format $rootfs_blkdev as ext4\n"
	printf "  3. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m⚠  Data on these partitions will be lost! ⚠\033[0m\n"
	echo
	printf "Continue? [yes/NO] "
	read -r final_confirm

	case "$final_confirm" in
		yes|YES)
			echo "Proceeding with installation..."
			;;
		*)
			printf "\033[1;33mInstallation cancelled.\033[0m\n"
			exit 0
			;;
	esac

	install_boot

	# Stop DE monitoring
	toggle_udisks stop

	echo "Formatting..."

	# Create a temp log file to capture mkfs output
	fmt_log=$(mktemp)

	# Run wipefs and mkfs in background, redirecting output to log
	{
		wipefs -a "$rootfs_blkdev" && \
		mkfs.ext4 -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev"
	} > "$fmt_log" 2>&1 &

	# Run spinner
	spinner "Formatting rootfs"

	# Check exit code of the background process
	wait $!
	ret=$?

	if [ $ret -ne 0 ]; then
		printf "\033[1;31mFailed to format rootfs!\033[0m\n"
		echo "--- Error Log ---"
		cat "$fmt_log"
		rm -f "$fmt_log"
		bug_report "Step: rootfs_format" "Return code: $ret" "Root blkdev: $rootfs_blkdev"
	fi
	rm -f "$fmt_log"

	# Stabilization pause
	udevadm settle --timeout=10 2>/dev/null || true
	sleep 2

	# Resume monitoring
	toggle_udisks start

	install_root

	do_configure

	unmount_and_cleanup
}

automatic_install() {
	# currently, boot_blkdev is our SD Card.
	# Let's unmount and erase any partitons on it before we try to repartition
	sd_blkdev="$boot_blkdev"

	fatSize=""
	while true; do
		printf "\033[33mHow many MB of space would you like to reserve for the \033[32mFAT32 Boot files / Homebrew partiton\033[33m?\033[0m [default:256, q to quit] "
		read -r fatSz
		case "$fatSz" in
			q|Q|quit|Quit) printf "\033[33mInstallation cancelled by user.\033[0m\n"; exit 0 ;;
			*[!0-9]*) printf "\033[1;31mInvalid input!  Please type a number.\033[0m\n"; continue ;;
			'') fatSize="+256M" ;;
			*)
				# valid number
				fatSize="+${fatSz}M"
		esac
		unset fatSz
		break
	done

	# Calculate partition size in MB for the confirmation prompt
	fat_mb=$(echo "$fatSize" | sed 's/+\([0-9]*\)M/\1/')

	echo
	printf "\033[1;33m╔════════════════════════════════════════════════════════════╗\033[0m\n"
	printf "\033[1;33m║           \033[1;31mWARNING: DESTRUCTIVE OPERATION\033[1;33m              ║\033[0m\n"
	printf "\033[1;33m╚════════════════════════════════════════════════════════════╝\033[0m\n"
	echo

	show_disk_info "$sd_blkdev"

	echo
	printf "\033[1;31mThe automatic installer will:\033[0m\n"
	printf "  1. \033[1;31mERASE ALL DATA\033[0m on /dev/$sd_blkdev\n"
	printf "  2. Create a ${fat_mb}MB FAT32 partition for boot files\n"
	printf "  3. Create an ext4 partition using remaining space for rootfs\n"
	printf "  4. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m⚠  ALL EXISTING DATA ON THIS DISK WILL BE PERMANENTLY LOST! ⚠\033[0m\n"
	echo
	printf "Type 'YES' in CAPITAL letters to continue: "
	read -r final_confirm

	if [ "$final_confirm" != "YES" ]; then
		printf "\033[1;33mInstallation cancelled.\033[0m\n"
		exit 0
	fi

	echo "Proceeding with installation..."

	# Stop DE monitoring to prevent crashes
	toggle_udisks stop

	echo "Cleaning disk..."
	clean_disk "$sd_blkdev"

	echo "Repartitioning..."

	# Calculate partition sizes in sectors
	fat_sectors=$((fat_mb * 1024 * 1024 / 512))

	# Create partition table with sfdisk
	cat << EOF | sfdisk "/dev/$sd_blkdev"
label: dos
start=2048, size=$fat_sectors, type=c, bootable
type=83
EOF

	# set up a loop device so we get a consistent partition scheme of /dev/loopXp#
	loopdev="$(losetup --direct-io=on --show -P -f "/dev/$sd_blkdev")" && [ "$loopdev" != "" ] || {
		ret="$?"
		printf "\033[1;31mLoop device creation failed!\033[0m\n"
		bug_report "Step: loopdev_create" "Return code: $ret"
	}
	partprobe "$loopdev" 2>/dev/null || true
	udevadm settle --timeout=10 2>/dev/null || sleep 1

	echo "Synchronizing partition table with kernel..."
	sync

	partprobe "/dev/$sd_blkdev" 2>/dev/null || true

	udevadm settle --timeout=10 2>/dev/null || {
		echo "Waiting for device nodes to appear..."
		sleep 2
	}

	boot_blkdev="${loopdev}p1"
	rootfs_blkdev="${loopdev}p2"

	echo "Formatting..."

	fmt_log=$(mktemp)

	{
		mkfs.vfat -F 32 "$boot_blkdev" && \
		mkfs.ext4 -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev"
	} > "$fmt_log" 2>&1 &

	spinner "Formatting partitions"

	wait $!
	ret=$?

	if [ $ret -ne 0 ]; then
		printf "\033[1;31mFailed to format partitions!\033[0m\n"
		echo "--- Error Log ---"
		cat "$fmt_log"
		rm -f "$fmt_log"
		bug_report "Step: loopdev_format" "Return code: $ret" "Boot blkdev: $boot_blkdev" "Root blkdev: $rootfs_blkdev"
	fi
	rm -f "$fmt_log"

	# Wait for the Desktop Environment to notice the new filesystems
	# This prevents crashing due to event flooding
	udevadm settle --timeout=10 2>/dev/null || true
	sleep 2

	# Resume monitoring
	toggle_udisks start

	install_boot
	install_root

	do_configure

	unmount_and_cleanup
	losetup -d "$loopdev"
}
# ====
# Start of the actual installer process
# ====

# Check for optional tools
if ! command -v pv >/dev/null 2>&1; then
	printf "\033[1;33mNote: Install 'pv' for progress bars during extraction\033[0m\n"
	printf "  (This is optional, installation will work without it)\n"
	echo
fi

check_dependencies

if [ "$(id -u)" != "0" ]; then
	printf "\033[1;31mThis installer must be run as root!\033[0m\n"
	exit 1
fi

echo "We need to gather some info about where you would like to install to..."
rescan_bdevs

printf "\033[33mWe now need to know where your \033[32mSD Card\033[33m is.\033[0m\n"
while ! select_disk; do
	printf "\033[1;31mInvalid option, please try again\033[0m\n"
	rescan_bdevs
done
boot_blkdev="$selection"

select_root_disk

if [ "$seperate_sd_and_rootfs" = "false" ]; then
	while true; do
		printf "\033[33mWould you like \033[32m[A]utomatic\033[33m or \033[32m[M]anual\033[33m install?\033[0m "
		read -r doauto
		case "$doauto" in
			a|A|auto|Auto|AUTO|automatic|Automatic|AUTOMATIC) automatic_install ;;
			m|M|man|Man|MAN|manual|Manual|MANUAL) manual_install ;;
			q|Q|quit|Quit|QUIT) printf "\033[33mInstallation cancelled by user.\033[0m\n"; exit 0 ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
		esac
		break
	done
else
	manual_install
fi

printf "\033[1;32mSUCCESS!!  If you're reading this, your Wii Linux install is complete!\033[0m\n"
