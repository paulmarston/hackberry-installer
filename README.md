# hackberry-installer

Installers for the [HackberryPi CM5](https://github.com/ZitaoTech/HackberryPiCM5) handheld
(Raspberry Pi Compute Module 5, 720×720 screen, built-in keyboard). Each one installs a complete,
working system onto the device's NVMe drive or a USB disk, starting from the SD card the device
boots.

| Installer | What you get |
| --- | --- |
| [`hackberry-ubuntu-phosh.sh`](hackberry-ubuntu-phosh.sh) | Ubuntu 26.04.1 Desktop with the Phosh shell, no snap, Chromium from Flathub |

> **Status: beta.** The installer has run end to end many times on a HackberryPi CM5, against a
> test disk. It has not yet been booted from a real NVMe or USB disk by anyone else. If you try
> it, please [open an issue](../../issues) with how it went, good or bad.

## hackberry-ubuntu-phosh

### What it sets up

- **Ubuntu 26.04.1 Desktop:** Ubuntu's own Raspberry Pi image. Its hash is pinned, and the script
  checks Ubuntu's signature on it. It is then fully updated.
- **Hackberry drivers, built from source on the device:**
  - the screen, touch and battery gauge overlay
  - the keyboard and trackpad (the USB port in host mode)
  - the battery gauge driver, rebuilt by DKMS on every kernel update
- **Phosh:** the phone shell, which suits the 720×720 square screen far better than GNOME. GNOME
  is still available from the login screen's gear button.
- **No snap:**
  - every snap and `snapd` are removed, and an apt pin keeps snap from coming back
  - Chromium comes from Flathub and is the default browser
- **A black screensaver instead of screen blanking:** see [why](docs/hardware-notes.md#never-blank-the-screen).
  - It starts after 5 minutes idle, and a touch or key wakes it.
  - The **Screensaver** icon in the app grid switches it on and off.
  - The lock screen is never blanked either.
- **Quick shutdowns:** a Phosh login no longer holds up shutdown for 90 seconds.
- **Your user:** one user, `berry` by default, with sudo (no password needed). Its password is
  generated and saved in a `.env` file next to the script. Your Wi-Fi networks are copied from the
  SD card. ssh (keys only) is set up from `--ssh-key FILE`, or by default from your own
  `~/.ssh/authorized_keys` on the SD card if you have one.
- **Bluetooth speaker:** a helper reconnects your speaker at login.

### Disk layout

The target disk is **erased** and laid out as:

| Partition | Size | Holds |
| --- | --- | --- |
| 1 | 2 GB | FAT32 boot |
| 2 | 32 GB (`--root-size`) | `/` |
| 3 | 32 GB (`--home-size`) | `/home` |
| 4 | 16 GB (`--swap-size`) | swap |
| rest | — | left free |

### You need

- A HackberryPi CM5, booted from an SD card. The Raspberry Pi OS card it ships with works, as does
  any arm64 Debian or Ubuntu.
- The NVMe drive or USB disk you want to install to. Everything on it will be lost.
- Network on the SD system. The install downloads about 3 GB for the Ubuntu image, plus about
  1.5 GB of updates and Chromium.
- About 45 minutes. Most of it is downloading and updating.

### Install

1. Boot the device from its SD card and connect to Wi-Fi. The networks saved here are copied to
   the new system.
2. Get this repository onto the device. The script needs the whole folder: it reads the driver
   source and Ubuntu's signing key from `vendor/`.

   ```bash
   git clone https://github.com/paulmarston/hackberry-installer.git
   cd hackberry-installer
   ```

3. Check the plan. A dry run changes nothing:

   ```bash
   sudo ./hackberry-ubuntu-phosh.sh --target nvme --wipe /dev/nvme0n1 --dry-run
   ```

   For a USB disk, use `--target usb` and the disk the dry run names, for example
   `--wipe /dev/sda`. `lsblk` lists your disks.
4. Run it:

   ```bash
   sudo ./hackberry-ubuntu-phosh.sh --target nvme --wipe /dev/nvme0n1 --country GB
   ```

   Use your own two-letter Wi-Fi country code. The new user's password is generated and saved in
   `.env` in this folder, as `HACKBERRY_USER` and `HACKBERRY_PASSWORD`, along with the host name,
   the disk and the install time. Each run rewrites the whole file, so copy it first if you want
   to keep an earlier one, or use `--env-file`. The file is readable only
   by you, and the password is never printed. `cat .env` shows it when you need it. Keep the file:
   a second run for the same user reuses the password. If you'd rather choose the password, use
   `--ask-password`, or pipe it in. Other options:
   - `--user NAME`, or `sudo HACKBERRY_USER=NAME ./hackberry-ubuntu-phosh.sh …` (default: the
     user already in `.env`, else `berry`)
   - `--hostname NAME` (default `hackberry`)
   - `--ssh-key FILE` (default: your own `~/.ssh/authorized_keys`, if any; with neither, no ssh)
   - `--session ubuntu` to make GNOME the default

   `--help` lists the rest.
5. When it prints **Done**, power off, take the SD card out and power on. The first boot reboots
   once by itself, to switch to the newest kernel the install fetched.
6. Log in with the user and password from the SD card (see [Your login](#your-login)). Phosh is
   the default session.

### Your login

Unless you chose the password yourself, the installer generates it. It saves it in two places
on the SD card you ran it from, and never prints it:

| Where | How to read it |
| --- | --- |
| `.env` in the `hackberry-installer` folder (mode 600) | On the SD system: `cat ~/hackberry-installer/.env`. The user and password are `HACKBERRY_USER` and `HACKBERRY_PASSWORD`. |
| `hackberry-login.txt` on the SD card's boot partition | Put the SD card in any computer. The boot partition (`bootfs` on Raspberry Pi OS) opens on macOS and Windows; open the file there. |

**Delete `hackberry-login.txt` once you've logged in.** The boot partition is FAT, which has no
file permissions, so anyone holding the card can read it. Keep `.env` if you might run the
installer again: a second run for the same user reuses the password. To skip the boot-partition
copy, use `--no-login-copy`. To change the password later, run `passwd` on the new system.

### After installing

- **Bluetooth speaker:** pair and trust it in Settings → Bluetooth. Then add its address to
  `~/.config/hackberry/bt-speakers`, one per line, and it will reconnect at every login.
- **Screensaver:** tap **Screensaver** in the app grid to switch it on or off. From a terminal,
  `hackberry-screensaver on|off|status` does the same.
- **Lock:** press Super+L. The device never locks by itself.
- **Updates:** `sudo apt update && sudo apt full-upgrade` for the system, `flatpak update` for
  Chromium. Kernel updates rebuild the battery driver by themselves.

### Booting

The CM5's bootloader tries the SD card, then the NVMe, then USB, in that order (`BOOT_ORDER=0xf2461`).

- **NVMe install:** take the SD card out to boot it.
- **USB install:** boots only when the SD card is out and the NVMe has no boot partition, unless you
  change the boot order with `sudo rpi-eeprom-config --edit`.

The installer never changes the bootloader.

### Safety

The script refuses to:
- erase the SD card it is running from
- erase a disk that has mounted partitions or swap in use
- erase a disk whose type doesn't match `--target` (an NVMe given as `--target usb`, for example)
- erase anything without `--wipe` naming the same disk

Names under `/dev/disk/by-id/` are resolved to the real disk first.

## Hardware notes

[`docs/hardware-notes.md`](docs/hardware-notes.md) covers what this installer works around, and
why. It's useful if you're building your own HackberryPi CM5 system.

## Credits and licence

- **Battery driver and panel overlay:** from [CNflysky/hackberrypiq20](https://github.com/CNflysky/hackberrypiq20),
  vendored at a pinned commit in [`vendor/hackberrypi-max17048/`](vendor/hackberrypi-max17048/).
- **Ubuntu's image signing key:** [`vendor/ubuntu-cdimage-signing-key.asc`](vendor/ubuntu-cdimage-signing-key.asc),
  exported from Ubuntu's `ubuntu-archive-keyring`. The script checks its fingerprint,
  `843938DF228D22F7B3742BC0D94AA3F0EFE21092`.

The scripts are GPL-3.0-or-later and the vendored driver keeps its upstream GPL-3.0 licence (see
[LICENSE](LICENSE)). `vendor/ubuntu-cdimage-signing-key.asc` is Ubuntu's public key, included
unchanged.
