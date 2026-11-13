# HP OmniBook X Flip 16 — Linux audio fix

Fixes "no sound / Dummy Output" on the **HP OmniBook X Flip Laptop 16-cc0xxx**
(AMD Ryzen AI 300-series, subsystem ID `103c:8ea2`) and likely other AMD laptops that
use SoundWire audio with **TI TAS2783** speaker amps.

Tested on CachyOS, kernel 7.3.4, alsa-ucm-conf 1.2.16.1, linux-firmware 20261019,
PipeWire 1.6.11. After the fix: speakers, headphone jack, internal mics and headset
mic all work.

## Symptoms

- Sound settings show only **Dummy Output**; `pactl list short sinks` lists only `auto_null`.
- `aplay -l` *does* list an `amdsoundwire` card (so the kernel driver is fine).
- `alsaucm -c hw:1 list _verbs` fails with
  `could not open configuration file /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf`.
- Kernel log: `slave-tas2783 ...: Direct firmware load for 8EA2-0-0xC.bin failed with error -2`
  and later `error playback without fw download`.

## Cause

Two separate problems, both needed:

1. **Missing ALSA UCM profile.** The card advertises `spk:tas2783`, but the released
   alsa-ucm-conf has no `sof-soundwire/tas2783.conf`, so the whole card fails UCM setup
   and PipeWire exposes nothing. Upstream added it in Aug 2026
   ([alsa-ucm-conf #812](https://github.com/alsa-project/alsa-ucm-conf/pull/812)) but it
   is not in a tagged release yet. `tas2783.conf` in this repo is that upstream file.
2. **Firmware name mismatch.** The kernel driver requests `<SSID>-<link>-0x<id>.bin`
   (e.g. `8EA2-0-0xC.bin`) from the firmware root, while linux-firmware ships the
   right files as `ti/audio/tas2783/8EA2-0-0-0xC.bin.zst`. Without firmware the amps
   reject playback. The fix symlinks the requested name to the shipped file.

## Usage

```sh
git clone https://github.com/thejameslang/omnibook-x-flip-16-linux-audio
cd omnibook-x-flip-16-linux-audio
./install.sh            # check only, changes nothing
sudo ./install.sh apply # apply the missing parts
reboot
```

`sudo ./install.sh remove` undoes it. The check exits `0` (nothing to do),
`1` (fixable) or `2` (something this script can't fix — see below).

## Will it work on other distros?

The fix itself is distro-independent; what matters is how new the distro's packages are.
`./install.sh` checks all of this:

| Requirement | Why | If missing |
|---|---|---|
| Kernel with `snd_soc_tas2783_sdw` and AMD ACP SoundWire | drives the amps | install a newer kernel (e.g. mainline/HWE on Ubuntu-based distros) |
| linux-firmware with `ti/audio/tas2783/` | amp firmware | update linux-firmware |
| `/usr/share/alsa/ucm2/sof-soundwire/` | alsa-ucm-conf with SoundWire support | update alsa-ucm-conf |

Rolling/recent distros (Arch, CachyOS, Fedora) usually meet these. Ubuntu-LTS-based
distros (Linux Mint, Pop!_OS) may need a newer kernel and firmware first.

## When to remove it

- When your distro's **alsa-ucm-conf** ships `tas2783.conf`, the package manager may
  report a file conflict (pacman: "exists in filesystem"). Delete
  `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` and upgrade again.
- The firmware symlinks become unnecessary once the kernel or linux-firmware fix the
  naming; leaving them is harmless. `install.sh` skips links that already resolve.

## Notes

- `port 2 not supported for TX` messages in the kernel log come from the amp's
  feedback/capture path and do not affect playback.
- The amps here are on SoundWire link 0 (IDs 0x9, 0xC), so the `8EA2-0-0-*` firmware is
  used. If sound is distorted or unbalanced, the `8EA2-1-0-*` variants are the thing to try.
