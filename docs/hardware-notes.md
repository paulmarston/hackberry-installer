# HackberryPi CM5 hardware notes

These were learned the hard way, while building the Ubuntu + Phosh system this repository installs.
They apply to any OS on a HackberryPi CM5: a Raspberry Pi Compute Module 5 Lite, with a 720×720
DPI panel and a USB keyboard and trackpad.

## The Hackberry overlay

The screen, touch and battery gauge are described by one device-tree overlay,
`hackberrypicm5`. Its source is
[`vendor/hackberrypi-max17048/hackberrypicm5.dts`](../vendor/hackberrypi-max17048/hackberrypicm5.dts).
It provides:

- **Screen:** a `panel-dpi` 720×720 panel, using 18-bit DPI (`dpi_18bit_cpadhi_gpio0`), which
  takes most of the low GPIOs, from GPIO 0 up.
- **Touch:** an `edt-ft5406` controller on a GPIO I²C bus (GPIO 10/11), at 0x48. Its interrupt is
  GPIO 27, with a pull-up.
- **Battery gauge:** a MAX17048 on the same bus, at 0x36. It needs the `hackberrypi-max17048`
  kernel module, built with DKMS.

The keyboard and trackpad are a USB HID device on the CM5's USB 2.0 port. That port has to be in
host mode:

```ini
[cm5]
dtoverlay=dwc2,dr_mode=host
```

Ubuntu's own `config.txt` has `dtoverlay=dwc2` (peripheral mode) under `[all]`. Without the change,
the keyboard is dead.

## Ubuntu's config.txt takes the panel's pins

Ubuntu turns on `dtparam=i2c_arm=on` (GPIO 2–3) and `dtparam=spi=on` (GPIO 7–11). The DPI panel
needs those pins too, so its driver fails with `pin gpio2 already requested`. The screen then stays
blank while HDMI works. Comment both lines out.

## Never blank the screen

The panel has no backlight control (`/sys/class/backlight` is empty), and it sets itself up only at
power-on. When the compositor blanks the screen (DPMS off), the video signal stops, but the backlight
stays lit. The panel then shows a bright, flickering halo or vignette. Turning the output back on
does not bring the picture back, and nor does a soft reboot: only a power cycle does. Raspberry Pi
OS doesn't blank by default, which is why this rarely shows there.

Under GNOME and Phosh, blanking comes from two places:

1. **Idle blank:** `org.gnome.desktop.session idle-delay`. Set it to 0, and turn off idle dim and
   idle suspend in `org.gnome.settings-daemon.plugins.power`.
2. **gsd-power on the lock screen:** while the screen is locked, it blanks after a fixed 30 s,
   whatever `idle-delay` says. Only a session idle inhibitor stops it:
   `gnome-session-inhibit --inhibit=idle --inhibit-only`, held for the whole session.

The installer stands in a black screensaver instead. When idle, `swayidle` puts a full-screen
black layer-shell surface over everything, and a touch or key removes it. The video signal never
stops. The session inhibitor doesn't affect `swayidle`, because swayidle uses the compositor's own
idle protocol.

## The bootloader numbers only FAT partitions on GPT

On a GPT disk, the CM5 bootloader counts only the FAT partitions for `boot_partition` in
`autoboot.txt`, and for `reboot N`. With FAT partitions at GPT 1 and 5, partition 5 is number 2.
`boot_partition=5` silently falls back to the first partition.

The installer avoids the issue: the boot partition is partition 1, and no `autoboot.txt` switching
is needed.

## Ubuntu's kernel updates are A/B (piboot-try)

Ubuntu's raspi images keep the boot files in `current/`, `new/` and `old/` on the boot partition.

- **How updates land:** flash-kernel writes a new kernel to `new/`. At the next boot,
  `piboot-try` reboots once into it, using the bootloader's tryboot. If that boot succeeds, the new
  kernel becomes `current/`.
- **In a chroot:** flash-kernel does nothing unless `FK_FORCE=yes` is set.
- **Overlays:** the Hackberry overlay has to be copied into `current/overlays` and `new/overlays`.
  The installer's kernel hook keeps it there after every update.

## The battery driver needs headers for every kernel

DKMS builds the battery module only for kernels whose headers are installed. Install
`linux-headers-raspi`, the metapackage, rather than one kernel's headers. Otherwise the battery
gauge disappears after the next kernel update.

## PCIe Gen 3

`dtparam=pciex1_gen=3` brought the NVMe link to 8 GT/s. Under the first sustained write, though,
the disk seemed to drop off the bus. The install keeps the default, Gen 2.

## Phosh quirks

- **Phosh's init worker:** `gnome-session-init-worker` ignores SIGTERM, so every shutdown waited the
  full 90 s. A drop-in for `session-.scope` with `TimeoutStopSec=10s` fixes it.
- **"Failed to start":** Phosh reports this for apps that show no window within about 5 s. The
  Flatpak Chromium is slower than that on a CM5, so give it `StartupNotify=false` in a local copy
  of its desktop file.
- **No display scaling:** GNOME offers none at 720×720, because mutter wants a logical area of at
  least 800×480. Phosh sizes the screen sensibly at scale 1.

## Ubuntu replaces the ssh host keys on first boot

Ubuntu's `sshd-keygen.service` (`ConditionFirstBoot=yes`) throws away the ssh host keys on a
system's first boot and makes new ones. Host keys set up while installing are therefore lost: ssh
reports a changed host key, or there are briefly no keys at all. The installer masks the
service, because it makes the keys itself.
