#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# hackberry-ubuntu-phosh.sh: install Ubuntu 26.04.1 Desktop with Phosh on a HackberryPi CM5's NVMe
# or a USB disk. https://github.com/paulmarston/hackberry-installer . Run as root
# from the SD card the device boots (the Raspberry Pi OS it ships with, or any arm64 Debian or
# Ubuntu). Everything on the target disk is erased.
#
# What you get:
#   - Ubuntu's own raspi image (hash pinned, Ubuntu's signature checked), fully updated
#   - Hackberry drivers built from the source next to this script: the 720x720 panel, touch and
#     battery gauge overlay; host-mode USB for the keyboard and trackpad; the
#     battery gauge driver through DKMS, rebuilt on every kernel update
#   - no snap (removed and blocked); Chromium from Flathub as the browser
#   - Phosh, the default session (GNOME stays at the login screen's gear button)
#   - a black screensaver instead of blanking (a "Screensaver" icon switches it on and off):
#     this panel shows a lit halo once its video signal stops, until a power cycle
#   - one user with passwordless sudo, ssh with keys only (if a key is given), the Wi-Fi
#     networks of the running system, a swap partition
#
# Layout (GPT): p1 2G FAT boot, p2 root, p3 /home, p4 swap, the rest left free.
set -Eeuo pipefail
trap 'echo "hackberry-ubuntu-phosh: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

VERSION=1
IMG_URL=https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-preinstalled-desktop-arm64+raspi.img.xz
IMG_SHA=8216f54cc1df2fcf7de37530a7edccdd200abd7dcfbc5d4f0407df7513544d6a
SUMS_URL=https://cdimage.ubuntu.com/releases/26.04.1/release/SHA256SUMS
UBUNTU_KEY_FPR=843938DF228D22F7B3742BC0D94AA3F0EFE21092
DRV_NAME=hackberrypi-max17048 DRV_VER=1.1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: sudo hackberry-ubuntu-phosh.sh --target nvme|usb --wipe DEVICE [options]

Install Ubuntu Desktop with Phosh on the NVMe or a USB disk of a HackberryPi CM5. Run it from the
SD card the device has booted. DEVICE is erased.

Required:
  --target nvme|usb    where the OS goes; the disk is found for you (one USB disk only)
  --wipe DEVICE        the disk to erase, repeated to confirm, e.g. --wipe /dev/nvme0n1

Options:
  --device DEVICE      use this disk instead of the one --target finds
  --user NAME          the user (default: HACKBERRY_USER, else the one in .env, else berry);
                       passwordless sudo
  --hostname NAME      (default: hackberry)
  --country CC         Wi-Fi country, e.g. GB (default: the running system's, if set)
  --ssh-key FILE       authorized_keys for the user; turns on ssh, keys only
                       (default: the invoking user's ~/.ssh/authorized_keys, if any)
  --no-wifi            don't copy the running system's Wi-Fi networks
  --session phosh|ubuntu  the default session at the login screen (default: phosh)
  --root-size SIZE     (default: 32G)   --home-size SIZE (default: 32G)   --swap-size SIZE (16G)
  --images DIR         keep the downloaded image here for another run (default: on the target,
                       deleted at the end)
  --driver-src DIR     the Hackberry driver source (default: vendor/hackberrypi-max17048 here)
  --env-file FILE      where the new user's password is kept (default: .env next to this script)
  --ask-password       type the password instead of having one generated
  --no-login-copy      don't also write hackberry-login.txt to the SD card's FAT boot partition
  --dry-run            check everything and print the plan; change nothing
  -h, --help           --version

The new user's password: one line on stdin if piped; else, for the same user, the one already
in the .env file; else a new random one. It is saved in the .env file (mode 600, owned by you,
never printed) as HACKBERRY_USER and HACKBERRY_PASSWORD, so you can log in to the new system,
with the host name, disk and install time. Each run rewrites the whole file. A copy goes to the
SD card's FAT boot partition as hackberry-login.txt, readable on macOS and Windows: delete it
once you have logged in (FAT has no permissions).

Examples:
  sudo ./hackberry-ubuntu-phosh.sh --target nvme --wipe /dev/nvme0n1 --dry-run
  sudo ./hackberry-ubuntu-phosh.sh --target nvme --wipe /dev/nvme0n1 --country GB   # password in .env
  sudo HACKBERRY_USER=alex ./hackberry-ubuntu-phosh.sh --target usb --wipe /dev/sda --ask-password
  sudo ./hackberry-ubuntu-phosh.sh --target usb --wipe /dev/sda --hostname hackberry-usb

Boot: the bootloader tries SD, then NVMe, then USB (BOOT_ORDER 0xf2461, the CM5 default). Take
the SD card out to boot the NVMe; a USB install boots only when the SD card is out and the NVMe
has no boot partition, unless you change BOOT_ORDER (rpi-eeprom-config --edit). This script
never changes the bootloader.
EOF
}

die() { echo "hackberry-ubuntu-phosh: $*" >&2; exit 1; }
need() { (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "$1 needs a value"; }
say() { echo "==> $*"; }

TARGET='' DEVICE='' WIPE='' USERNAME='' ENVFILE='' ASKPW=0 LOGINCOPY=1 HOST=hackberry COUNTRY='' SSHKEY='' WIFI=1 SESSION=phosh
ROOT_SIZE=32G HOME_SIZE=32G SWAP_SIZE=16G IMAGES='' DRV_SRC=$HERE/vendor/hackberrypi-max17048 DRY=0
while (($#)); do
  case $1 in
    --target) need "$@"; TARGET=$2; shift ;;
    --device) need "$@"; DEVICE=$2; shift ;;
    --wipe) need "$@"; WIPE=$2; shift ;;
    --user) need "$@"; USERNAME=$2; shift ;;
    --hostname) need "$@"; HOST=$2; shift ;;
    --country) need "$@"; COUNTRY=$2; shift ;;
    --ssh-key) need "$@"; SSHKEY=$2; shift ;;
    --no-wifi) WIFI=0 ;;
    --session) need "$@"; SESSION=$2; shift ;;
    --root-size) need "$@"; ROOT_SIZE=$2; shift ;;
    --home-size) need "$@"; HOME_SIZE=$2; shift ;;
    --swap-size) need "$@"; SWAP_SIZE=$2; shift ;;
    --images) need "$@"; IMAGES=$2; shift ;;
    --driver-src) need "$@"; DRV_SRC=$2; shift ;;
    --env-file) need "$@"; ENVFILE=$2; shift ;;
    --ask-password) ASKPW=1 ;;
    --no-login-copy) LOGINCOPY=0 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) usage >&2; die "unknown option '$1'" ;;
  esac
  shift
done
# the .env file next to this script keeps the new user's login; the user name comes from --user,
# then HACKBERRY_USER, then the .env file, then 'berry'
ENVFILE=${ENVFILE:-$HERE/.env}
envget() { [[ -f $ENVFILE ]] && sed -n "s/^$1=//p" "$ENVFILE" | tail -1 | sed -E "s/^['\"](.*)['\"]$/\1/"; true; }
[[ -n $USERNAME ]] || USERNAME=${HACKBERRY_USER:-$(envget HACKBERRY_USER)}
USERNAME=${USERNAME:-berry}
# a /dev/disk/by-id or by-path name is a link: work with the kernel name (/dev/sda, /dev/nvme0n1)
[[ -n $DEVICE ]] && DEVICE=$(readlink -f -- "$DEVICE")
[[ -n $WIPE ]] && WIPE=$(readlink -f -- "$WIPE")

# --- checks ----------------------------------------------------------------------------------

[[ $(id -u) == 0 ]] || die "run as root (sudo)"
[[ $TARGET == nvme || $TARGET == usb ]] || { usage >&2; die "--target nvme or --target usb is required"; }
[[ $SESSION == phosh || $SESSION == ubuntu ]] || die "--session is phosh or ubuntu"
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--user '$USERNAME' is not a valid user name"
[[ $HOST =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "--hostname '$HOST' is not a valid host name"
[[ $(uname -m) == aarch64 ]] || die "run this on the HackberryPi CM5 itself (aarch64)"
grep -qa 'Compute Module 5' /proc/device-tree/model 2>/dev/null || die "this is not a Raspberry Pi CM5 ($(tr -d '\0' </proc/device-tree/model 2>/dev/null))"
ROOTSRC=$(findmnt -no SOURCE /)
[[ $ROOTSRC == /dev/mmcblk0* || ${HACKBERRY_ANY_ROOT:-0} == 1 ]] || die "run this from the SD card (/ is ${ROOTSRC})"
UBUNTU_KEY=$HERE/vendor/ubuntu-cdimage-signing-key.asc
[[ -s $UBUNTU_KEY ]] || die "missing $UBUNTU_KEY (copy the whole folder, not just this script)"
for f in hackberrypicm5.dts hackberrypi-max17048.c Makefile dkms.conf LICENSE; do
  [[ -f $DRV_SRC/$f ]] || die "driver source missing: $DRV_SRC/$f (copy the whole folder, not just this script)"
done

if [[ -z $DEVICE ]]; then
  if [[ $TARGET == nvme ]]; then
    DEVICE=/dev/nvme0n1
  else
    mapfile -t usb < <(lsblk -dnpo NAME,TRAN | awk '$2=="usb"{print $1}')
    ((${#usb[@]} == 1)) || die "found ${#usb[@]} USB disks (${usb[*]:-none}); name one with --device"
    DEVICE=${usb[0]}
  fi
fi
[[ -b $DEVICE ]] || die "$DEVICE is not a block device"
[[ $(lsblk -dno TYPE "$DEVICE") == disk || ($(lsblk -dno TYPE "$DEVICE") == loop && ${HACKBERRY_ANY_ROOT:-0} == 1) ]] \
  || die "$DEVICE is not a whole disk"
if [[ $(lsblk -dno TYPE "$DEVICE") != loop ]]; then
  tran=$(lsblk -dno TRAN "$DEVICE" | xargs)
  [[ $tran == "$TARGET" ]] || die "$DEVICE is a ${tran:-unknown}-attached disk, not $TARGET (--target $TARGET)"
fi
[[ $WIPE == "$DEVICE" ]] || die "--wipe $DEVICE is required to erase $DEVICE (got '${WIPE:-nothing}')"
[[ $ROOTSRC != "$DEVICE"* ]] || die "$DEVICE holds the running system"
if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -q .; then
  die "$DEVICE has mounted partitions: $(lsblk -nro NAME,MOUNTPOINTS "$DEVICE" | awk 'NF>1' | tr '\n' ' ')"
fi
grep -q "^${DEVICE}" /proc/swaps && die "$DEVICE has swap in use (swapoff first)"
p() { [[ $DEVICE =~ [0-9]$ ]] && echo "${DEVICE}p$1" || echo "${DEVICE}$1"; }
bytes() { numfmt --from=iec "${1%B}"; }
need=$(( $(bytes 2G) + $(bytes "$ROOT_SIZE") + $(bytes "$HOME_SIZE") + $(bytes "$SWAP_SIZE") + $(bytes 64M) ))
have=$(blockdev --getsize64 "$DEVICE")
(( have >= need )) || die "$DEVICE has $(numfmt --to=iec "$have"), the layout needs $(numfmt --to=iec "$need")"
(( $(bytes "$ROOT_SIZE") >= $(bytes 16G) )) || die "--root-size must be at least 16G"
(( $(bytes "$HOME_SIZE") >= $(bytes 14G) )) || [[ -n $IMAGES ]] || die "--home-size under 14G needs --images (the image is unpacked in /home)"

if [[ -z $COUNTRY ]]; then
  COUNTRY=$(grep -o 'cfg80211.ieee80211_regdom=[A-Z][A-Z]' /proc/cmdline | cut -d= -f2 || true)
  [[ -n $COUNTRY ]] || COUNTRY=$( (iw reg get 2>/dev/null || true) | awk '/^country/{sub(":","",$2); print $2; exit}')
  [[ $COUNTRY == 00 ]] && COUNTRY=
fi
[[ -z $COUNTRY || $COUNTRY =~ ^[A-Z]{2}$ ]] || die "--country is two capital letters, e.g. GB"
if [[ -z $SSHKEY ]]; then
  inv=${SUDO_USER:-}; h=$( [[ -n $inv ]] && getent passwd "$inv" | cut -d: -f6 || true)
  [[ -n $h && -s $h/.ssh/authorized_keys ]] && SSHKEY=$h/.ssh/authorized_keys
fi
[[ -z $SSHKEY || -s $SSHKEY ]] || die "--ssh-key $SSHKEY is empty or missing"
# saved networks: NetworkManager keyfiles, Ubuntu's netplan files NetworkManager moves them into,
# and the netplan file Raspberry Pi Imager's Wi-Fi setting becomes on Pi OS Trixie (cloud-init);
# the new Ubuntu reads all three
wifi=() plan=()
if ((WIFI)); then
  for f in /etc/NetworkManager/system-connections/*.nmconnection; do [[ -f $f ]] && wifi+=("$f"); done
  for f in /etc/netplan/90-NM-*.yaml /etc/netplan/50-cloud-init.yaml; do [[ -f $f ]] && plan+=("$f"); done
fi

cat <<EOF
Plan (hackberry-ubuntu-phosh $VERSION):
  erase     $DEVICE ($(lsblk -dno MODEL,SIZE "$DEVICE" | xargs), $TARGET)
  layout    $(p 1) 2G boot, $(p 2) ${ROOT_SIZE} root, $(p 3) ${HOME_SIZE} /home, $(p 4) ${SWAP_SIZE} swap, rest free
  image     $(basename "$IMG_URL") (sha256 ${IMG_SHA:0:12}…, signed by ${UBUNTU_KEY_FPR})
  system    host ${HOST}, user ${USERNAME} (passwordless sudo), session ${SESSION}, Wi-Fi country ${COUNTRY:-not set}
  ssh       $([[ -n $SSHKEY ]] && echo "keys only, from ${SSHKEY}" || echo "not installed (no key)")
  networks  $(( ${#wifi[@]} + ${#plan[@]} )) saved connection(s) from this system
  password  $( ((ASKPW)) && echo typed || { [[ ! -t 0 ]] && echo "piped if given, else the one in ${ENVFILE} or a new one; saved to ${ENVFILE}" || { [[ $(envget HACKBERRY_USER) == "$USERNAME" && -n $(envget HACKBERRY_PASSWORD) ]] && echo "the one in ${ENVFILE}" || echo "generated; saved to ${ENVFILE}"; }; })
EOF
((DRY)) && { echo "dry run: nothing changed"; exit 0; }

PW='' PWSRC=''
if ((ASKPW)); then
  [[ -t 0 ]] || die "--ask-password needs a terminal"
  read -rsp "Password for ${USERNAME}: " PW; echo; read -rsp "Again: " PW2; echo
  [[ $PW == "$PW2" ]] || die "the passwords differ"; unset PW2; PWSRC=typed
elif [[ ! -t 0 ]]; then
  IFS= read -r PW || true; [[ -n $PW ]] && PWSRC=stdin
fi
if [[ -z $PW && $(envget HACKBERRY_USER) == "$USERNAME" ]]; then
  PW=$(envget HACKBERRY_PASSWORD); [[ -n $PW ]] && PWSRC=$ENVFILE
fi
if [[ -z $PW ]]; then
  PW=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20); PWSRC=generated
fi
[[ ${#PW} -ge 8 ]] || die "the password must be at least 8 characters"
# keep the login next to this script (written before anything is erased), never printed
( umask 077
  { echo "# hackberry-ubuntu-phosh: the login for the system installed on ${DEVICE}. Keep this file private."
    printf 'HACKBERRY_USER=%s\nHACKBERRY_PASSWORD=%s\nHACKBERRY_HOSTNAME=%s\nHACKBERRY_DEVICE=%s\nHACKBERRY_INSTALLED=%s\n' \
      "$USERNAME" "$PW" "$HOST" "$DEVICE" "$(date -u +%FT%TZ)"
  } >"$ENVFILE.new" && mv "$ENVFILE.new" "$ENVFILE" )
[[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$ENVFILE"
say "password for ${USERNAME}: ${PWSRC}, saved in ${ENVFILE}"
# and a copy on the SD card's FAT boot partition, which macOS and Windows can read
if ((LOGINCOPY)); then
  fat=''
  for m in /boot/firmware /boot; do
    [[ $(findmnt -no FSTYPE "$m" 2>/dev/null) == vfat ]] && { fat=$m; break; }
  done
  if [[ -n $fat ]]; then
    { printf '%s\r\n' "HackberryPi login for the system installed by hackberry-ubuntu-phosh on ${DEVICE} ($(date -u +%F))." \
        "Delete this file once you have logged in: anyone with this SD card can read it." ""
      grep -E '^HACKBERRY_(USER|PASSWORD|HOSTNAME)=' "$ENVFILE" | sed -e 's/^HACKBERRY_USER=/user:     /' \
        -e 's/^HACKBERRY_PASSWORD=/password: /' -e 's/^HACKBERRY_HOSTNAME=/host:     /' -e 's/$/\r/'
    } >"$fat/hackberry-login.txt" && sync && say "a copy for macOS and Windows: hackberry-login.txt on the SD card's boot partition"
  else
    say "no FAT boot partition mounted here; the login is only in ${ENVFILE}"
  fi
fi

# --- tools on the running system --------------------------------------------------------------

say "tools: gdisk, dosfstools, rsync, xz, dtc, curl, gpg"
missing=()
for t in sgdisk:gdisk mkfs.vfat:dosfstools mkfs.ext4:e2fsprogs rsync:rsync xz:xz-utils dtc:device-tree-compiler \
         curl:curl gpg:gpg partprobe:parted losetup:mount; do
  command -v "${t%%:*}" >/dev/null || missing+=("${t#*:}")
done
((${#missing[@]})) && { apt-get update -q && apt-get install -y -q --no-install-recommends "${missing[@]}" ca-certificates; }

# --- partition --------------------------------------------------------------------------------

W=/mnt/hackberry-target S=/mnt/hackberry-src L=''
cleanup() {
  set +e; trap - ERR
  rm -f "$W/usr/sbin/policy-rc.d" 2>/dev/null
  umount -R "$S.boot" "$S" 2>/dev/null; [[ -n $L ]] && losetup -d "$L" 2>/dev/null
  umount -R "$W" 2>/dev/null
}
trap cleanup EXIT

say "erasing and partitioning $DEVICE"
wipefs -aq "$DEVICE"
sgdisk --zap-all "$DEVICE" >/dev/null; sgdisk -o "$DEVICE" >/dev/null
sgdisk -n "1:0:+2G" -t "1:0700" -c "1:hackberry-boot" \
       -n "2:0:+${ROOT_SIZE}" -t "2:8300" -c "2:hackberry-root" \
       -n "3:0:+${HOME_SIZE}" -t "3:8302" -c "3:hackberry-home" \
       -n "4:0:+${SWAP_SIZE}" -t "4:8200" -c "4:hackberry-swap" "$DEVICE" >/dev/null
partprobe "$DEVICE" 2>/dev/null || partx -u "$DEVICE"; udevadm settle
# a FAT32 boot partition first: the bootloader boots it with no autoboot.txt switching
mkfs.vfat -F 32 -n HB-BOOT "$(p 1)" >/dev/null
mkfs.ext4 -q -F -L hb-root "$(p 2)"; mkfs.ext4 -q -F -L hb-home "$(p 3)"
mkswap -q -L hb-swap "$(p 4)"
pu() { blkid -s PARTUUID -o value "$(p "$1")"; }
mkdir -p "$W"; mount "$(p 2)" "$W"; mkdir -p "$W/boot/firmware" "$W/home"
mount "$(p 1)" "$W/boot/firmware"; mount "$(p 3)" "$W/home"

# --- image ------------------------------------------------------------------------------------

STAGE=${IMAGES:-$W/home/.hackberry-image}; [[ -d $STAGE ]] || install -d -m 0700 "$STAGE"
xzf=$STAGE/$(basename "$IMG_URL")
if [[ ! -s $xzf ]] || ! echo "$IMG_SHA  $xzf" | sha256sum -c --quiet - 2>/dev/null; then
  say "downloading $(basename "$IMG_URL") (about 3 GB)"
  if [[ -t 1 ]]; then pr=(--progress-bar); else pr=(-sS); fi
  curl -fL --retry 3 "${pr[@]}" -o "$xzf.part" "$IMG_URL"; mv "$xzf.part" "$xzf"
fi
echo "$IMG_SHA  $xzf" | sha256sum -c --quiet - || { rm -f "$xzf"; die "image checksum mismatch (removed)"; }
say "checking Ubuntu's signature on SHA256SUMS"
g=$(mktemp -d)
curl -fsSL -o "$g/SHA256SUMS" "$SUMS_URL"; curl -fsSL -o "$g/SHA256SUMS.gpg" "$SUMS_URL.gpg"
# Ubuntu's CD image signing public key ships next to this script (exported from Ubuntu's own
# ubuntu-archive-keyring); trust comes from the pinned fingerprint, which the signature must match
GNUPGHOME=$g gpg -q --batch --import "$UBUNTU_KEY" 2>/dev/null || die "could not import $UBUNTU_KEY"
GNUPGHOME=$g gpg -q --batch --status-fd 1 --verify "$g/SHA256SUMS.gpg" "$g/SHA256SUMS" 2>/dev/null \
  | grep -q "VALIDSIG $UBUNTU_KEY_FPR" || die "Ubuntu's SHA256SUMS signature is not valid"
grep -q "^$IMG_SHA \*$(basename "$IMG_URL")$" "$g/SHA256SUMS" || die "the pinned hash is not in Ubuntu's signed SHA256SUMS"
rm -rf "$g"
img=${xzf%.xz}
[[ -s $img ]] || { say "unpacking the image"; xz -dkT0 "$xzf"; }

say "copying the image's files onto the new filesystems"
L=$(losetup -fPr --show "$img")
[[ $(blkid -s TYPE -o value "${L}p1") == vfat && $(blkid -s TYPE -o value "${L}p2") == ext4 ]] || die "unexpected image layout"
mkdir -p "$S" "$S.boot"; mount -o ro "${L}p2" "$S"; mount -o ro "${L}p1" "$S.boot"
rsync -aHAX --numeric-ids --exclude=/boot/firmware/ --exclude=/home/ "$S/" "$W/"
rsync -aHAX --numeric-ids "$S/home/" "$W/home/"
rsync -rt --modify-window=2 "$S.boot/" "$W/boot/firmware/"
umount "$S.boot" "$S"; losetup -d "$L"; L=
[[ -z $IMAGES ]] && rm -rf "$STAGE"

cat >"$W/etc/fstab" <<EOF
# hackberry-ubuntu-phosh.sh: Ubuntu + Phosh on ${DEVICE} (${TARGET})
PARTUUID=$(pu 2)  /               ext4  discard    0 1
PARTUUID=$(pu 1)  /boot/firmware  vfat  defaults   0 1
PARTUUID=$(pu 3)  /home           ext4  defaults   0 2
PARTUUID=$(pu 4)  none            swap  sw,nofail  0 0
EOF
for c in "$W"/boot/firmware/cmdline.txt "$W"/boot/firmware/*/cmdline.txt; do
  [[ -f $c ]] || continue
  sed -i -E "s#root=[^ ]+#root=PARTUUID=$(pu 2)#" "$c"
  [[ -n $COUNTRY ]] && ! grep -q 'cfg80211.ieee80211_regdom=' "$c" && sed -i "s/\$/ cfg80211.ieee80211_regdom=${COUNTRY}/" "$c"
done
B=$W/boot/firmware

# --- chroot -----------------------------------------------------------------------------------

for d in proc sys dev dev/pts run; do mkdir -p "$W/$d"; done
mount -t proc proc "$W/proc"; mount -t sysfs sys "$W/sys"; mount --bind /dev "$W/dev"; mount --bind /dev/pts "$W/dev/pts"
mount -t tmpfs tmpfs "$W/run"; mkdir -p "$W/run/systemd/resolve"; cp -L /etc/resolv.conf "$W/run/systemd/resolve/stub-resolv.conf"
printf '#!/bin/sh\nexit 101\n' >"$W/usr/sbin/policy-rc.d"; chmod 0755 "$W/usr/sbin/policy-rc.d"
inr() { chroot "$W" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 "$@"; }
apt_in() { inr apt-get -y -q -o Dpkg::Options::=--force-confold "$@"; }

say "first-boot setup off (cloud-init, GNOME's initial setup), host name ${HOST}"
echo "$HOST" >"$W/etc/hostname"
sed -i -E '/^127\.0\.1\.1\s/d' "$W/etc/hosts"; printf '127.0.1.1\t%s\n' "$HOST" >>"$W/etc/hosts"
touch "$W/etc/cloud/cloud-init.disabled"
grep -q '^InitialSetupEnable' "$W/etc/gdm3/custom.conf" || sed -i 's/^\[daemon\]$/[daemon]\nInitialSetupEnable=false/' "$W/etc/gdm3/custom.conf"

say "Hackberry overlay from ${DRV_SRC}, host-mode USB for the keyboard"
install -d "$W/usr/local/share/hackberry"
dtc -q -I dts -O dtb -o "$W/usr/local/share/hackberry/hackberrypicm5.dtbo" "$DRV_SRC/hackberrypicm5.dts"
install -d "$W/etc/kernel/postinst.d"
install -m 0755 /dev/stdin "$W/etc/kernel/postinst.d/zz-hackberry-overlay" <<'EOF'
#!/bin/sh
# hackberry-ubuntu-phosh: keep the HackberryPi CM5 overlay where flash-kernel and the firmware look
o=/usr/local/share/hackberry/hackberrypicm5.dtbo
[ -n "$1" ] && [ -d "/lib/firmware/$1/device-tree/overlays" ] && install -m 0644 "$o" "/lib/firmware/$1/device-tree/overlays/"
for d in /boot/firmware/current/overlays /boot/firmware/new/overlays; do [ -d "$d" ] && install -m 0644 "$o" "$d/"; done
exit 0
EOF
overlay_everywhere() {
  for d in "$B/current/overlays" "$B/new/overlays" "$W"/lib/firmware/*/device-tree/overlays; do
    [[ -d $d ]] && install -m 0644 "$W/usr/local/share/hackberry/hackberrypicm5.dtbo" "$d/"
  done; true
}
overlay_everywhere

say "updating Ubuntu (a newer kernel boots after one automatic test reboot, Ubuntu's piboot-try)"
apt_in update
apt_in full-upgrade

say "no snap: every snap and snapd removed, snapd blocked"
apt_in purge snapd firefox 2>/dev/null || apt_in purge snapd
rm -rf "$W/snap" "$W/var/snap" "$W/var/lib/snapd" "$W/var/cache/snapd" "$W"/home/*/snap "$W/root/snap"
printf 'Package: snapd\nPin: release a=*\nPin-Priority: -10\n' >"$W/etc/apt/preferences.d/no-snap.pref"
# no apt-mark hold: with snapd purged and pinned to -10 there is no version to hold, and the pin
# alone stops apt from ever installing it
inr dpkg-query -W ubuntu-desktop-minimal >/dev/null || die "removing snapd took the desktop with it"

say "Phosh, Flatpak, the screensaver's parts, ssh, the battery driver's build tools"
pk=(phosh-core phosh-mobile-settings flatpak xdg-desktop-portal-gnome swayidle python3-gi
    gir1.2-gtk4layershell-1.0 libgtk4-layer-shell0 dkms build-essential linux-headers-raspi)
[[ -n $SSHKEY ]] && pk+=(openssh-server)
# headers for every installed kernel, so the fallback in current/ has the battery gauge too
for kd in "$W"/lib/modules/*/; do
  k=$(basename "$kd")
  inr dpkg-query -W -f='${Status}' "linux-image-$k" 2>/dev/null | grep -q 'ok installed' && pk+=("linux-headers-$k")
done
apt_in install --no-install-recommends "${pk[@]}"

say "battery gauge driver from source (DKMS)"
rm -rf "$W/usr/src/${DRV_NAME}-${DRV_VER}"; install -d "$W/usr/src/${DRV_NAME}-${DRV_VER}"
install -m 0644 "$DRV_SRC"/{hackberrypi-max17048.c,Makefile,dkms.conf,hackberrypicm5.dts,LICENSE} "$W/usr/src/${DRV_NAME}-${DRV_VER}/"
inr dkms add -m "$DRV_NAME" -v "$DRV_VER" >/dev/null 2>&1 || true
built=0
for kd in "$W"/lib/modules/*/; do
  k=$(basename "$kd"); [[ -e $kd/build ]] || continue
  inr dkms install -m "$DRV_NAME" -v "$DRV_VER" -k "$k" >/dev/null && built=1 && echo "    built for $k"
done
((built)) || say "battery driver NOT built (no kernel headers matched); the gauge will be missing"
overlay_everywhere

# flash-kernel does nothing in a chroot unless forced, so the upgrade's kernel never reached the
# boot partition. Forced, it writes the newest kernel to new/ (state "unknown"); on first boot
# Ubuntu's piboot-try reboots once into it and, once it boots, makes it current/.
newest=$(basename "$(printf '%s\n' "$W"/lib/modules/*/ | sort -V | tail -1)")
say "boot partition: kernel ${newest} into new/ (the image's kernel stays in current/ as the fallback)"
inr /usr/bin/env FK_FORCE=yes flash-kernel "$newest" >/dev/null 2>&1 || die "flash-kernel could not install ${newest}"
overlay_everywhere
[[ $(cat "$B/new/state" 2>/dev/null) == unknown ]] || say "warning: no new/ boot assets for ${newest}; the image's kernel will boot"

say "config.txt: keyboard in host mode, the panel's GPIO pins freed, the Hackberry overlay"
sed -i -E 's/^dtoverlay=dwc2$/dtoverlay=dwc2,dr_mode=host/' "$B/config.txt"
# Ubuntu turns on I2C1 (GPIO 2-3) and SPI0 (GPIO 7-11); the DPI panel needs GPIO 0-27
sed -i -E 's/^dtparam=(i2c_arm|spi)=on$/# & (hackberry: off, the DPI panel needs these pins)/' "$B/config.txt"
grep -q '^# hackberry-ubuntu-phosh' "$B/config.txt" || cat >>"$B/config.txt" <<'EOF'

# hackberry-ubuntu-phosh: screen, touch, battery gauge
[all]
dtoverlay=hackberrypicm5
EOF
# only lines in [all] or [cm5] apply to a CM5 (the image's [cm4] section has the same line)
awk '/^\[/{s=$0; next} (s=="" || s=="[all]" || s=="[cm5]") && /^dtoverlay=dwc2,dr_mode=host[[:space:]]*$/{f=1} END{exit !f}' "$B/config.txt" \
  || printf '\n[cm5]\ndtoverlay=dwc2,dr_mode=host\n[all]\n' >>"$B/config.txt"

say "user ${USERNAME}"
grep -q "^${USERNAME}:" "$W/etc/passwd" || inr useradd -m -U -s /bin/bash -c "$USERNAME" "$USERNAME"
groups=$(for gr in sudo adm audio video render input plugdev netdev dialout lpadmin bluetooth gpio i2c spi; do
  grep -q "^$gr:" "$W/etc/group" && printf '%s,' "$gr"; done; true)
inr usermod -aG "${groups%,}" "$USERNAME"
install -m 0440 /dev/stdin "$W/etc/sudoers.d/010-${USERNAME}" <<<"${USERNAME} ALL=(ALL) NOPASSWD: ALL"
printf '%s:%s\n' "$USERNAME" "$PW" | inr chpasswd; unset PW
UH=$W/home/$USERNAME; UIDN=$(inr id -u "$USERNAME"); GIDN=$(inr id -g "$USERNAME")
uinst() { install -o "$UIDN" -g "$GIDN" "$@"; }
uinst -d "$UH/.config" "$UH/.local" "$UH/.local/share" "$UH/.local/share/applications" "$UH/.config/hackberry"
echo yes | uinst -m 0644 /dev/stdin "$UH/.config/gnome-initial-setup-done"
install -d "$W/var/lib/AccountsService/users"
s=$([[ $SESSION == phosh ]] && echo phosh || echo ubuntu)
printf '[User]\nSession=%s\nSystemAccount=false\n' "$s" >"$W/var/lib/AccountsService/users/$USERNAME"

if [[ -n $SSHKEY ]]; then
  say "ssh: keys only, no root, the host's own keys"
  uinst -d -m 0700 "$UH/.ssh"; uinst -m 0600 "$SSHKEY" "$UH/.ssh/authorized_keys"
  printf '# hackberry-ubuntu-phosh: keys only\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
    >"$W/etc/ssh/sshd_config.d/10-hackberry.conf"
  ls "$W"/etc/ssh/ssh_host_*_key >/dev/null 2>&1 || inr ssh-keygen -A
  ls "$W"/etc/ssh/ssh_host_ed25519_key >/dev/null || die "no ssh host keys in the new system"
  # Ubuntu's sshd-keygen.service replaces the host keys on a system's first boot (ConditionFirstBoot),
  # so the keys made here would change under the user, or be lost; keep the ones made here
  ln -sf /dev/null "$W/etc/systemd/system/sshd-keygen.service"
  inr systemctl enable ssh.service >/dev/null || die "could not enable ssh.service in the new system"
fi
if (( ${#wifi[@]} + ${#plan[@]} )); then
  say "networks: $(( ${#wifi[@]} + ${#plan[@]} )) saved connection(s)"
  install -d -m 0700 "$W/etc/NetworkManager/system-connections"
  ((${#wifi[@]})) && install -m 0600 "${wifi[@]}" "$W/etc/NetworkManager/system-connections/"
  ((${#plan[@]})) && install -m 0600 "${plan[@]}" "$W/etc/netplan/"
fi

say "Chromium from Flathub, the default browser"
if inr flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
  inr flatpak install -y --system --noninteractive flathub org.chromium.Chromium >/dev/null \
    || say "Chromium NOT installed; after boot run: sudo flatpak install flathub org.chromium.Chromium"
else
  say "Flathub NOT added; after boot run: sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
fi
cdesk=$W/var/lib/flatpak/exports/share/applications/org.chromium.Chromium.desktop
# Phosh reports "failed to start" if an app shows no window within about 5 s; Chromium takes longer
[[ -f $cdesk ]] && sed 's/^StartupNotify=true$/StartupNotify=false/' "$cdesk" \
  | uinst -m 0644 /dev/stdin "$UH/.local/share/applications/org.chromium.Chromium.desktop"
uinst -m 0644 /dev/stdin "$UH/.config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=org.chromium.Chromium.desktop
x-scheme-handler/https=org.chromium.Chromium.desktop
text/html=org.chromium.Chromium.desktop

[Added Associations]
x-scheme-handler/http=org.chromium.Chromium.desktop;
x-scheme-handler/https=org.chromium.Chromium.desktop;
text/html=org.chromium.Chromium.desktop;
EOF

say "desktop defaults: dock, no screen blanking"
cat >"$W/usr/share/glib-2.0/schemas/90_hackberry.gschema.override" <<'EOF'
# hackberry-ubuntu-phosh
[org.gnome.shell]
favorite-apps=['org.chromium.Chromium.desktop', 'org.gnome.Evolution.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Rhythmbox3.desktop', 'libreoffice-writer.desktop', 'org.gnome.Yelp.desktop']

# The panel has no backlight control and sets itself up only at power-on: once its video signal
# stops (screen blank) it shows a lit, flickering halo until a power cycle. Never blank; the
# black screensaver (hackberry-blank) stands in for it under Phosh.
[org.gnome.desktop.session]
idle-delay=uint32 0

[org.gnome.settings-daemon.plugins.power]
idle-dim=false
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
EOF
inr glib-compile-schemas /usr/share/glib-2.0/schemas

say "shutdown: login sessions get 10 s to stop (Phosh's init worker ignores SIGTERM)"
install -d "$W/etc/systemd/system/session-.scope.d"
printf '# hackberry-ubuntu-phosh: gnome-session-init-worker ignores SIGTERM\n[Scope]\nTimeoutStopSec=10s\n' \
  >"$W/etc/systemd/system/session-.scope.d/10-hackberry-stop-timeout.conf"

say "black screensaver (Phosh), no blanking on the lock screen, Bluetooth speaker reconnect at login"
install -m 0755 /dev/stdin "$W/usr/local/bin/hackberry-blank" <<'EOF'
#!/usr/bin/python3
# hackberry-ubuntu-phosh: a black full-screen layer over everything (Phosh), closed by any touch,
# tap, key or pointer move. The panel must keep its video signal: blanking it leaves a lit halo
# until a power cycle, so this stands in for screen blanking. Started by hackberry-blank-idle.
import os, sys
lib = "/usr/lib/aarch64-linux-gnu/libgtk4-layer-shell.so.0"
if os.environ.get("HACKBERRY_BLANK_PRELOADED") != "1":   # gtk4-layer-shell must load before libwayland
    os.environ["LD_PRELOAD"] = lib; os.environ["HACKBERRY_BLANK_PRELOADED"] = "1"
    os.execv(sys.argv[0], sys.argv)
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gtk, Gdk, Gtk4LayerShell as L, GLib

def activate(app):
    w = Gtk.ApplicationWindow(application=app)
    css = Gtk.CssProvider(); css.load_from_string("window { background: #000; }")
    Gtk.StyleContext.add_provider_for_display(w.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    L.init_for_window(w); L.set_layer(w, L.Layer.OVERLAY); L.set_namespace(w, "hackberry-blank")
    for e in (L.Edge.TOP, L.Edge.BOTTOM, L.Edge.LEFT, L.Edge.RIGHT): L.set_anchor(w, e, True)
    L.set_exclusive_zone(w, -1); L.set_keyboard_mode(w, L.KeyboardMode.EXCLUSIVE)
    armed = [False]; GLib.timeout_add(800, lambda: armed.__setitem__(0, True) or False)  # ignore the trigger
    def close(*_):
        if armed[0]: app.quit()
        return True
    k = Gtk.EventControllerKey(); k.connect("key-pressed", close); w.add_controller(k)
    c = Gtk.GestureClick(); c.connect("pressed", close); w.add_controller(c)
    m = Gtk.EventControllerMotion(); m.connect("motion", close); w.add_controller(m)
    w.set_cursor(Gdk.Cursor.new_from_name("none", None))   # no pointer over the black
    w.present()

app = Gtk.Application(application_id="io.github.paulmarston.HackberryBlank")
app.connect("activate", activate)
sys.exit(app.run([]))
EOF
cat >"$W/etc/systemd/user/hackberry-blank-idle.service" <<'EOF'
# hackberry-ubuntu-phosh: black screensaver for Phosh (the Hackberry panel must never be blanked)
[Unit]
Description=Black screensaver after idle (Phosh)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
# runs only in Phosh, and not while hackberry-screensaver has switched it off (the flag file)
ExecCondition=/bin/sh -c 'case "$XDG_CURRENT_DESKTOP" in *Phosh*) ;; *) exit 1 ;; esac; [ ! -e "$HOME/.config/hackberry/screensaver-off" ]'
Environment=HACKBERRY_BLANK_AFTER=300
# the resume pattern is anchored: unanchored it also matched swayidle's own command line, so the
# first wake killed swayidle and the screensaver ran only once per login
ExecStart=/bin/sh -c 'exec swayidle -w timeout "$HACKBERRY_BLANK_AFTER" "/usr/local/bin/hackberry-blank &" resume "pkill -f ^/usr/bin/python3\ /usr/local/bin/hackberry-blank || true"'
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF
install -m 0755 /dev/stdin "$W/usr/local/bin/hackberry-bt-connect" <<'EOF'
#!/bin/sh
# hackberry-ubuntu-phosh: connect the trusted Bluetooth speakers listed in
# ~/.config/hackberry/bt-speakers (one address per line) after login; keeps trying for about
# 2 minutes while a speaker powers up.
list=${XDG_CONFIG_HOME:-$HOME/.config}/hackberry/bt-speakers
[ -r "$list" ] || exit 0
for i in $(seq 1 24); do
  left=0
  for mac in $(grep -Eo "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" "$list"); do
    bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes" && continue
    left=1; bluetoothctl connect "$mac" >/dev/null 2>&1 || true
  done
  [ $left = 0 ] && exit 0
  sleep 5
done
exit 0
EOF
cat >"$W/etc/systemd/user/hackberry-bt-connect.service" <<'EOF'
[Unit]
Description=Connect the Bluetooth speaker after login
After=wireplumber.service pipewire.service
Wants=wireplumber.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hackberry-bt-connect

[Install]
WantedBy=graphical-session.target
EOF
install -m 0755 /dev/stdin "$W/usr/local/bin/hackberry-screensaver" <<'EOF'
#!/bin/sh
# hackberry-ubuntu-phosh: switch the black screensaver (hackberry-blank-idle) on or off for this user.
#   hackberry-screensaver [toggle|on|off|status]      (toggle is what the app-grid icon runs)
# The choice is kept in ~/.config/hackberry/screensaver-off, which the service checks at login, so it
# survives logins and reboots. Off means the screen stays on; it is never blanked either way.
flag=$HOME/.config/hackberry/screensaver-off
unit=hackberry-blank-idle.service
mins=$(( $(systemctl --user show -p Environment --value "$unit" | tr ' ' '\n' | sed -n 's/^HACKBERRY_BLANK_AFTER=//p' | head -1) / 60 ))
[ "$mins" -gt 0 ] 2>/dev/null || mins=5
cmd=${1:-toggle}
[ "$cmd" = toggle ] && { [ -e "$flag" ] && cmd=on || cmd=off; }
case $cmd in
  on)  rm -f "$flag"; systemctl --user start "$unit"; msg="Screensaver on: black after ${mins} minutes idle" ;;
  off) mkdir -p "${flag%/*}"; : >"$flag"; systemctl --user stop "$unit"; msg="Screensaver off: the screen stays on" ;;
  status) [ -e "$flag" ] && echo off || echo on; exit 0 ;;
  *) echo "usage: hackberry-screensaver [toggle|on|off|status]" >&2; exit 2 ;;
esac
echo "$msg"
notify-send -a Screensaver -i preferences-desktop-screensaver -e "$msg" 2>/dev/null || true
EOF
# the app-grid icon that switches it (Phosh's own Caffeine toggle does not reach swayidle)
cat >"$W/usr/share/applications/hackberry-screensaver.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Screensaver
GenericName=Screensaver on/off
Comment=Turn the black screensaver on or off (the screen is never blanked)
Exec=/usr/local/bin/hackberry-screensaver toggle
Icon=preferences-desktop-screensaver
Terminal=false
Categories=Settings;DesktopSettings;
Keywords=screensaver;blank;black;idle;caffeine;
StartupNotify=false
X-Purism-FormFactor=Workstation;Mobile;
EOF
cat >"$W/etc/systemd/user/hackberry-no-blank.service" <<'EOF'
# hackberry-ubuntu-phosh: GNOME's power daemon blanks the screen 30 s into the lock screen
# whatever idle-delay says (a fixed timeout), and a blanked Hackberry panel shows a lit halo until
# a power cycle. An idle inhibitor for the whole session stops it; the black screensaver still runs.
[Unit]
Description=Keep the Hackberry panel from being blanked (idle inhibitor)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/gnome-session-inhibit --app-id=io.github.paulmarston.HackberryNoBlank --reason="The Hackberry panel shows a halo once blanked" --inhibit=idle --inhibit-only
Restart=on-failure

[Install]
WantedBy=graphical-session.target
EOF
inr systemctl --global enable hackberry-blank-idle.service hackberry-bt-connect.service hackberry-no-blank.service >/dev/null \
  || die "could not enable the user services (hackberry-blank-idle, hackberry-bt-connect, hackberry-no-blank)"
uinst -m 0644 /dev/stdin "$UH/.config/hackberry/bt-speakers" <<'EOF'
# Bluetooth speakers to connect after login, one address per line (pair and trust it first:
# Settings > Bluetooth, then add its address here, e.g. 00:11:22:33:44:55)
EOF

say "result"
echo "  kernels:   $(ls "$W/lib/modules" | tr '\n' ' ')"
echo "  battery:   $(ls "$W"/lib/modules/*/updates/dkms/*.ko* 2>/dev/null | wc -l) module(s)"
echo "  snapd:     $(inr dpkg-query -W -f='${db:Status-Abbrev}' snapd 2>/dev/null || echo none)"
echo "  chromium:  $(inr flatpak list --system --app --columns=version 2>/dev/null | head -1 || echo none)"
echo "  phosh:     $(inr dpkg-query -W -f='${Version}' phosh 2>/dev/null)"
echo "  overlay:   $(ls "$B"/{current,new}/overlays/hackberrypicm5.dtbo 2>/dev/null | sed "s#$W##" | tr '\n' ' ')"
echo "  boot:      current/ $(cat "$B/current/state" 2>/dev/null), new/ $(cat "$B/new/state" 2>/dev/null || echo none) (${newest})"
df -h "$W" "$W/home" "$B" | sed 's/^/  /'
rm -f "$W/usr/sbin/policy-rc.d"; sync
cat <<EOF

Done. ${DEVICE} holds Ubuntu + Phosh.
Next: power off, take the SD card out, power on. The first boot reboots once by itself into the
updated kernel. Log in as ${USERNAME}; Phosh is the default (GNOME is at the gear button).
EOF
[[ $TARGET == usb ]] && echo "USB: it boots only if the NVMe has no boot partition, unless you change BOOT_ORDER."
exit 0
