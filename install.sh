#!/usr/bin/env bash
# Audio fix for laptops with AMD ACP SoundWire + TI TAS2783 speaker amps
# (tested on HP OmniBook X Flip 16-cc0xxx, AMD Ryzen AI 9 465, CachyOS, kernel 7.3).
#
#   ./install.sh            check only (no root needed, changes nothing)
#   sudo ./install.sh apply   apply whatever parts of the fix are missing
#   sudo ./install.sh remove  undo what this script installed
#
# Exit codes for "check": 0 = nothing to do, 1 = fix needed and can be applied,
#                         2 = cannot be fixed by this script (see messages).

set -u
MODE="${1:-check}"
HERE="$(cd "$(dirname "$0")" && pwd)"
UCM_DIR=/usr/share/alsa/ucm2/sof-soundwire
UCM_FILE="$UCM_DIR/tas2783.conf"
FW_ROOT="$(readlink -f /lib/firmware 2>/dev/null || echo /lib/firmware)"
FW_TI="$FW_ROOT/ti/audio/tas2783"

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
todo() { printf '  \033[33m[fix]\033[0m  %s\n' "$*"; NEED_FIX=1; }
bad()  { printf '  \033[31m[fail]\033[0m %s\n' "$*"; BLOCKED=1; }
info() { printf '         %s\n' "$*"; }

NEED_FIX=0
BLOCKED=0

case "$MODE" in check|apply|remove) ;; *) echo "usage: $0 [check|apply|remove]"; exit 64;; esac
if [ "$MODE" != check ] && [ "$(id -u)" -ne 0 ]; then
    echo "'$MODE' needs root: sudo $0 $MODE"; exit 77
fi

# ---------------------------------------------------------------- remove
if [ "$MODE" = remove ]; then
    for l in "$FW_ROOT"/*.bin*; do
        [ -L "$l" ] || continue
        case "$(readlink "$l")" in ti/audio/tas2783/*) rm -v "$l";; esac
    done
    if [ -f "$UCM_FILE" ] && cmp -s "$UCM_FILE" "$HERE/tas2783.conf"; then
        if command -v pacman >/dev/null && pacman -Qo "$UCM_FILE" >/dev/null 2>&1; then
            echo "$UCM_FILE is owned by a package now; leaving it."
        elif command -v dpkg >/dev/null && dpkg -S "$UCM_FILE" >/dev/null 2>&1; then
            echo "$UCM_FILE is owned by a package now; leaving it."
        else
            rm -v "$UCM_FILE"
        fi
    fi
    echo "Done. Reboot to take effect."; exit 0
fi

echo "== System"
info "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
info "kernel $(uname -r)"
[ -r /etc/os-release ] && info "$(. /etc/os-release; echo "$PRETTY_NAME")"

# ---------------------------------------------------------------- hardware
echo "== Hardware"
ACP=""
for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1022 ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x0480*) ACP="$d"; break;; esac
done
if [ -z "$ACP" ]; then
    bad "no AMD Audio Coprocessor (ACP) found - this fix is for AMD SoundWire laptops"
else
    SSID="$(sed 's/^0x//' "$ACP/subsystem_device" | tr a-f A-F)"
    ok "AMD ACP at ${ACP##*/}, subsystem ID $SSID"
fi

AMPS=()
for d in /sys/bus/soundwire/devices/sdw:*:*:0102:*; do
    [ -e "$d" ] && AMPS+=("${d##*/}")
done
if [ ${#AMPS[@]} -eq 0 ]; then
    bad "no TI SoundWire devices found (manufacturer 0x0102)"
    info "either the hardware differs, or the kernel lacks AMD SoundWire support"
else
    ok "TI SoundWire amps: ${AMPS[*]}"
fi

if modinfo snd_soc_tas2783_sdw >/dev/null 2>&1; then
    ok "kernel has the TAS2783 driver (snd_soc_tas2783_sdw)"
else
    bad "kernel $(uname -r) has no TAS2783 SoundWire driver - a newer kernel is required"
fi

# ---------------------------------------------------------------- firmware
echo "== Amp firmware"
LINKS=()   # entries: "linkname target"
if [ ! -d "$FW_TI" ]; then
    bad "$FW_TI missing - install a newer linux-firmware (TI/tas2783 files)"
elif [ -n "${SSID:-}" ]; then
    for a in "${AMPS[@]}"; do
        # sdw:<ctrl>:<link>:<mfg>:<part>:<ver>:<unique>
        IFS=: read -r _ ctrl link _ _ _ uid <<<"$a"
        uid="$(echo "${uid:-0}" | tr a-f A-F)"
        want="$SSID-$link-0x$uid"            # name the kernel driver requests
        if ls "$FW_ROOT/$want".bin* >/dev/null 2>&1; then
            ok "$want.bin already present"
            continue
        fi
        target=""
        for cand in "$SSID-$link-0-0x$uid" "$SSID-$ctrl-$link-0x$uid"; do
            for ext in .bin.zst .bin.xz .bin; do
                if [ -e "$FW_TI/$cand$ext" ]; then target="$cand$ext"; break 2; fi
            done
        done
        if [ -n "$target" ]; then
            todo "driver wants $want.bin; will link to ti/audio/tas2783/$target"
            LINKS+=("$want${target#"${target%%.bin*}"} ti/audio/tas2783/$target")
        else
            bad "no firmware for $want in $FW_TI (looked for $SSID-$link-0-0x$uid.*)"
            info "available for this model: $(cd "$FW_TI" && ls | grep -i "^$SSID" | tr '\n' ' ')"
        fi
    done
fi

# ---------------------------------------------------------------- UCM
echo "== ALSA UCM profile"
if [ ! -d "$UCM_DIR" ]; then
    bad "$UCM_DIR missing - alsa-ucm-conf too old or not installed"
elif [ -f "$UCM_FILE" ]; then
    ok "$UCM_FILE present"
else
    todo "$UCM_FILE missing - will install the upstream copy"
fi

# ---------------------------------------------------------------- result
echo
if [ "$BLOCKED" -eq 1 ]; then
    echo "Some requirements are missing (see [fail] above); this script cannot fix those."
    [ "$NEED_FIX" -eq 1 ] && [ "$MODE" = apply ] && echo "Applying the parts that can be fixed anyway."
fi
if [ "$NEED_FIX" -eq 0 ]; then
    [ "$BLOCKED" -eq 0 ] && echo "Nothing to do - everything this fix covers is already in place."
    [ "$BLOCKED" -eq 1 ] && exit 2 || exit 0
fi
if [ "$MODE" = check ]; then
    echo "Run 'sudo $0 apply' to apply the fix."
    [ "$BLOCKED" -eq 1 ] && exit 2 || exit 1
fi

for e in "${LINKS[@]}"; do
    name="${e%% *}"; target="${e#* }"
    ln -sfv "$target" "$FW_ROOT/$name"
done
if [ -d "$UCM_DIR" ] && [ ! -f "$UCM_FILE" ]; then
    install -v -m644 "$HERE/tas2783.conf" "$UCM_FILE"
fi
echo
echo "Applied. Reboot so the amp firmware loads, then check: wpctl status"
