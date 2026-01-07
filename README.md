# Wii Linux PC Installer

This tool is designed to install **Wii Linux ArchPOWER** onto an SD Card (and optional USB drive)
from a Linux PC. It handles downloading the necessary files, partitioning the media,
and extracting the filesystem.

For more detailed instructions, please see
[the installation guide](https://wiki.wii-linux.org/wiki/Installation_Guide).

## Important: Read Before Running

This installer performs destructive operations on storage devices. As the script requires
`root` privileges to modify partition tables and filesystems, misuse could damage your host system.
The script will format and erase the device you select. **All data on that device will be
permanently lost**.

You are solely responsible for making sure you select the correct drive (e.g., your SD card, not
your system hard drive). We strongly recommend you read through and understand the steps before
executing the script.

## Features

The installer offers two primary modes of operation. The **Automatic Mode** is designed for fresh
installs; it automatically wipes the target SD card and creates the necessary FAT32 (Boot) and
ext4 (Root) partitions. Alternatively, **Manual Mode** allows you to select specific pre-existing
partitions if you have a custom setup.

To prevent accidents, the script attempts to identify "Removable" devices to help distinguish SD
cards from internal drives. It detects and offers to reuse previously downloaded installation
files to speed up subsequent runs. It also prompts you to configure essential settings such as
the Hostname, SSH, and Network profiles immediately after installation.

## Prerequisites

You will need a Linux system with `root` access. Please install the following dependencies for
your distribution before running the installer.

**Debian / Ubuntu / Linux Mint / Pop!_OS**

```bash
sudo apt update
sudo apt install util-linux e2fsprogs dosfstools wget tar pv parted
```

**Arch Linux / Manjaro / Garuda / CachyOS**

```bash
sudo pacman -Syu util-linux e2fsprogs dosfstools wget tar pv parted
```

**Fedora / RHEL / Bazzite**

```bash
# Note: On immutable systems like Bazzite, run this inside a toolbox or distrobox container
sudo dnf install util-linux e2fsprogs dosfstools wget tar pv parted
```

**Gentoo**

```bash
emerge sys-apps/util-linux sys-fs/e2fsprogs sys-fs/dosfstools net-misc/wget sys-apps/pv sys-block/parted
```

## Usage

1. **Clone the repository:**

   ```bash
   git clone https://github.com/Wii-Linux/pc-installer
   cd pc-installer
   ```

2. **Run the installer:**

   ```bash
   sudo ./installer.sh
   ```

3. **Follow the on-screen prompts.**
   If you are unsure about a step, you can usually type `q` to quit safely. The script will
   attempt to clean up temporary mount points if interrupted.

## Tested Modes

| Installation mode   | Tested?       |
| ------------------- | ------------- |
| Automatic, SD Only  | Working       |
| Automatic, SD + USB | Unimplemented |
| Manual, SD Only     | Working       |
| Manual, SD + USB    | Experimental  |

## Tested Host Distros

| Tester    | Platform                | Testing date | Status  | Additional Notes                  |
| --------- | ----------------------- | ------------ | ------- | --------------------------------- |
| Techflash | Arch Linux (AMD64)      | Dec 03, 2024 | Working | Automatic w/ SD                   |
| Techflash | Debian 12 (BeagleBone)  | Dec 23, 2024 | Working | Manual w/ SD, took a few fixes    |
| Selim     | Ubuntu 24.04 LTS (AMD64)| Dec 19, 2024 | Working | Automatic w/ SD, took a few fixes |

## Troubleshooting

If the script fails with a "Missing required dependencies" error, please ensure you have installed
the packages listed in the Prerequisites section above.

During partitioning, the script temporarily pauses `udisks2` to prevent your desktop environment
from interfering. If the script appears to hang, it is likely just waiting for a safe moment to
proceed or resume the service. Finally, if the automatic formatter fails with loop device errors,
try running `sudo losetup -D` to clear any stuck loop devices before trying again.

## Community & Support

* **Main Website:** [wii-linux.org](https://wii-linux.org/)
* **Wiki:** [Wii-Linux Wiki](https://wiki.wii-linux.org/)
* **Discord:** [Join our Server](https://discord.com/invite/D9EBdRWzv2) for help and discussion.

## License

This program is distributed under the terms of the GNU General Public License version 2 (or later).
You can redistribute it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 2 of the License, or (at your option)
any later version.

Please see the [LICENSE](LICENSE) file for the full text.

## Disclaimer

This project is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
without even the implied warranty of **MERCHANTABILITY** or **FITNESS FOR A PARTICULAR PURPOSE**.
See the [GNU General Public License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
for more details.

**Use at your own risk.** By using this software, you acknowledge that you understand the risks
involved in disk partitioning and formatting. The authors are not responsible for data loss,
hardware damage, or system instability resulting from the use of this software.
