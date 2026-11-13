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
2. **Firmware name mismatch.** The kernel driver requests `<SSID>-<link>-0x<uid>.bin`
   (e.g. `8EA2-0-0xC.bin`) from the firmware root, while linux-firmware ships the
   files as `ti/audio/tas2783/<SSID>-<variant>-<link>-0x<uid>.bin.zst`, with more than
   one tuning variant per board. Without firmware the amps reject playback. The fix
   symlinks the requested name to the right variant — see
   [Firmware variant](#firmware-variant).

## Usage

```sh
git clone https://github.com/thejameslang/omnibook-x-flip-16-linux-audio
cd omnibook-x-flip-16-linux-audio
./install.sh            # check only, changes nothing
sudo ./install.sh apply # apply the missing parts
reboot
```

The check exits `0` (nothing to do), `1` (fixable) or `2` (something this script can't
fix — see below).

`sudo ./install.sh remove` undoes everything: the firmware alias links, the saved
variant in `/etc/tas2783-variant`, and the UCM file (if it's still this repo's copy and
no package owns it). It works even when the amps aren't detected, for example after
switching to a kernel where SoundWire doesn't enumerate. It then falls back to
matching the alias names (`<SSID>-<link>-0x<uid>.bin*`) in the firmware root.

It only removes a link that has the exact shape this script creates: it points to
`ti/audio/tas2783/<SSID>-<variant>-<link>-0x<uid>` for the same name, and no package owns
it. It never touches anything inside `ti/`, or the many similarly named links that
linux-firmware installs itself.

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
  naming. `install.sh` leaves real files and package-provided links alone, and
  `remove` only deletes the alias links it creates.

## Firmware variant

linux-firmware names the TAS2783 tuning files

```
<SSID>-<variant>-<link>-0x<uid>.bin     e.g. 8EA2-1-0-0xC.bin.zst
```

- `SSID` — the audio subsystem ID of the laptop (`8EA2` here).
- `variant` — a tuning variant (`0` or `1` for this board), most likely for different
  speaker suppliers. It is **not** the SoundWire link.
- `link` and `uid` — where each amp sits on the SoundWire bus (here link `0`,
  amps `0x9` and `0xC`).

The kernel driver only asks for `<SSID>-<link>-0x<uid>.bin`, so the script has to pick
the variant. An earlier version of this repo picked variant 0 by mistake.

**What this unit uses:** on Windows, Process Monitor showed HP's `SDCATITASXu` driver
loading `8EA2-1-0-0x9.bin` and `8EA2-1-0-0xC.bin`, and never touching `8EA2-0-0-*`.
So `install.sh` defaults to **variant 1 for SSID 8EA2**. This has been verified on
**one unit only**; another 8EA2 laptop with different speakers could need variant 0.

For other SSIDs the script doesn't guess: if exactly one variant ships it uses that,
and if several ship it stops and asks you to choose with `TAS_VARIANT`.

### Choosing a different variant

```sh
sudo TAS_VARIANT=0 ./install.sh apply   # repoint the links to variant 0 and remember it
reboot
```

`apply` with `TAS_VARIANT` set saves the number to **`/etc/tas2783-variant`**, so later
plain `./install.sh` checks and `apply` runs keep using it instead of switching back to
the default. It only accepts and saves a variant that has firmware for every detected
amp. Otherwise it reports `[fail]`, lists the available files, and changes nothing.
The script picks the variant in this order:

1. `TAS_VARIANT` from the environment
2. `/etc/tas2783-variant`
3. the board default (`8EA2` → `1`)
4. the only variant shipped for the board (if there are several, it stops and asks)

Check mode prints which one it used, for example
`firmware variant 0 (saved in /etc/tas2783-variant)`.

To clear the override and go back to the board default:

```sh
sudo TAS_VARIANT=default ./install.sh apply   # deletes /etc/tas2783-variant, repoints links
reboot
```

### Checking your unit's variant from Windows

If you still have Windows (or can boot it from another drive):

1. Get [Process Monitor](https://learn.microsoft.com/sysinternals/downloads/procmon)
   and add filters: *Process Name is `System`* and *Path contains `8EA2-`*. Use your
   own SSID if it differs. `./install.sh` prints it on Linux. On Windows it's the first
   4 hex digits after `SUBSYS_` in the audio device's hardware ID (`SUBSYS_8EA2103C`).
2. In an admin terminal, list the TI amps (SoundWire manufacturer `0102`):
   ```
   pnputil /enum-devices /connected | findstr /i "MAN_0102"
   ```
   This lists two instance IDs, one per amp.
3. With Process Monitor capturing, restart both amps so their firmware reloads:
   ```
   pnputil /restart-device "<instance id 1>"
   pnputil /restart-device "<instance id 2>"
   ```
   If `/restart-device` isn't available, use `/disable-device` then `/enable-device`.
4. Play some audio, then look at which `8EA2-*-0-*.bin` files the System process
   read. The number after the SSID is your variant.

Please open an issue with your result, especially if it's variant 0.

## Notes

- `port 2 not supported for TX` messages in the kernel log come from the amp's
  feedback/capture path and do not affect playback.
