# OpenWrt 25.12 Lite for TP-Link TL-WR940N v6

An unofficial **OpenWrt 25.12** build for the **TP-Link TL-WR940N v6 (EU)**. It has WPA3 Wi-Fi, Pi-hole-style ad blocking and a small web admin panel, all in 4 MB of flash and 32 MB of RAM.

OpenWrt stopped publishing images for 4 MB flash / 32 MB RAM routers years ago, because the standard image no longer fits. The device support is still in the OpenWrt source tree. This project trims the build until a current release fits, then adds the features that matter.

> **Unofficial.** This project is not affiliated with or endorsed by the OpenWrt project or TP-Link. Flashing custom firmware can brick your router and voids the warranty. Use it at your own risk, and keep the TFTP recovery method (below) handy.

## Features
- **OpenWrt 25.12.x** (newest 25.12 tag at build time), Linux 6.12.
- **Wi-Fi security:** WPA2/WPA3 mixed by default, plus WPA3-only and WPA2-only modes, using `hostapd-basic-mbedtls`. Includes SAE and Protected Management Frames. WPS is off.
- **Ad blocking** with dnsmasq and the [HaGeZi](https://github.com/hagezi/dns-blocklists) Light list (~57,000 domains).
  - The list downloads over HTTPS, checked against a bundled set of root certificates.
  - It refreshes at boot and every night.
  - From the admin panel you can manage allow/block lists, check whether a domain is blocked, and optionally force every device onto the router's DNS.
  - **Memory guard:** the list is trimmed automatically to fit the available RAM. If DNS ever fails to start with the list, the list is removed so the network keeps working.
- **Firewall:** a strict, small iptables ruleset (no firewall4/nftables). Nothing from the internet gets in except replies. If the rules fail to load, the router locks down to LAN-only.
- **SSH:** LAN only, modern algorithms only (curve25519, chacha20-poly1305, AES-CTR), no forwarding.
- **Web admin panel** (BusyBox httpd and one shell script). Password-protected, and every form carries a security token.
  - **Status:** shows connected devices, Wi-Fi and wired.
  - **Wi-Fi:** network name, password, security mode, country and channel.
  - **Network:** WAN and LAN settings, plus **Access point mode**.
  - **Ad blocking** settings.
  - **Admin:** password, reboot and factory reset.
- **Status light:** **purple** (orange + blue) means everything is working: the router has its address, Wi-Fi is broadcasting and, in router mode, it is handing out addresses. **Orange** alone means something isn't ready.
- **Self-repair:** if saved network settings leave the router unreachable, it restores the built-in settings about a minute after boot.

**Removed to make it fit:** LuCI, PPP/PPPoE, IPv6, the package manager, the full CA bundle, WPS, mesh, Wi-Fi client mode, kernel debugging, seccomp, multicast routing, SSH client/forwarding and unused BusyBox applets.

## How it fits in 4 MB
`build.sh` builds the image and measures it. If it's too big, it applies the next trim level and rebuilds, stopping at the first level that fits.

| Level | Removes | Effect |
|---|---|---|
| 0 | Base trims (always on) | none |
| 1 | Kernel diet: PCI, other boards' drivers, BPF, SysV IPC | none on this board |
| 2 | IPv6 in the kernel | none (IPv6 not used) |
| 3 | Kernel log messages | `dmesg` is empty |
| 4 | 1 MiB squashfs blocks | slightly more RAM for file caching |
| 5 | Parallel-flash drivers, initramfs, policy routing, 5 GHz radar code | none on this board |
| 6 | dnsmasq TFTP server / packet dump / loop detection | none |
| 7 | QoS framework, extra TCP algorithms, BusyBox `vi` | no fq_codel |
| 8 | ethtool netlink | none |
| 9 | IPv6 code in programs | none (currently fails to build; tried last) |

"Fits" means the image fits **and** leaves at least 384 KiB for saved settings. With less than that, the router can't save its configuration reliably.

## Build
You need a Linux machine (x86_64 or arm64). On a Mac, [OrbStack](https://orbstack.dev) with an Ubuntu machine works well. Build inside the Linux home folder, not a shared Mac folder.

```bash
git clone https://github.com/<you>/openwrt-wr940n-v6-lite.git
cd openwrt-wr940n-v6-lite
START=7 ./build.sh          # start with levels 1-7 applied (what currently fits)
```

- The first build downloads the OpenWrt sources and toolchain, so it takes about an hour. Rebuilds take 10–30 minutes.
- Firmware ends up in `output/`.
- Other options:
  - `LEVEL=7 ./build.sh` builds exactly one level.
  - `CONFIG_ONLY=1 ./build.sh` only checks the configuration of every level.

## Flash
Connect by cable to a **yellow** LAN port.

**From the stock TP-Link firmware:**
1. Open `http://192.168.0.1` and go to System Tools → Firmware Upgrade.
2. Upload `…-squashfs-factory-eu.bin`.

**TFTP recovery** (also the unbrick method). The bootloader asks for `wr940nv6_tp_recovery.bin` from `192.168.0.66`.
1. Turn the computer's Wi-Fi off.
2. Set its Ethernet to the manual IP `192.168.0.66` / `255.255.255.0`.
3. Start the included one-file TFTP server (macOS; the second argument is the Ethernet adapter):
   ```bash
   sudo python3 tools/tftp_send.py output/*factory-eu.bin en4
   ```
4. Hold **Reset** while powering the router on, and keep holding for about 15 seconds.
5. The script shows progress and exits when the transfer is complete.
6. **Wait 5 minutes.** The router writes the image and then does a slow first boot.
7. Set the Ethernet back to DHCP.

**Upgrading from this firmware** (keeps your settings). The router has no `scp` receiver, so pipe the file over SSH:
```bash
cat output/*sysupgrade.bin | ssh root@192.168.1.1 'cat > /tmp/fw.bin && sysupgrade /tmp/fw.bin'
```
If ad blocking is active, free up RAM first with `ssh root@192.168.1.1 adblock off`.

## First start
1. Open `http://192.168.1.1/` and set the admin password. It is also the SSH password for `root`.
2. On the **Wi-Fi** page, set the name, password and country. Wi-Fi stays off until you do this.
3. Choose how to connect:
   - **As a router:** plug your internet into the blue WAN port.
   - **As an access point** behind an existing router:
     1. On the **Network** page, give it a free address in your main router's network (for example `192.168.0.2`).
     2. Tick **Access point mode** and enter the main router's address.
     3. Connect a cable from a main-router LAN port to a **yellow** port.
     4. To use ad blocking for the whole house, set the main router's DHCP DNS server to this router's address.

## Buttons and recovery
- **Reset button:** ignored while running, because its input glitches on this board. Use the admin panel to reboot or factory reset. Holding Reset at power-on still starts TFTP recovery.
- **Failsafe mode:**
  1. Tap the **Wi-Fi button** while the light blinks during boot.
  2. Set the computer's Ethernet to `192.168.1.2` / `255.255.255.0`.
  3. Run `ssh root@192.168.1.1`. No password is needed.
  4. Run `mount_root` to edit the saved settings.

## Credits and license
- [OpenWrt](https://openwrt.org) and the Linux kernel, GPL-2.0.
- Blocklists by [HaGeZi](https://github.com/hagezi/dns-blocklists). They are downloaded by the router at runtime, not included in this repository.

The build scripts, configuration and router-side scripts in this repository are licensed under the **GNU General Public License v2.0 or later**; see [LICENSE](LICENSE).
