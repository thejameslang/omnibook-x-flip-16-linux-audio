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

The distro might have fixed things differently since this was written (Nov 2026) — e.g.
upstream may have shipped `tas2783.conf` or changed firmware names. Check before
assuming the old fix is still needed.
