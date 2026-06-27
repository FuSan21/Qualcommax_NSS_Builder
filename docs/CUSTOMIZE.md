# Customizing the build

All knobs live in the **`env:` block of [`.github/workflows/build.yml`](../.github/workflows/build.yml)**,
the **[device `.config`](../devices/xiaomi_ax3600/config)**, and the overlay directories. This page
shows what each one does.

## Build parameters (`build.yml` → `env:`)

```yaml
env:
  UPSTREAM_REPO: JuliusBairaktaris/openwrt-nss-edma   # OpenWrt source tree
  UPSTREAM_REF: nss-edma-rework                       # branch, tag, or 40-char SHA
  NSS_REPO: JuliusBairaktaris/nss-packages            # NSS packages repo (blank to disable)
  NSS_REF: edma-nss
  TARGET: qualcommax/ipq807x                          # bin/targets/<target>/
  DEVICE: xiaomi_ax3600                               # selects devices/<id>/
  VARIANT: edma-nss                                   # selects devices/<id>/files.<variant>
  RELEASE_PREFIX: edma-nss                            # tag = <prefix>-<ts>-<run id>
  KEEP: "2"                                           # newest releases to retain
  FEEDS: "src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss"
```

When the build runs depends on the trigger:
- **schedule** → `check` skips the build when the upstream is unchanged since the last release
  (this is the "rebuild when upstream moves" path).
- **push** → always rebuilt — a push to this repo means the config, overlays, or scripts changed,
  so the image must be regenerated.
- **Run workflow** (`workflow_dispatch`) → always rebuilt.

## Device `.config`

The whole `.config` is [`devices/xiaomi_ax3600/config`](../devices/xiaomi_ax3600/config); `prepare-build.sh`
copies it to `.config` and runs `make defconfig`. To change something, edit in a real OpenWrt checkout
and diff back:

```sh
git clone --branch nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cp devices/xiaomi_ax3600/config openwrt/.config
cd openwrt && make menuconfig
./scripts/diffconfig.sh > /tmp/full.config        # minimal .config (deltas only)
# then copy /tmp/full.config back to devices/xiaomi_ax3600/config
```

Symbols that don't exist on the upstream are dropped silently by `make defconfig`.

## Custom feeds

Each `src-git <name> <url>` line in `FEEDS` is appended to `feeds.conf` and updated/installed
individually. The corresponding `CONFIG_FEED_<name>` is then set to `n` so you don't bundle every
package from the feed — only what you explicitly enable in `.config` ships.

## Rootfs overlay

Two overlay layers, applied in order (later wins):

1. `devices/xiaomi_ax3600/files/` — base
2. `devices/xiaomi_ax3600/files.edma-nss/` — variant-specific

Anything under these is copied to the image root, preserving paths. Special handling:
- `etc/ssh/sshd_config` is `chmod 0600`'d automatically
- `etc/uci-defaults/<name>` files run once on first boot, then are deleted
- `etc/rc.local` runs on every boot

## Cron schedule

GitHub Actions requires `cron:` values to be static. Edit [`.github/workflows/build.yml`](../.github/workflows/build.yml):

```yaml
on:
  schedule:
    - cron: "0 */2 * * *"            # every 2 hours
```

Use [crontab.guru](https://crontab.guru) if you're unsure.

## Disabling caching

This build does not use `actions/cache` and explicitly sets `# CONFIG_CCACHE is not set` in the
config. ccache without persistent storage is a no-op on fresh runners, and `actions/cache` for
OpenWrt's multi-GB build dir is a footgun (easily corrupts mid-build).

## Disabling the schedule

If you only want manual builds, remove the `schedule:` block from `build.yml` (keep
`workflow_dispatch` and `push`).
