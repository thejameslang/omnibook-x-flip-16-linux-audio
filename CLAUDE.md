# Notes for Claude Code

This repo fixes audio on an HP OmniBook X Flip 16 (AMD ACP SoundWire + TI TAS2783 amps +
Realtek RT712 headset codec). The owner may clone it on a fresh distro and ask whether
the fix applies. Read README.md for the full background.

When asked to check or fix audio on this machine:

1. Run `./install.sh` (check mode, no root). Exit 0 = nothing to do, 1 = fixable,
   2 = blocked by something the script can't fix (old kernel, missing firmware, old
   alsa-ucm-conf, different hardware).
2. Also confirm the actual state rather than trusting the script alone:
   `wpctl status` (look for Speaker/Headphones sinks vs. "Dummy Output"),
   `aplay -l`, `alsaucm -c hw:<amdsoundwire card> list _verbs`,
   `journalctl -k -b | grep -i tas2783`.
3. If exit 2: explain which requirement is missing and the distro-appropriate way to
   get it (e.g. newer kernel on Ubuntu-based distros). Don't apply partial fixes
   without saying they won't be sufficient.
4. If fixable: `sudo ./install.sh apply` needs root — give the user the exact command to
   run (keep it on one short line), then a reboot is required for the amp firmware.
5. After reboot, verify: no "Direct firmware load ... failed" for tas2783, Speaker sink
   present, test with `pw-play /usr/share/sounds/freedesktop/stereo/complete.oga` and ask
   the user whether they heard it.

## Firmware variant (important)

linux-firmware names TAS2783 files `<SSID>-<variant>-<link>-0x<uid>.bin`, but the
kernel driver requests `<SSID>-<link>-0x<uid>.bin`. `install.sh` symlinks the latter
to the former, so it has to choose a **variant**. The variant is a tuning field (likely
speaker supplier), **not** the SoundWire link.

- SSID 8EA2 defaults to variant 1. This was verified on Windows with Process Monitor:
  HP's SDCATITASXu driver loads `8EA2-1-0-0x9/0xC.bin`, never `8EA2-0-0-*`. It's
  verified on one unit only.
- Other SSIDs: if one variant ships it's used; if several ship the check reports
  `[fail]` and the user must choose.
- Override: `sudo TAS_VARIANT=0 ./install.sh apply`, then reboot. Undo by re-running
  `apply` without it, or with `remove`.
- Check mode prints the variant in use and why, and reports `[fix]` if the existing
  symlinks point at a different variant.

When checking a machine, read the variant line and confirm the symlink targets
(`ls -l /lib/firmware/<SSID>-*`) match it. If the speakers sound distorted, thin or
unbalanced, the wrong variant is the first suspect. The README explains how to verify
the variant from Windows.

`remove` only deletes the requested-name symlinks for this machine's amps. linux-firmware
itself ships many `<SSID>-<variant>-<link>-*` symlinks in the firmware root. Those are
package-owned and must never be deleted.

The distro might have fixed things differently since this was written (Nov 2026) — e.g.
upstream may have shipped `tas2783.conf` or changed firmware names. Check before
assuming the old fix is still needed.
