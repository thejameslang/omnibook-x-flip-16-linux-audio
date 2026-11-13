#!/usr/bin/env bash
# Audio fix for laptops with AMD ACP SoundWire + TI TAS2783 speaker amps
# (tested on HP OmniBook X Flip 16-cc0xxx, AMD Ryzen AI 9 465, CachyOS, kernel 7.3).
#
#   ./install.sh              check only (no root needed, changes nothing)
#   sudo ./install.sh apply   apply whatever parts of the fix are missing
#   sudo ./install.sh remove  undo what this script installed
#
# Amp firmware tuning variant: linux-firmware names files
#   <SSID>-<variant>-<link>-0x<uid>.bin   e.g. 8EA2-1-0-0xC.bin.zst
# Variant is chosen from, in order: $TAS_VARIANT, /etc/tas2783-variant,
# the board default (8EA2 -> 1), or the only variant shipped.
#   sudo TAS_VARIANT=0 ./install.sh apply        use variant 0 and remember it
#   sudo TAS_VARIANT=default ./install.sh apply  forget it, back to the default
#
# Exit codes for "check": 0 = nothing to do, 1 = fix needed and can be applied,
#                         2 = cannot be fixed by this script (see messages).

set -u
MODE="${1:-check}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# System paths (kept together so tests can point them at a fake root).
SYS_PCI=/sys/bus/pci/devices
SYS_SDW=/sys/bus/soundwire/devices
FW_ROOT="$(readlink -f /lib/firmware 2>/dev/null || echo /lib/firmware)"
UCM_DIR=/usr/share/alsa/ucm2/sof-soundwire
VARIANT_FILE=/etc/tas2783-variant

UCM_FILE="$UCM_DIR/tas2783.conf"
FW_REL="ti/audio/tas2783"
FW_TI="$FW_ROOT/$FW_REL"

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
if [ -n "${TAS_VARIANT:-}" ] && ! [[ "$TAS_VARIANT" =~ ^([0-9]+|default)$ ]]; then
    echo "TAS_VARIANT must be a number (e.g. 0 or 1) or 'default', got '$TAS_VARIANT'"; exit 64
fi

# True if a package manager owns the path (never touch those).
pkg_owned() {
    if command -v pacman >/dev/null 2>&1; then pacman -Qo "$1" >/dev/null 2>&1 && return 0; fi
    if command -v dpkg >/dev/null 2>&1; then dpkg -S "$1" >/dev/null 2>&1 && return 0; fi
    if command -v rpm >/dev/null 2>&1; then rpm -qf "$1" >/dev/null 2>&1 && return 0; fi
    return 1
}

# First existing "$FW_ROOT/<name>.bin*" path, or empty.
find_requested() {
    local f
    for f in "$FW_ROOT/$1".bin "$FW_ROOT/$1".bin.zst "$FW_ROOT/$1".bin.xz; do
        if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; return; fi
    done
}

# ---------------------------------------------------------------- hardware
ACP=""
SSID=""
for d in "$SYS_PCI"/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1022 ] || continue
    case "$(cat "$d/class" 2>/dev/null)" in 0x0480*) ACP="$d"; break;; esac
done
[ -n "$ACP" ] && SSID="$(sed 's/^0x//' "$ACP/subsystem_device" | tr '[:lower:]' '[:upper:]')"

AMPS=()
for d in "$SYS_SDW"/sdw:*:*:0102:*; do
    [ -e "$d" ] && AMPS+=("${d##*/}")
done

# Name the kernel driver requests for an amp: <SSID>-<link>-0x<uid>
# Sets globals LINK, UID_HEX, WANT.
parse_amp() {
    # sdw:<ctrl>:<link>:<mfg>:<part>:<ver>:<unique>
    IFS=: read -r _ _ LINK _ _ _ UID_HEX <<<"$1"
    UID_HEX="$(echo "${UID_HEX:-0}" | tr '[:lower:]' '[:upper:]')"
    WANT="$SSID-$LINK-0x$UID_HEX"
}

# True if $1 is a symlink this script would have created: in the firmware root,
# named <SSID>-<link>-0x<uid>.bin[.ext], pointing at
# ti/audio/tas2783/<SSID>-<variant>-<link>-0x<uid>.bin[.ext], and not package-owned.
# Package links (e.g. 15E2-0-0x9.bin.zst -> ti/audio/tas2783/15E2-0-0x9.bin.zst)
# never have that shape, and are also excluded by pkg_owned.
is_our_link() {
    local f="$1" name tgt
    [ -L "$f" ] || return 1
    name="${f##*/}"
    tgt="$(readlink "$f")"
    [[ "$name" =~ ^([0-9A-F]{4})-([0-9]+)-0x([0-9A-F]+)(\.bin(\.zst|\.xz)?)$ ]] || return 1
    local ss="${BASH_REMATCH[1]}" ln="${BASH_REMATCH[2]}" uid="${BASH_REMATCH[3]}" ext="${BASH_REMATCH[4]}"
    [[ "$tgt" =~ ^${FW_REL}/${ss}-[0-9]+-${ln}-0x${uid}${ext//./\\.}$ ]] || return 1
    ! pkg_owned "$f"
}

# ---------------------------------------------------------------- remove
if [ "$MODE" = remove ]; then
    removed=0
    rm_link() { if is_our_link "$1"; then rm -v "$1"; removed=$((removed + 1)); fi; }
    # 1. the names requested by the detected amps
    if [ -n "$SSID" ]; then
        for a in "${AMPS[@]}"; do
            parse_amp "$a"
            f="$(find_requested "$WANT")"
            [ -n "$f" ] && rm_link "$f"
        done
    fi
    # 2. amps not enumerated (e.g. older kernel): any <SSID>-<link>-0x* alias,
    #    or any <XXXX>-<link>-0x* alias if the SSID is unknown too
    if [ -n "$SSID" ]; then
        for f in "$FW_ROOT/$SSID"-*-0x*.bin*; do rm_link "$f"; done
    else
        echo "Audio subsystem ID not detected; removing any alias links this script creates."
        for f in "$FW_ROOT"/????-*-0x*.bin*; do rm_link "$f"; done
    fi
    [ "$removed" -eq 0 ] && echo "No firmware links from this script found."
    if [ -e "$VARIANT_FILE" ]; then rm -v "$VARIANT_FILE"; fi
    if [ -f "$UCM_FILE" ] && cmp -s "$UCM_FILE" "$HERE/tas2783.conf"; then
        if pkg_owned "$UCM_FILE"; then
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

echo "== Hardware"
if [ -z "$ACP" ]; then
    bad "no AMD Audio Coprocessor (ACP) found - this fix is for AMD SoundWire laptops"
else
    ok "AMD ACP at ${ACP##*/}, subsystem ID $SSID"
fi
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

# ---------------------------------------------------------------- variant
echo "== Amp firmware"
# Saved override: what it is now, and what apply should leave behind.
SAVED=""
if [ -e "$VARIANT_FILE" ]; then
    SAVED="$(tr -d '[:space:]' < "$VARIANT_FILE")"
fi
VARIANT_SAVE=""     # "", a number to write, or "delete"
case "${TAS_VARIANT:-}" in
    "") ;;
    default)
        if [ -e "$VARIANT_FILE" ]; then
            todo "TAS_VARIANT=default: will delete $VARIANT_FILE (saved variant ${SAVED:-?})"
            VARIANT_SAVE=delete
        fi;;
    *)
        if [ "$SAVED" != "$TAS_VARIANT" ]; then
            todo "will save variant $TAS_VARIANT to $VARIANT_FILE"
            VARIANT_SAVE="$TAS_VARIANT"
        fi;;
esac

# Decided lazily: only needed if some requested firmware name is missing or is our symlink.
VARIANT=""
VARIANT_STATE=""   # "", "ok" or "blocked"
resolve_variant() {
    [ "$VARIANT_STATE" = ok ] && return 0
    [ "$VARIANT_STATE" = blocked ] && return 1
    if [ -n "${TAS_VARIANT:-}" ] && [ "$TAS_VARIANT" != default ]; then
        VARIANT="$TAS_VARIANT"
        ok "firmware variant $VARIANT (from TAS_VARIANT)"
    elif [ "${TAS_VARIANT:-}" != default ] && [ -e "$VARIANT_FILE" ]; then
        if ! [[ "$SAVED" =~ ^[0-9]+$ ]]; then
            bad "$VARIANT_FILE contains '$SAVED', expected a number"
            info "fix it, or clear it with: sudo TAS_VARIANT=default $0 apply"
            VARIANT_STATE=blocked; return 1
        fi
        VARIANT="$SAVED"
        ok "firmware variant $VARIANT (saved in $VARIANT_FILE)"
    else
        case "$SSID" in
            8EA2) VARIANT=1
                  ok "firmware variant 1 (default for board 8EA2, matches HP's Windows driver)";;
            *)
                local vs
                vs="$(cd "$FW_TI" && ls -1 | sed -n "s/^$SSID-\([0-9]\+\)-[0-9]\+-0x.*/\1/p" | sort -u)"
                if [ -z "$vs" ]; then
                    bad "no <SSID>-<variant>-<link>-0x<uid> firmware for $SSID in $FW_TI"
                    info "available for this model: $(cd "$FW_TI" && ls | grep -i "^$SSID" | tr '\n' ' ')"
                    VARIANT_STATE=blocked; return 1
                elif [ "$(echo "$vs" | wc -l)" -eq 1 ]; then
                    VARIANT="$vs"
                    ok "firmware variant $VARIANT (only variant shipped for $SSID)"
                else
                    bad "several firmware variants exist for $SSID ($(echo "$vs" | tr '\n' ' ')) and no known default"
                    info "available: $(cd "$FW_TI" && ls | grep "^$SSID-" | tr '\n' ' ')"
                    info "pick one (see README: checking your variant) and run e.g.:"
                    info "  sudo TAS_VARIANT=1 $0 apply"
                    VARIANT_STATE=blocked; return 1
                fi;;
        esac
    fi
    VARIANT_STATE=ok
}

# ---------------------------------------------------------------- firmware
LINKS=()   # entries: "old_path_or_- linkname target"
if [ ! -d "$FW_TI" ]; then
    bad "$FW_TI missing - install a newer linux-firmware (TI/tas2783 files)"
elif [ -n "$SSID" ]; then
    for a in "${AMPS[@]}"; do
        parse_amp "$a"
        cur="$(find_requested "$WANT")"
        if [ -n "$cur" ] && [ ! -L "$cur" ]; then
            ok "$WANT.bin is a real file (not ours), leaving it alone"
            continue
        fi
        if [ -n "$cur" ] && pkg_owned "$cur"; then
            ok "$WANT.bin is provided by a package ($(readlink "$cur")), leaving it alone"
            continue
        fi
        resolve_variant || continue
        base="$SSID-$VARIANT-$LINK-0x$UID_HEX"
        target=""
        for ext in .bin.zst .bin.xz .bin; do
            if [ -e "$FW_TI/$base$ext" ]; then target="$base$ext"; break; fi
        done
        if [ -z "$target" ]; then
            bad "no firmware $base.* in $FW_TI for $WANT"
            info "available for this model: $(cd "$FW_TI" && ls | grep -i "^$SSID" | tr '\n' ' ')"
            continue
        fi
        name="$WANT${target#"$base"}"
        if [ -n "$cur" ]; then
            if [ "$cur" = "$FW_ROOT/$name" ] && [ "$(readlink "$cur")" = "$FW_REL/$target" ]; then
                ok "$WANT.bin -> $FW_REL/$target"
                continue
            fi
            todo "$WANT.bin points to $(readlink "$cur"); will repoint to $FW_REL/$target"
            LINKS+=("$cur $name $FW_REL/$target")
        else
            todo "$WANT.bin missing; will link to $FW_REL/$target"
            LINKS+=("- $name $FW_REL/$target")
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
    if [ "$BLOCKED" -eq 1 ]; then exit 2; else exit 0; fi
fi
if [ "$MODE" = check ]; then
    echo "Run 'sudo $0 apply' to apply the fix."
    if [ "$BLOCKED" -eq 1 ]; then exit 2; else exit 1; fi
fi

case "$VARIANT_SAVE" in
    "") ;;
    delete) rm -v "$VARIANT_FILE";;
    *) echo "$VARIANT_SAVE" > "$VARIANT_FILE" && echo "saved variant $VARIANT_SAVE to $VARIANT_FILE";;
esac
for e in "${LINKS[@]}"; do
    read -r old name target <<<"$e"
    [ "$old" != - ] && rm -v "$old"
    ln -sfv "$target" "$FW_ROOT/$name"
done
if [ -d "$UCM_DIR" ] && [ ! -f "$UCM_FILE" ]; then
    install -v -m644 "$HERE/tas2783.conf" "$UCM_FILE"
fi
echo
echo "Applied. Reboot so the amp firmware loads, then check: wpctl status"
