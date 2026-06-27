# Qualcommax NSS Builder

### OpenWrt firmware builder for the Xiaomi AX3600 — NSS offload on the upstream EDMA drivers

[![Build](https://img.shields.io/github/actions/workflow/status/JuliusBairaktaris/Qualcommax_NSS_Builder/build.yml?branch=main&style=flat-square&logo=github&label=Build)](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder/actions/workflows/build.yml)
[![Lint](https://img.shields.io/github/actions/workflow/status/JuliusBairaktaris/Qualcommax_NSS_Builder/lint.yml?branch=main&style=flat-square&logo=github&label=Lint)](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder/actions/workflows/lint.yml)
[![License](https://img.shields.io/github/license/JuliusBairaktaris/Qualcommax_NSS_Builder?style=flat-square&label=License)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/JuliusBairaktaris/Qualcommax_NSS_Builder?style=flat-square&label=Last%20Commit)](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder/commits/main)

A GitHub Actions pipeline that builds one OpenWrt image — **`edma-nss`**: Qualcomm NSS hardware
offloading running on **OpenWrt main's upstream `qca-edma`/`qca-ppe` ethernet drivers**
([PR #22381](https://github.com/openwrt/openwrt/pull/22381)) — built from
[openwrt-nss-edma](https://github.com/JuliusBairaktaris/openwrt-nss-edma) and
[nss-packages](https://github.com/JuliusBairaktaris/nss-packages), for the Xiaomi AX3600.

- **No caching** — fresh runner every build, predictable output, no cache-poisoning surface
- **Auto-rebuild** — builds on push and every 2 hours, skipped while both source trees are unchanged
- **Tested release pruning** — "keep last N" has unit tests
- **Linted pipeline** — `actionlint`, `shellcheck`, `yamllint` run on every PR
- **Reproducible builds** — pinned `SOURCE_DATE_EPOCH`, fixed locale, no ccache

---

## The `edma-nss` image

| | `edma-nss` |
|---|---|
| **OpenWrt tree** | [`JuliusBairaktaris/openwrt-nss-edma`](https://github.com/JuliusBairaktaris/openwrt-nss-edma) @ `nss-edma-rework` (OpenWrt main + PR #22381 + the NSS integration series) |
| **NSS packages** | [`JuliusBairaktaris/nss-packages`](https://github.com/JuliusBairaktaris/nss-packages) @ `edma-nss` (drv, ECM, qdisc/igs/pppoe clients, firmware 12.5, `sqm-scripts-nss`) |
| **Ethernet** | the upstream `qca-edma` DSA driver, with the firmware data plane attached at runtime |
| **Offload** | ECM NAT/PPPoE, NSS SQM (`nss-edma.qos`), ath11k NSS Wi-Fi offload (wifili) |
| **Builds on** | schedule + push (auto, skipped while both source trees are unchanged) |
| **Release tag** | `edma-nss-<ts>-<run>` |

This is, to our knowledge, the first NSS stack that keeps the upstream ethernet drivers instead of the vendor `qca-nss-dp`/`qca-ssdk` pairing. Architecture, runtime model, measured results and limitations are documented in the **[openwrt-nss-edma wiki](https://github.com/JuliusBairaktaris/openwrt-nss-edma/wiki)**.

**Runtime model:** the image boots on the plain host stack (Wi-Fi in host mode — loading the NSS modules is inert by design). `/usr/sbin/nss-up`, invoked from `rc.local`, arms the NSS data plane, boots the firmware, moves the radios onto the wifili data path and starts ECM + SQM. A reboot always returns to the stock host-only stack — that is the universal recovery path. Remove the `nss-up` line from `/etc/rc.local` to stay on the host stack permanently.

---

## Repo layout

```
.
├── devices/
│   └── xiaomi_ax3600/
│       ├── config                   # the .config (target, toolchain, hardening, NSS packages)
│       ├── files/                   # base rootfs overlay (sshd_config, QoL uci-defaults)
│       └── files.edma-nss/          # edma-nss overlay (nss-up, sqm + offload settings)
├── scripts/                         # bash helpers (tested, linted)
│   ├── check-updates.sh             # resolve SHAs, skip a build when upstreams are unchanged
│   ├── prepare-build.sh             # feeds, assemble .config, overlays
│   ├── prune-releases.sh            # keep newest N releases
│   └── tests/
├── docs/
│   ├── CUSTOMIZE.md
│   └── ARCHITECTURE.md
└── .github/workflows/
    ├── build.yml                    # env block + check -> build -> prune
    └── lint.yml                     # actionlint + shellcheck + yamllint + prune tests
```

---

## How the pipeline works

```
check -> build -> prune
```

| Job | Purpose |
|---|---|
| `check` | Resolves the upstream (and NSS) ref to a commit SHA; on a scheduled tick it skips the build when the latest release already records that SHA (push + manual runs always build) |
| `build` | Checks out the upstream at the pinned SHA, applies the config + overlays, compiles, creates a GitHub Release |
| `prune` | Keeps the newest `KEEP` releases (`scripts/prune-releases.sh`) |

Every parameter (upstream, NSS, target, device, feed, retention) lives in the `env:` block at the
top of [`.github/workflows/build.yml`](.github/workflows/build.yml). The cron schedule lives there
too — GitHub Actions requires it as a static string.

---

## Reference build: Xiaomi AX3600 (IPQ8071A)

### NSS hardware acceleration on upstream drivers

The IPQ807x SoC has dedicated Network Subsystem cores. Without NSS, all NAT/bridge/VLAN traffic hits the ARM CPU. Measured on this stack (AX3600, NSS.FW.12.5-210, kernel 6.12; details in the [wiki](https://github.com/JuliusBairaktaris/openwrt-nss-edma/wiki)):

| Metric | Host path | NSS offload (`edma-nss`) |
|---|---|---|
| 311 Mbit/s PPPoE NAT | ~42% of one core (softirq) | **~99.7% CPU idle** |
| SQM at 285 Mbit ingress | CPU-bound | **258 Mbit goodput, ~99% idle** |
| RTT under shaped load | high (bufferbloat) | **16 ms avg vs 20 idle — flat** |
| Wi-Fi data path | mac80211/ath11k on CPU | **wifili on the NSS cores** |

Enabled NSS modules: `kmod-qca-nss-drv` (+ the `kmod-qca-ppe-nss` glue), `kmod-qca-nss-ecm`, `kmod-qca-nss-drv-pppoe`, `kmod-qca-nss-drv-qdisc`/`-igs`, `sqm-scripts-nss` (`nss-edma.qos`), ath11k NSS Wi-Fi offload (`CONFIG_ATH11K_NSS_SUPPORT`).

### Security hardening

- **OpenSSH** (Dropbear disabled) with post-quantum KEX (ML-KEM 768, sntrup761), AEAD ciphers only, ETM MACs, RSA min 3072
- **Build hardening**: `PKG_ASLR_PIE_ALL`, `PKG_CC_STACKPROTECTOR_ALL`, `PKG_FORTIFY_SOURCE_3`, `PKG_RELRO_FULL`, `USE_SECCOMP`, `PKG_CHECK_FORMAT_SECURITY`
- **Firewall**: WAN input/forward = DROP, HTTPS redirect, BCP38 anti-spoofing
- **OQS provider** loaded into OpenSSL for hybrid post-quantum TLS

### Toolchain

| Component | Setting |
|---|---|
| GCC | 15 + Graphite loops |
| Binutils | 2.46 |
| Linker | Mold |
| LTO | enabled |
| Target flags | `-O2 -pipe -mcpu=cortex-a53+crc+crypto` |
| ccache | **disabled** (no caching policy) |

> Toolchain version pins live in [`devices/xiaomi_ax3600/config`](devices/xiaomi_ax3600/config).

### Flashing

Grab the `*-sysupgrade.bin` from the newest `edma-nss-*` release ([Releases](https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder/releases)) and:

```sh
sysupgrade -n /tmp/openwrt-qualcommax-ipq807x-xiaomi_ax3600-squashfs-sysupgrade.bin
```

Or via LuCI: **System → Backup / Flash Firmware**, upload, uncheck "Keep settings" for a first-time flash. Coming from stock Xiaomi? Install OpenWrt first via the [official guide](https://openwrt.org/toh/xiaomi/ax3600).

---

## Customizing

| What | Where |
|---|---|
| Upstream / NSS / target / device / feed / retention | [`.github/workflows/build.yml`](.github/workflows/build.yml) → `env:` |
| Build cron | [`.github/workflows/build.yml`](.github/workflows/build.yml) → `on.schedule` |
| Package selection | [`devices/xiaomi_ax3600/config`](devices/xiaomi_ax3600/config) |
| Rootfs overlay | `devices/xiaomi_ax3600/files/`, `devices/xiaomi_ax3600/files.edma-nss/` |

See [`docs/CUSTOMIZE.md`](docs/CUSTOMIZE.md) for the long version.

---

## Contributing

Issues and PRs welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Acknowledgements

- **[Ansuel (Christian Marangi)](https://github.com/Ansuel)** — the [EDMA rework](https://github.com/openwrt/openwrt/pull/22381) this stack builds on
- **[qosmio](https://github.com/qosmio)** — NSS development, the [openwrt-ipq](https://github.com/qosmio/openwrt-ipq) tree, and the Wi-Fi offload patch lineage
- **[rodriguezst](https://github.com/rodriguezst)** — original [ipq807x-openwrt-builder](https://github.com/rodriguezst/ipq807x-openwrt-builder) inspiration
- **OpenWrt community** — the long-running [IPQ807x NSS Build thread](https://forum.openwrt.org/t/ipq807x-nss-build/148529)

---

## License

[GPL-2.0](LICENSE), consistent with OpenWrt.
