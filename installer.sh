#!/bin/sh
set -e
product=$(printf '\033[33mWii Linux \033[1;36mArchPOWER\033[0m PC Installer')
product_plain="Wii Linux ArchPOWER PC Installer"
version="0.1.0"
printf "%s v%s\n" "$product" "$version"

boot_blkdev=""
boot_mnt=""
rootfs_blkdev=""
rootfs_mnt=""
all_bdevs=""
separate_sd_and_rootfs=""
UDISKS_WAS_RUNNING=""
boot_needs_format=false


selection=""
selection_info=""
fmt_log=""
_bg_pids=""

bug_report() {
	exec >&2
	echo "Please attach everything below this line!"
	printf "=== %s - BUG REPORT ===\n" "$product_plain"
	echo "VERSION: $version"
	for arg in "$@"; do
		printf '%s\n' "$arg"
	done
	echo "=== END OF BUG REPORT ==="
	echo "Now exiting.  Please attach the following bug report and submit a GitHub issue."
	exit 1
}

cleanup() {
	# Kill tracked background processes explicitly. kill $(jobs -p) is unreliable
	# in POSIX sh because command substitutions run in a subshell with an empty
	# job table (notably dash, which is /bin/sh on Debian/Ubuntu).
	if [ -n "$_bg_pids" ]; then
		# shellcheck disable=SC2086 -- word splitting is intentional
		kill $_bg_pids 2>/dev/null || true
	fi
	wait 2>/dev/null || true

	# Only attempt cleanup if variables are set
	if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
		if mountpoint -q "$boot_mnt" 2>/dev/null; then
			umount "$boot_mnt" 2>/dev/null || true
		fi
		rmdir "$boot_mnt" 2>/dev/null || true
	fi

	if [ -n "$rootfs_mnt" ] && [ -d "$rootfs_mnt" ]; then
		if mountpoint -q "$rootfs_mnt" 2>/dev/null; then
			umount "$rootfs_mnt" 2>/dev/null || true
		fi
		rmdir "$rootfs_mnt" 2>/dev/null || true
	fi

	# Clean up format log if the trap fires mid-format
	if [ -n "$fmt_log" ] && [ -f "$fmt_log" ]; then
		rm -f "$fmt_log" 2>/dev/null || true
	fi

	# Ensure monitoring is restarted if we crashed while it was stopped
	if [ "$UDISKS_WAS_RUNNING" = "true" ]; then
		toggle_udisks start
	fi
}
# Trap INT/TERM separately to ensure exit is called, preventing loop traps
trap cleanup EXIT
trap "exit 1" INT TERM

check_dependencies() {
	missing_deps=""

	# Core utilities (should always be present)
	for cmd in find grep cat basename dirname readlink awk sort mktemp mount umount sync sleep dd stat head tr sed; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing_deps="$missing_deps $cmd"
		fi
	done

	# Partitioning and filesystem tools
	for cmd in sfdisk wipefs mkfs.ext4 mkfs.vfat blkid; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing_deps="$missing_deps $cmd"
		fi
	done

	# Download tool
	if ! command -v wget >/dev/null 2>&1; then
		missing_deps="$missing_deps wget"
	fi

	# tar with required capabilities; must be GNU tar as non-GNU implementations
	# lack --acls, --xattrs, --numeric-owner, and --sparse support.
	if ! command -v tar >/dev/null 2>&1; then
		missing_deps="$missing_deps tar"
	elif ! tar --version 2>&1 | grep -q "GNU tar"; then
		printf "\033[1;31mERROR: 'tar' found but it is not GNU tar.\033[0m\n" >&2
		printf "This script requires GNU tar for ACL, xattr, and sparse file support.\n" >&2
		printf "Please install GNU tar using your distribution's package manager.\n" >&2
		exit 1
	fi

	# mountpoint (part of util-linux)
	if ! command -v mountpoint >/dev/null 2>&1; then
		missing_deps="$missing_deps mountpoint"
	fi

	# Optional but recommended tools
	for cmd in partprobe udevadm timeout; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			printf '\033[1;33mWARNING: %s not found (recommended but optional)\033[0m\n' "$cmd"
		fi
	done

	if [ -n "$missing_deps" ]; then
		printf '\033[1;31mERROR: Missing required dependencies:%s\033[0m\n' "$missing_deps"
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
		! -name "loop*" ! -name "sr*" ! -name "ram*" ! -name "zram*" \
		! -name "dm-*" ! -name "md*" -exec basename {} \; | sort)
}


formatSize() {
	size=$1
	suffix="K"
	while [ "$size" -ge "1024" ]; do
		size=$((size / 1024))
		case $suffix in
			"K") suffix="M" ;;
			"M") suffix="G" ;;
			"G") suffix="T" ;;
		esac
	done

	echo "${size}${suffix}"
}

select_disk() {
	if [ -z "$all_bdevs" ]; then
		printf "\033[1;31mNo eligible block devices found.\033[0m\n"
		printf "Ensure a disk is connected, then press Enter to rescan.\n"
		read -r _unused || true
		return 1
	fi

	i=1
	for dev in $all_bdevs; do
		size=$(cat "/sys/block/$dev/size")
		size=$((size / 2))
		size=$(formatSize $size)

		# Check if removable (typically SD cards/USB drives)
		removable=""
		if [ -f "/sys/block/$dev/removable" ] && [ "$(cat "/sys/block/$dev/removable")" = "1" ]; then
			removable=$(printf ' \033[32m(Removable)\033[0m')
		fi

		printf '[%s] /dev/%s - %s%s\n' "$i" "$dev" "$size" "$removable"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a disk (or 'q' to quit): "
	read -r devnum || true

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
	find "/sys/block/$1/" -mindepth 1 -maxdepth 1 -name "${1}*" -exec basename {} \; | sort -V
}

select_part() {
	all_parts=$(get_parts "$1")

	if [ -z "$all_parts" ]; then
		printf '\033[1;31mNo partitions found on /dev/%s.\033[0m\n' "$1"
		printf "The disk must be partitioned before using manual mode.\n"
		return 1
	fi

	i=1
	for part in $all_parts; do
		size=$(cat "/sys/block/$1/$part/size")
		size=$((size / 2))
		size="$(formatSize "$size")"

		printf '[%s] /dev/%s - %s\n' "$i" "$part" "$size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a partition (or 'q' to quit): "
	read -r partnum || true

	if [ "$partnum" = "q" ] || [ "$partnum" = "Q" ]; then
		printf "\033[33mInstallation cancelled by user.\033[0m\n"
		exit 0
	fi

	for part in $all_parts; do
		if [ "$i" = "$partnum" ]; then
			selection=$part

			# give caller the partition size
			selection_info=$(cat "/sys/block/$1/$part/size")
			selection_info=$((selection_info / 2))

			return 0
		fi
		i=$((i + 1))
	done

	return 1
}

show_disk_info() {
	disk="$1"

	printf "\033[1;33m=== Disk Information ===\033[0m\n"
	printf 'Device: /dev/%s\n' "$disk"

	# Show size
	size=$(cat "/sys/block/$disk/size")
	size=$((size / 2))
	size=$(formatSize $size)
	printf 'Size: %s\n' "$size"

	# Show model if available
	if [ -f "/sys/block/$disk/device/model" ]; then
		model=$(sed 's/[[:space:]]*$//' "/sys/block/$disk/device/model")
		printf "Model: %s\n" "$model"
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
			part_size=$((part_size / 2))
			part_size=$(formatSize "$part_size")
			printf '  /dev/%s - %s' "$part" "$part_size"

			# Show filesystem type if detectable
			if blkid "/dev/$part" >/dev/null 2>&1; then
				fstype=$(blkid -s TYPE -o value "/dev/$part" 2>/dev/null || true)
				fslabel=$(blkid -s LABEL -o value "/dev/$part" 2>/dev/null || true)
				[ -n "$fstype" ] && printf ' (%s)' "$fstype"
				[ -n "$fslabel" ] && printf " [label: %s]" "$fslabel"
				unset fstype fslabel
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
		size="$((1536 * 1024))" # 1.5GB
		size_readable="1.5GB"
		name="rootfs"
		name2="rootfs"
		correct_type="ext4"
	elif [ "$1" = "boot" ]; then
		size="$((256 * 1024))" # 256MB
		size_readable="256MB"
		name="boot files"
		name2="boot"
		correct_type="vfat"
	else
		printf "\033[1;31mInternal error - parameter 1 not boot or root"
		bug_report "Step: validate_part" "Param1: $1"
	fi

	if [ "$selection_info" -lt "$size" ]; then
		printf '\033[1;31mThis partition is not large enough to hold the %s!\nIt should be %s or larger.\033[0m\n' "$name" "$size_readable"
		return 1
	fi

	if [ "$1" = "boot" ]; then
		sel_mb=$((selection_info / 1024))
		if [ "$sel_mb" -gt 2097152 ]; then # 2TiB in MiB
			printf "\033[1;31mThis partition is too large for FAT32! It must be 2TB or smaller.\033[0m\n"
			return 1
		fi
	fi

	# Check filesystem type and warn if formatting will be required
	fstype=$(blkid -s TYPE -o value "/dev/$selection" 2>/dev/null || true)
	if [ "$fstype" != "$correct_type" ]; then
		printf '\033[1;33mThis partition will need to be formatted as %s (%s).\n' "$name2" "$correct_type"
		printf "All existing data on it will be \033[31mERASED\033[33m during installation.\n"
		printf "Do you want to continue?\033[0m [y/N] "

		read -r yesno || true
		case $yesno in
			y|Y|yes|YES)
				[ "$1" = "boot" ] && boot_needs_format=true
				return 0
				;;
			n|N|no|NO|"") return 2 ;;
			*)             return 3 ;;
		esac
	fi
}

validate_and_select_part() {
	while true; do
		select_part "$1" || {
			_rc="$?"
			case "$_rc" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
					bug_report "Step: select_part" "Return code: $_rc" ;;
			esac
		}

		validate_part_selection "$2" || {
			_rc="$?"
			case "$_rc" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				2) printf "\033[1;31mNot confirmed.\033[0m\n"; continue ;;
				3) printf "\033[1;31mInvalid answer, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
					bug_report "Step: validate_part" "Return code: $_rc" ;;
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
		printf "Would you like to store the boot files and rootfs on separate devices?\033[0m [y/N/q] "
		read -r yesno || true
		case "$yesno" in
			y|Y|yes|YES) separate_sd_and_rootfs=true; break ;;
			n|N|no|NO|"") separate_sd_and_rootfs=false; break ;;
			q|Q|quit|QUIT) printf "\033[33mInstallation cancelled by user.\033[0m\n"; exit 0 ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n" ;;
		esac
	done

	if [ "$separate_sd_and_rootfs" = "true" ]; then
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
		if grep -q "^/dev/$dev " /proc/mounts; then
			if ! umount "/dev/$dev"; then
				ret=$?
				printf '\033[1;31mFATAL ERROR: Failed to unmount /dev/%s\033[0m\n' "$dev"
				bug_report "Step: auto_install_unmount" "Return code: $ret"
			fi
		fi

		wipefs -a "/dev/$dev" || true
	done
}

mount_in_tmpdir_or_die() {
	tmp="$(mktemp -d /tmp/wii-linux-installer.XXXXXX)" || {
		ret="$?"

		printf "\033[1;31mFATAL ERROR: Failed to create temporary directory\033[0m\n" >&2
		bug_report "Step: mount_in_tmpdir__make_tmpdir" "Return code: $ret"
	}

	mount "$1" "$tmp" || {
		ret="$?"
		printf '\033[1;31mFATAL ERROR: Failed to mount %s\033[0m\n' "$1" >&2
		if [ -d "$tmp" ]; then rmdir "$tmp"; fi

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

	i=0
	while kill -0 "$pid" 2>/dev/null; do
		i=$(( (i+1) % 4 ))
		case $i in
			0) frame="|" ;;
			1) frame="/" ;;
			2) frame="-" ;;
			3) frame="\\" ;;
		esac
		printf "\r[%s] %s..." "$frame" "$msg"
		sleep 0.1
	done
	printf "\r[✓] %s complete!       \n" "$msg"
}

sync_progress() {
	msg="$1"
	target_path="$2"

	# Determine the base block device (e.g., /dev/sda1 -> sda)
	part_name=$(basename "$target_path")
	parent_name=$(basename "$(dirname "$(readlink -f "/sys/class/block/$part_name")" 2>/dev/null)" 2>/dev/null || echo "$part_name")

	if [ -f "/sys/block/$parent_name/stat" ]; then
		stat_file="/sys/block/$parent_name/stat"
		dev_name="$parent_name"
	else
		stat_file="/sys/block/$part_name/stat"
		dev_name="$part_name"
	fi

	if [ -n "$3" ]; then
		sync "$3" &
	else
		sync &
	fi
	sync_pid=$!
	_bg_pids="${_bg_pids:+$_bg_pids }$sync_pid"

	# If the sysfs stat file isn't found, gracefully fallback to the regular spinner
	if [ ! -f "$stat_file" ]; then
		spinner "$msg"
		return
	fi

	i=0
	ticks=0
	s1=$(awk '{print $7}' "$stat_file" 2>/dev/null)
	s1=${s1:-0}
	diff=0
	kb_s="?"

	while kill -0 "$sync_pid" 2>/dev/null; do
		i=$(( (i+1) % 4 ))
		case $i in
			0) frame="|" ;;
			1) frame="/" ;;
			2) frame="-" ;;
			3) frame="\\" ;;
		esac

		# Update KB/s calculation every 1 second (10 ticks)
		if [ "$ticks" -eq 10 ]; then
			s2=$(awk '{print $7}' "$stat_file" 2>/dev/null)
			s2=${s2:-0}
			diff=$((s2 - s1))
			[ "$diff" -lt 0 ] && diff=0
			kb_s=$((diff / 2)) # 1 sector = 512 bytes = 0.5 KB
			s1=$s2
			ticks=0
		fi

		if [ "$kb_s" = "?" ]; then
			printf "\r[%s] %s... (Calculating...)                     " "$frame" "$msg"
		elif [ "$diff" -gt 0 ]; then
			printf "\r[%s] %s... (Writing to %s: %s KB/s)      " "$frame" "$msg" "$dev_name" "$kb_s"
		else
			printf "\r[%s] %s... (Finishing up)                       " "$frame" "$msg"
		fi

		sleep 0.1
		ticks=$((ticks + 1))
	done
	printf "\r[✓] %s complete!                                     \n" "$msg"
}

# Portable udev settle: tries udevadm first, falls back to mdev on systems
# that use it instead. Callers should still follow up with a sleep if needed.
settle_udev() {
	if command -v udevadm >/dev/null 2>&1; then
		udevadm settle --timeout=10 2>/dev/null || true
	elif command -v mdev >/dev/null 2>&1; then
		mdev -s 2>/dev/null || true
	fi
}

# Discard any buffered stdin (e.g. accidental double-enter) so the next
# read prompt starts clean.  Uses timeout if available; silently skips
# the drain otherwise.
drain_stdin() {
	if command -v timeout >/dev/null 2>&1; then
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
	fi
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
				systemctl start udisks2 2>/dev/null || true
				unset UDISKS_WAS_RUNNING
			fi
		fi
	elif command -v rc-service >/dev/null 2>&1; then
		if [ "$1" = "stop" ]; then
			if rc-service udevd status >/dev/null 2>&1; then
				echo "Suspending udevd monitoring..."
				rc-service udevd stop 2>/dev/null || true
				UDISKS_WAS_RUNNING=true
			fi
		elif [ "$1" = "start" ]; then
			if [ "$UDISKS_WAS_RUNNING" = "true" ]; then
				echo "Resuming udevd monitoring..."
				rc-service udevd start 2>/dev/null || true
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
		printf '\033[33mFound local file: %s\033[0m\n' "$filename"
		printf "Use local file? [Y/n] "
		read -r use_local || true
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
	# Print the current working directory to clarify where the file will land
	printf 'Current working directory: %s\n' "$PWD"
	printf 'Downloading %s...\n' "$filename"
	tmp_dl=$(mktemp "/tmp/wii_dl.XXXXXX")
	if ! wget --timeout=30 --tries=3 -O "$tmp_dl" --show-progress --progress=bar:force "$url"; then
		rm -f "$tmp_dl"
		printf '\033[1;31mFATAL ERROR: Failed to download %s\033[0m\n' "$filename"
		exit 1
	fi
	mv -f "$tmp_dl" "./$filename"

	if [ ! -s "./$filename" ]; then
		printf '\033[1;31mFATAL ERROR: Downloaded file is empty or missing: %s\033[0m\n' "$filename"
		rm -f "./$filename"
		exit 1
	fi

	# Make sure regular users can delete/move the downloaded file
	if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
		chown "$SUDO_UID:$SUDO_GID" "./$filename" 2>/dev/null || true
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
		# Capture pv's exit code separately: without pipefail (non-POSIX) the
		# pipeline only surfaces tar's exit code, so a pv failure mid-stream
		# would go undetected and silently produce a truncated installation.
		_pv_rc=$(mktemp)
		{ pv -p -t -e -r -b -s "$file_size" "$tarball_name"; echo $? > "$_pv_rc"; } | \
			tar xzf - --no-same-owner --no-same-permissions -C "$boot_mnt/"
		tar_ret=$?
		pv_ret=$(cat "$_pv_rc" 2>/dev/null || echo 1)
		rm -f "$_pv_rc"
		if [ "$tar_ret" -ne 0 ] || [ "$pv_ret" -ne 0 ]; then
			printf "\033[1;31mFATAL ERROR: Failed to extract boot files!\033[0m\n"
			bug_report "Step: install_boot_extract" "pv exit: $pv_ret" "tar exit: $tar_ret"
		fi
	else
		(tar xzf "$tarball_name" --no-same-owner --no-same-permissions -C "$boot_mnt/") &
		tar_pid=$!
		_bg_pids="${_bg_pids:+$_bg_pids }$tar_pid"
		spinner "Extracting"
		wait $tar_pid || {
			ret=$?
			printf "\033[1;31mFATAL ERROR: Failed to extract boot files!\033[0m\n"
			bug_report "Step: install_boot_extract" "Return code: $ret"
		}
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
		_pv_rc=$(mktemp)
		{ pv -p -t -e -r -b -s "$file_size" "$tarball_name"; echo $? > "$_pv_rc"; } | \
			tar -xzf - --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -C "$rootfs_mnt/"
		tar_ret=$?
		pv_ret=$(cat "$_pv_rc" 2>/dev/null || echo 1)
		rm -f "$_pv_rc"
		if [ "$tar_ret" -ne 0 ] || [ "$pv_ret" -ne 0 ]; then
			printf "\033[1;31mFATAL ERROR: Failed to extract rootfs!\033[0m\n"
			bug_report "Step: install_root_extract" "pv exit: $pv_ret" "tar exit: $tar_ret"
		fi
	else
		echo "Extracting... (this might take a while)"
		(tar -xz --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -f "$tarball_name" -C "$rootfs_mnt/") &
		tar_pid=$!
		_bg_pids="${_bg_pids:+$_bg_pids }$tar_pid"
		spinner "Extracting"
		wait $tar_pid || {
			ret=$?
			printf "\033[1;31mFATAL ERROR: Failed to extract rootfs!\033[0m\n"
			bug_report "Step: install_root_extract" "Return code: $ret"
		}
	fi

	echo "Syncing to disk..."
	sync_progress "Syncing" "$rootfs_blkdev" "$rootfs_mnt"
	printf "\033[32mRootfs installed!\033[0m\n"
}


do_configure() {
	printf "\033[32mSuccess!  Your Wii Linux install has been written to disk!\n"
	printf "It's now time to configure your install, if you would like to.\033[0m\n"

	while true; do
		# discard any double-enter taps or similar
		drain_stdin
		printf "\033[33mWould you like to copy NetworkManager profiles from your host system?\033[0m [Y/n] "
		read -r yesno || true
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
			mkdir -p "$rootfs_mnt/etc/NetworkManager/system-connections/"
			chmod 700 "$rootfs_mnt/etc/NetworkManager/system-connections/"
			cp -a /etc/NetworkManager/system-connections/. "$rootfs_mnt/etc/NetworkManager/system-connections/"
		fi
	fi

	while true; do
		# discard any double-enter taps or similar
		drain_stdin
		printf "\033[33mWould you like to enable the SSH daemon to start automatically for remote login?\033[0m [Y/n] "
		read -r yesno || true
		case "$yesno" in
			y|Y|yes|YES|"") ssh=true ;;
			n|N|no|NO) ssh=false ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$ssh" = "true" ]; then
		mkdir -p "$rootfs_mnt/etc/systemd/system/multi-user.target.wants/"
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
		drain_stdin

		printf "\033[33mThe current hostname is '\033[1;36m%s\033[33m'.\n\033[0m" "$default_hostname"
		printf "Would you like to set a custom hostname for this Wii?\033[0m [Y/n] "

		read -r yesno || true
		case "$yesno" in
			n|N|no|NO) set_hostname=false ;;
			y|Y|yes|YES|"") set_hostname=true ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$set_hostname" = "true" ]; then
		hostname_changed=false
		while true; do
			printf "Enter hostname (leave blank to keep '%s'): " "$default_hostname"
			read -r hostname || true

			if [ -z "$hostname" ]; then
				printf "Keep existing hostname '\033[1;32m%s\033[0m'? [Y/n] " "$default_hostname"
				read -r confirm || true
				case "$confirm" in
					n|N|no|NO) continue ;;
					*) break ;; # hostname_changed remains false
				esac
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

			printf "Set hostname to '\033[1;32m%s\033[0m'? [Y/n] " "$hostname"
			read -r confirm || true
			case "$confirm" in
				n|N|no|NO) continue ;;
				*) hostname_changed=true; break ;;
			esac
		done

		if [ "$hostname_changed" = "true" ]; then
			# Set hostname in /etc/hostname
			printf '%s\n' "$hostname" > "$rootfs_mnt/etc/hostname"

			# Update /etc/hosts
			# Remove old hostname entries and add new one
			if [ -f "$rootfs_mnt/etc/hosts" ]; then
				_hosts_tmp=$(mktemp)
				# Remove lines with 127.0.1.1 (local hostname)
				grep -v "^127\.0\.1\.1[[:blank:]]" "$rootfs_mnt/etc/hosts" > "$_hosts_tmp" || true
				mv "$_hosts_tmp" "$rootfs_mnt/etc/hosts"
			fi

			# Add new hostname entry
			printf "127.0.1.1\t%s\n" "$hostname" >> "$rootfs_mnt/etc/hosts"

			printf "\033[32mHostname set to '%s'!\033[0m\n" "$hostname"
		else
			printf "\033[32mKeeping existing hostname '%s'.\033[0m\n" "$default_hostname"
		fi
	fi

	# TODO: More here.... set up user account?
}

unmount_and_cleanup() {
	printf "\033[32mSuccess!  Now syncing to disk and cleaning up, please wait...\n"
	sync_progress "Final sync" "$rootfs_blkdev"

	umount "$boot_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to unmount boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$boot_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	umount "$rootfs_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to unmount rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$rootfs_mnt" || {
		ret=$?
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

	if [ "$boot_blkdev" = "$rootfs_blkdev" ]; then
		printf "\033[1;31mError: Boot and root partitions must be different devices!\033[0m\n"
		exit 1
	fi

	echo
	printf "\033[1;33m╔════════════════════════════════════════════════════════════╗\033[0m\n"
	printf "\033[1;33m║              \033[1;32mReady to Install\033[1;33m                              ║\033[0m\n"
	printf "\033[1;33m╚════════════════════════════════════════════════════════════╝\033[0m\n"
	echo

	# Get sizes for confirmation display
	boot_name=$(basename "$boot_blkdev")
	boot_size=$(cat "/sys/class/block/$boot_name/size" 2>/dev/null || echo 0)
	boot_size=$(( boot_size / 2 ))
	boot_size=$(formatSize "$boot_size")

	root_name=$(basename "$rootfs_blkdev")
	root_size=$(cat "/sys/class/block/$root_name/size" 2>/dev/null || echo 0)
	root_size=$(( root_size / 2 ))
	root_size=$(formatSize "$root_size")

	printf 'Boot partition: \033[1;36m%s\033[0m (%s)\n' "$boot_blkdev" "$boot_size"
	printf 'Root partition: \033[1;36m%s\033[0m (%s)\n' "$rootfs_blkdev" "$root_size"
	echo
	printf "\033[1;33mThe installer will now:\033[0m\n"
	printf '  1. Format %s as FAT32 (if needed)\n' "$boot_blkdev"
	printf '  2. Format %s as ext4\n' "$rootfs_blkdev"
	printf "  3. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m⚠  Data on these partitions will be lost! ⚠\033[0m\n"
	echo
	printf "Continue? [yes/NO] "
	read -r final_confirm || true

	case "$final_confirm" in
		yes|YES)
			echo "Proceeding with installation..."
			;;
		*)
			printf "\033[1;33mInstallation cancelled.\033[0m\n"
			exit 0
			;;
	esac

	# Stop DE monitoring
	toggle_udisks stop

	# Unmount selected partitions if the host OS has auto-mounted them
	echo "Unmounting selected partitions..."
	for _dev in "$boot_blkdev" "$rootfs_blkdev"; do
		if grep -q "^$_dev " /proc/mounts; then
			umount "$_dev" || {
				printf "\033[1;31mFATAL ERROR: Failed to unmount %s\033[0m\n" "$_dev" >&2
				exit 1
			}
		fi
	done

	echo "Formatting..."

	# Create a temp log file to capture mkfs output
	fmt_log=$(mktemp)

	# Format boot if it wasn't already the correct type, always format rootfs
	{
		set -e
		if [ "$boot_needs_format" = "true" ]; then
			wipefs -a "$boot_blkdev"
			mkfs.vfat -F 32 "$boot_blkdev"
		fi
		wipefs -a "$rootfs_blkdev"
		mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev"
	} > "$fmt_log" 2>&1 &
	fmt_pid=$!
	_bg_pids="${_bg_pids:+$_bg_pids }$fmt_pid"

	# Run spinner
	spinner "Formatting"

	# Check exit code of the background process
	ret=0
	wait $fmt_pid || ret=$?

	if [ "$ret" -ne 0 ]; then
		printf "\033[1;31mFailed to format partitions!\033[0m\n"
		echo "--- Error Log ---"
		cat "$fmt_log"
		rm -f "$fmt_log"
		bug_report "Step: rootfs_format" "Return code: $ret" "Root blkdev: $rootfs_blkdev"
	fi
	rm -f "$fmt_log"

	# Stabilization pause
	settle_udev
	sleep 2

	install_boot
	install_root

	do_configure

	unmount_and_cleanup

	# Resume DE monitoring only after partitions are fully unmounted
	toggle_udisks start
}

automatic_install() {
	# currently, boot_blkdev is our SD Card.
	# Let's unmount and erase any partitions on it before we try to repartition
	sd_blkdev="$boot_blkdev"

	sys_size=$(cat "/sys/block/$sd_blkdev/size" 2>/dev/null || echo 0)
	total_mb=$((sys_size / 2048))

	# The Wii requires an MBR partition table, which has a strict 2TB limit.
	if [ "$total_mb" -gt 2097152 ]; then
		printf "\033[1;33mWarning: This drive is larger than 2TB.\nThe Wii (and MBR partition tables) only support up to 2TB.\nOnly the first 2TB of this drive will be used.\033[0m\n"
		total_mb=2097152
	fi

	# Minimum space required: 256MB boot + 1536MB (1.5GB) rootfs + 2MB partition table overhead = 1794MB
	if [ "$total_mb" -lt 1794 ]; then
		printf "\033[1;31mError: This disk is too small. At least 1.8GB of space is required.\033[0m\n"
		exit 1
	fi

	max_fat_mb=$((total_mb - 1536 - 2))

	fatSize=""
	while true; do
		printf "\033[33mHow many MB of space would you like to reserve for the \033[32mFAT32 Boot files / Homebrew partition\033[33m?\033[0m [default:256, max:%s, q to quit] " "$max_fat_mb"
		read -r fatSz || true
		case "$fatSz" in
			q|Q|quit|Quit) printf "\033[33mInstallation cancelled by user.\033[0m\n"; exit 0 ;;
			*[!0-9]*) printf "\033[1;31mInvalid input!  Please type a number.\033[0m\n"; continue ;;
			'') fatSize="256" ;;
			*)
				# valid number
				fatSize="$fatSz"
		esac
		unset fatSz

		if [ "$fatSize" -lt 256 ]; then
			printf "\033[1;31mThe boot partition must be at least 256 MB!\033[0m\n"
			continue
		fi

		if [ "$fatSize" -gt "$max_fat_mb" ]; then
			printf "\033[1;31mThe requested size leaves less than 1.5GB for the root filesystem!\nMaximum allowed is %s MB.\033[0m\n" "$max_fat_mb"
			continue
		fi

		break
	done

	# Calculate partition size in MB for the confirmation prompt
	fat_mb="$fatSize"

	echo
	printf "\033[1;33m╔════════════════════════════════════════════════════════════╗\033[0m\n"
	printf "\033[1;33m║           \033[1;31mWARNING: DESTRUCTIVE OPERATION\033[1;33m                   ║\033[0m\n"
	printf "\033[1;33m╚════════════════════════════════════════════════════════════╝\033[0m\n"
	echo

	show_disk_info "$sd_blkdev"

	echo
	printf "\033[1;31mThe automatic installer will:\033[0m\n"
	printf '  1. \033[1;31mERASE ALL DATA\033[0m on /dev/%s\n' "$sd_blkdev"
	printf '  2. Create a %sMB FAT32 partition for boot files\n' "$fat_mb"
	printf "  3. Create an ext4 partition using remaining space for rootfs\n"
	printf "  4. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m⚠  ALL EXISTING DATA ON THIS DISK WILL BE PERMANENTLY LOST! ⚠\033[0m\n"
	echo
	printf "Type 'YES' in CAPITAL letters to continue: "
	read -r final_confirm || true

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
	fat_sectors=$((fat_mb * 2048))

	# If the drive was artificially capped at 2TB, sfdisk needs explicit size instructions
	# for the second partition to prevent it from failing by trying to span past the MBR limit.
	if [ "$total_mb" -eq 2097152 ]; then
		root_sectors=$(( (2097152 - fat_mb - 2) * 2048 ))
		cat << EOF | sfdisk "/dev/$sd_blkdev" || { printf "\033[1;31mFATAL ERROR: Failed to partition disk\033[0m\n" >&2; exit 1; }
label: dos
start=2048, size=$fat_sectors, type=c, bootable
type=83, size=$root_sectors
EOF
	else
		# Create partition table with sfdisk
		cat << EOF | sfdisk "/dev/$sd_blkdev" || { printf "\033[1;31mFATAL ERROR: Failed to partition disk\033[0m\n" >&2; exit 1; }
label: dos
start=2048, size=$fat_sectors, type=c, bootable
type=83
EOF
	fi

	echo "Synchronizing partition table with kernel..."
	partprobe "/dev/$sd_blkdev" 2>/dev/null || true
	settle_udev

	# Derive partition names: devices ending in a digit (e.g. mmcblk0, nvme0n1)
	# use a 'p' separator (mmcblk0p1), others just append the number (sda1)
	if echo "$sd_blkdev" | grep -q '[0-9]$'; then
		boot_blkdev="/dev/${sd_blkdev}p1"
		rootfs_blkdev="/dev/${sd_blkdev}p2"
	else
		boot_blkdev="/dev/${sd_blkdev}1"
		rootfs_blkdev="/dev/${sd_blkdev}2"
	fi

	# Wait for partition device nodes to appear; slow SD cards and USB
	# adapters can take a moment after partprobe and device settle.
	echo "Waiting for partitions to initialize..."
	_wait=0
	while [ "$_wait" -lt 10 ]; do
		[ -b "$boot_blkdev" ] && [ -b "$rootfs_blkdev" ] && break
		sleep 1
		_wait=$((_wait + 1))
	done
	if [ ! -b "$boot_blkdev" ] || [ ! -b "$rootfs_blkdev" ]; then
		printf "\033[1;31mFATAL ERROR: Partition device nodes did not appear after partitioning.\033[0m\n" >&2
		exit 1
	fi

	echo "Formatting..."

	fmt_log=$(mktemp)

	{
		set -e
		mkfs.vfat -F 32 "$boot_blkdev"
		mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev"
	} > "$fmt_log" 2>&1 &
	fmt_pid=$!
	_bg_pids="${_bg_pids:+$_bg_pids }$fmt_pid"

	spinner "Formatting partitions"

	ret=0
	wait $fmt_pid || ret=$?

	if [ "$ret" -ne 0 ]; then
		printf "\033[1;31mFailed to format partitions!\033[0m\n"
		echo "--- Error Log ---"
		cat "$fmt_log"
		rm -f "$fmt_log"
		bug_report "Step: loopdev_format" "Return code: $ret" "Boot blkdev: $boot_blkdev" "Root blkdev: $rootfs_blkdev"
	fi
	rm -f "$fmt_log"

	# Wait for the Desktop Environment to notice the new filesystems
	# This prevents crashing due to event flooding
	settle_udev
	sleep 2

	install_boot
	install_root

	do_configure

	unmount_and_cleanup

	# Resume DE monitoring only after partitions are fully unmounted
	toggle_udisks start
}
# ====
# Start of the actual installer process
# ====

if [ "$(id -u)" != "0" ]; then
	printf "\033[1;31mThis installer must be run as root!\033[0m\n"
	exit 1
fi

# Check for optional tools
if ! command -v pv >/dev/null 2>&1; then
	printf "\033[1;33mNote: Install 'pv' for progress bars during extraction\033[0m\n"
	printf "  (This is optional, installation will work without it)\n"
	echo
fi

check_dependencies

echo "We need to gather some info about where you would like to install to..."
rescan_bdevs

printf "\033[33mWe now need to know where your \033[32mSD Card\033[33m is.\033[0m\n"
while ! select_disk; do
	printf "\033[1;31mInvalid option, please try again\033[0m\n"
	rescan_bdevs
done
boot_blkdev="$selection"

select_root_disk

if [ "$separate_sd_and_rootfs" = "false" ]; then
	while true; do
		printf "\033[33mWould you like \033[32m[A]utomatic\033[33m or \033[32m[M]anual\033[33m install?\033[0m "
		read -r doauto || true
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
