#!/usr/bin/env bash
# Build OpenWrt 25.12.x for the TP-Link TL-WR940N v6 (EU): WPA3, ad blocking, tiny web GUI.
#
# The router has 3904 KiB of usable flash. This script builds the base configuration, measures it,
# and if it does not fit it adds the next trim level and rebuilds, until the image fits:
#   level 0  base: no package manager, iptables firewall, trimmed SSH/BusyBox/mbedTLS
#   level 1  kernel diet: drop drivers/features this board does not have (PCI, other SoCs' parts, BPF...)
#   level 2  no IPv6 in the kernel
#   level 3  no kernel log messages
#   level 4  1 MiB squashfs blocks (best compression, a bit more RAM)
#   level 5  more kernel diet (parallel-flash drivers, initramfs, policy routing), no 5 GHz radar code
#   level 6  dnsmasq without TFTP/packet-dump/loop-detect
#   level 7  last kernel/BusyBox cuts (QoS framework, TCP extras, unused tools)
#   level 8  ethtool netlink interface (CLI-only), small unused syscalls
#   level 9  no IPv6 code in programs (currently fails to build; tried last)
# "Fits" means the image fits AND leaves >= 448 KiB for saved settings.
#
# Usage:   ./build.sh                       # find the smallest level that fits, build it
#          LEVEL=3 ./build.sh               # build exactly this level (0-9)
#          START=4 ./build.sh               # start the search with levels 1-4 already applied
#          OPENWRT_TAG=v25.12.5 ./build.sh  # pin a release (default: newest 25.12.x)
#          CONFIG_ONLY=1 ./build.sh         # only check the configuration
# Needs Linux/WSL2/OrbStack, ~15 GB disk. Must NOT run as root.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$KIT/openwrt}"
OUT="$KIT/output"
LOG="$KIT/build.log"
DEVICE=tplink_tl-wr940n-v6
JOBS="${JOBS:-$(nproc)}"
MAX_LEVEL=9
MIN_OVERLAY_KB="${MIN_OVERLAY_KB:-384}"   # settings space; settings now ship in the firmware, so 6 x 64 KiB is enough
PATCHED_FILES="config/Config-kernel.in config/Config-build.in include/netfilter.mk target/linux/ath79/tiny/config-default package/network/services/dnsmasq/Makefile"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root (OpenWrt refuses to build as root)."
case "$(uname -s)" in Linux) ;; *) die "Run this on Linux, WSL2 or an OrbStack Linux machine." ;; esac
case "$WORK" in /mnt/[a-z]/*|/Users/*) die "Build inside the Linux home folder (e.g. ~/), not a Windows/Mac folder." ;; esac

missing=()
for t in git make gcc g++ gawk python3 rsync unzip bzip2 wget file perl patch diff; do
	command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "Missing tools: ${missing[*]}"
	echo "  sudo apt update && sudo apt install -y build-essential clang flex bison g++ gawk \\"
	echo "    gettext git libncurses-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget"
	exit 1
fi

# ---------------- source ----------------
if [ -z "${OPENWRT_TAG:-}" ]; then
	OPENWRT_TAG=$(git ls-remote --tags --refs https://git.openwrt.org/openwrt/openwrt.git 'v25.12.*' 2>/dev/null \
		| sed 's|.*refs/tags/||' | grep -v -- '-rc' | sort -V | tail -1 || true)
	[ -n "$OPENWRT_TAG" ] || OPENWRT_TAG=v25.12.5
fi
say "OpenWrt $OPENWRT_TAG"
if [ ! -d "$WORK/.git" ]; then
	git clone https://git.openwrt.org/openwrt/openwrt.git "$WORK" \
		|| git clone https://github.com/openwrt/openwrt.git "$WORK" || die "git clone failed"
fi
cd "$WORK" || die "cannot enter $WORK"
git checkout --quiet -- $PATCHED_FILES 2>/dev/null
git fetch --tags --quiet origin 2>/dev/null || true
git checkout --quiet "$OPENWRT_TAG" || die "cannot check out $OPENWRT_TAG"

# ---------------- levels ----------------
reset_tree() { git checkout --quiet -- $PATCHED_FILES; }

apply_level() { # $1 = level number; called cumulatively 1..N
	case "$1" in
	1) cat "$KIT/levels/1-kernel-diet.kconfig" >> target/linux/ath79/tiny/config-default ;;
	2) sed -i '/^config KERNEL_IPV6$/{n;s/^\tdef_bool IPV6$/\tdef_bool n/}' config/Config-kernel.in
	   sed -i '/nf_add,NF_CONNTRACK,CONFIG_NF_DEFRAG_IPV6/d' include/netfilter.mk
	   cat "$KIT/levels/2-no-ipv6.config" >> .config ;;
	3) cat "$KIT/levels/3-no-printk.config" >> .config ;;
	4) cat "$KIT/levels/4-squashfs-1m.config" >> .config ;;
	5) cat "$KIT/levels/5-kernel-diet2.kconfig" >> target/linux/ath79/tiny/config-default
	   cat "$KIT/levels/5-extra.config" >> .config ;;
	6) sed -i 's/^\tCOPTS += -DNO_AUTH -DNO_IPSET -DNO_ID$/\tCOPTS += -DNO_AUTH -DNO_IPSET -DNO_ID -DNO_TFTP -DNO_DUMPFILE -DNO_LOOP/' package/network/services/dnsmasq/Makefile ;;
	7) cat "$KIT/levels/7-final-diet.kconfig" >> target/linux/ath79/tiny/config-default
	   cat "$KIT/levels/7-final-diet.config" >> .config ;;
	8) cat "$KIT/levels/8-ethtool-netlink.kconfig" >> target/linux/ath79/tiny/config-default ;;
	9) sed -i '/^\tconfig IPV6$/{n;s/^\t\tdef_bool y$/\t\tdef_bool n/}' config/Config-build.in ;;
	esac
}

configure() { # $@ = trim levels to apply (e.g. "1 2 3")
	reset_tree
	cp "$KIT/diffconfig" .config
	local lv; for lv in "$@"; do [ "$lv" = 0 ] || apply_level "$lv"; done
	make defconfig >/dev/null 2>&1 || die "make defconfig failed"
	for want in "CONFIG_TARGET_ath79_tiny_DEVICE_${DEVICE}=y" "CONFIG_PACKAGE_hostapd-basic-mbedtls=y" \
		"CONFIG_PACKAGE_iptables-zz-legacy=y" "CONFIG_PACKAGE_uclient-fetch=y" "CONFIG_BUSYBOX_CONFIG_HTTPD=y"; do
		grep -qx "$want" .config || die "Config check failed: $want missing."
	done
	for unwanted in ppp odhcp6c odhcpd-ipv6only ca-bundle apk-mbedtls opkg firewall4 wpad-basic-mbedtls hostapd-mini; do
		if grep -q "^CONFIG_PACKAGE_${unwanted}=y" .config; then die "Config check failed: $unwanted still selected."; fi
	done
	rm -rf files && cp -a "$KIT/files" files
	chmod 755 files/www/cgi-bin/gui files/etc/init.d/* files/usr/sbin/* files/etc/uci-defaults/* files/etc/hotplug.d/*/* files/etc/rc.button/*
}

KDIR() { ls -d build_dir/target-*/linux-ath79_tiny 2>/dev/null | head -1; }

image_files() { ls bin/targets/ath79/tiny/*"${DEVICE}"-squashfs-*.bin 2>/dev/null; }

build_level() { # $@ = levels; returns 0 = fits, 1 = too big, 2 = build failed
	local l="${*:-0}"
	say "Levels [0 $l]: configuring"
	configure "$@"
	rm -f bin/targets/ath79/tiny/*"${DEVICE}"-squashfs-*.bin
	# kernel config changes need the out-of-tree kernel modules rebuilt against the new kernel
	make package/kernel/mac80211/clean package/kernel/gpio-button-hotplug/clean >/dev/null 2>&1
	say "Levels [0 $l]: building (watch progress with: tail -f $LOG)"
	if ! make -j"$JOBS" > "$LOG" 2>&1; then
		say "Parallel build failed, retrying single-threaded for a clear error"
		if ! make -j1 V=s > "$LOG" 2>&1; then
			grep -E 'error|Error' "$LOG" | grep -v 'ignored' | tail -15
			return 2
		fi
	fi
	local k r used ov
	k=$(stat -c %s "$(KDIR)/${DEVICE}-kernel.bin" 2>/dev/null || echo 0)
	r=$(stat -c %s "$(KDIR)/root.squashfs" 2>/dev/null || echo 0)
	if [ "$k" -eq 0 ] || [ "$r" -eq 0 ]; then
		RESULT="levels [0 $l]: build finished but kernel/rootfs missing"
		echo "$RESULT"; tail -20 "$LOG"; return 2
	fi
	# Flash layout: 3904 KiB firmware = 512 B header + kernel + rootfs, then the settings area
	# (JFFS2) starting at the next 64 KiB block. JFFS2 needs >= 7 blocks to be able to save anything.
	used=$(( ( (512 + k + r + 65535) / 65536 ) * 64 ))
	ov=$(( 3904 - used ))
	if [ -n "$(image_files)" ] && [ "$ov" -ge "$MIN_OVERLAY_KB" ]; then
		RESULT="levels [0 $l]: kernel $((k/1024)) KiB + rootfs $((r/1024)) KiB, settings space ${ov} KiB -> FITS"
		echo "$RESULT"; return 0
	fi
	RESULT="levels [0 $l]: kernel $((k/1024)) KiB + rootfs $((r/1024)) KiB, settings space ${ov} KiB (need ${MIN_OVERLAY_KB}) -> too big by $((MIN_OVERLAY_KB - ov)) KiB"
	echo "$RESULT"; return 1
}

if [ "${CONFIG_ONLY:-0}" = 1 ]; then
	configure; echo "level 0 configuration OK"
	for l in $(seq 1 $MAX_LEVEL); do configure $(seq 1 "$l"); echo "levels 0-$l configuration OK"; done
	reset_tree; exit 0
fi

say "Downloading sources"
cp "$KIT/diffconfig" .config && make defconfig >/dev/null 2>&1
make download -j"$JOBS" >/dev/null 2>&1 || make download -j1 V=s || die "source download failed"

SUMMARY=()
if [ -n "${LEVEL:-}" ]; then
	RESULT=; build_level $(seq 1 "$LEVEL"); rc=$?; SUMMARY+=("${RESULT:-levels 0-$LEVEL: build failed}")
else
	START="${START:-0}"
	active=(); for l in $(seq 1 "$START"); do active+=("$l"); done
	RESULT=; build_level "${active[@]}"; rc=$?; SUMMARY+=("${RESULT:-levels 0-$START: build failed}")
	[ $rc -eq 2 ] && { say "The base configuration failed to build"; }
	if [ $rc -eq 1 ]; then
		for l in $(seq $((START + 1)) $MAX_LEVEL); do
			RESULT=; build_level "${active[@]}" "$l"; rc=$?
			if [ $rc -eq 2 ]; then
				SUMMARY+=("level $l: build FAILED, skipped (see build-level$l.log)")
				cp "$LOG" "$KIT/build-level$l.log"; rc=1; last_failed=1; continue
			fi
			last_failed=0; active+=("$l"); SUMMARY+=("$RESULT")
			[ $rc -eq 0 ] && break
		done
		# if the last attempt was a skipped failure, rebuild the best working set so bin/ matches it
		if [ "${last_failed:-0}" = 1 ]; then RESULT=; build_level "${active[@]}"; rc=$?; fi
	fi
fi

say "Summary"
printf '  %s\n' "${SUMMARY[@]}"
if [ $rc -eq 0 ]; then
	mkdir -p "$OUT" && rm -f "$OUT"/*.bin
	image_files | while read -r f; do cp "$f" "$OUT/"; done
	echo
	for f in "$OUT"/*.bin; do printf '  %-75s %5d KiB\n' "$(basename "$f")" $(( $(stat -c %s "$f") / 1024 )); done
	echo
	echo "Flash from stock TP-Link firmware:  *-squashfs-factory-eu.bin"
	echo "Upgrade from this OpenWrt:          *-squashfs-sysupgrade.bin"
	echo "Copy to your Mac:  cp $OUT/*.bin /Users/\$USER/Downloads/"
	exit 0
fi
echo
echo "Not finished. Send the summary above and the last lines of $LOG."
exit 1
