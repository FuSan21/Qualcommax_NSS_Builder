# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not** an OpenWrt source tree — it's a thin GitHub Actions builder that assembles an
OpenWrt image for the Xiaomi AX3600 (Qualcomm IPQ8071A) from external sources:

- [`JuliusBairaktaris/openwrt-nss-edma`](https://github.com/JuliusBairaktaris/openwrt-nss-edma) — OpenWrt fork, upstream `qca_edma`/`qca_ppe` drivers (rebased on `openwrt/main`)
- [`JuliusBairaktaris/nss-packages`](https://github.com/JuliusBairaktaris/nss-packages), `edma-nss` branch — NSS packages feed

This repo contributes only: a `.config`, two rootfs overlay layers, one feed patch, and the
scripts/workflow that glue them together. All NSS runtime tooling (`nss-up`, `nss-status`, the
`nss` boot service, `nssqos`) lives upstream as regular packages — this repo does not author or
vendor that code.

## Commands

```sh
# Run prune-releases unit tests (pure bash + jq, no network)
bash scripts/tests/prune-releases.test.sh

# Exercise check-updates.sh locally (needs git + gh, hits the network)
UPSTREAM_REPO=JuliusBairaktaris/openwrt-nss-edma UPSTREAM_REF=nss-edma-rework \
  RELEASE_PREFIX=edma-nss EVENT_NAME=workflow_dispatch bash scripts/check-updates.sh

# Lint (what CI's lint.yml runs)
shellcheck -x scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}}}" .github/workflows/
# actionlint: see .github/workflows/lint.yml for the pinned download-and-run invocation

# Full local image build (2-6h, mirrors what build.yml's `build` job does)
git clone --branch nss-edma-rework https://github.com/JuliusBairaktaris/openwrt-nss-edma openwrt
cd openwrt
cp feeds.conf.default feeds.conf
echo "src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;edma-nss" >> feeds.conf
./scripts/feeds update -a && ./scripts/feeds install -a
cp ../Qualcommax_NSS_Builder/devices/xiaomi_ax3600/config .config
make defconfig && make -j"$(nproc)"
```

There is no build/lint/test command for this repo itself beyond the above — it has no
application code, just shell scripts, a `.config`, and rootfs overlay files.

## Architecture

Full detail in `docs/ARCHITECTURE.md` and `docs/CUSTOMIZE.md`; this is the map for orienting quickly.

### Pipeline: `check` → `build` → `prune` (`.github/workflows/build.yml`)

- **`check`** (`scripts/check-updates.sh`): resolves `UPSTREAM_REF`/`NSS_REF` to commit SHAs via
  `git ls-remote`. On a `schedule` trigger, skips the build if the latest release already records
  those SHAs; on `push` or `workflow_dispatch` it always rebuilds. Also expands the `theme` input
  into a matrix (`argon`, `i-love-luci`, or both).
- **`build`** (`scripts/prepare-build.sh`, matrixed per theme): checks out the OpenWrt source at
  the pinned SHA, checks out this repo alongside it, runs `prepare-build.sh` to assemble feeds +
  `.config` + overlay, sets reproducible-build env vars (`SOURCE_DATE_EPOCH` from the upstream
  commit, `TZ=UTC`, etc.), compiles (retries single-threaded with `V=s` on failure for
  diagnostics), then publishes a GitHub release tagged `<RELEASE_PREFIX>-<theme>-<timestamp>-<run
  id>` with the release body recording the resolved SHAs (this is what the next scheduled `check`
  reads back).
- **`prune`** (`scripts/prune-releases.sh`): deletes all but the newest `KEEP` non-draft releases.
  Has real unit tests (`scripts/tests/prune-releases.test.sh`) because it's destructive and once
  had a silent "keep last N" bug — anything you change here should be re-verified against those
  tests, and new edge cases should get a new `run_case`.

Every build parameter (upstream/NSS repo+ref, target, device, variant, release prefix, retention,
feeds, cron) lives in the `env:` block at the top of `build.yml` — that block is the single place
to edit, not a separate config file.

### `prepare-build.sh` responsibilities (in order)

1. Append custom `FEEDS` entries to `feeds.conf`, update/install each individually, then
   `feeds update -a && feeds install -a`.
2. Apply local patches from `patches/feeds/<variant>/<feed>/*.patch` to the checked-out feed source
   (checked with `--dry-run` first so already-applied patches are skipped, not double-applied), so
   a patch rides only the flavour it is for.
3. Clone the selected `THEME` (`argon` or `i-love-luci`) into `package/` with `.git` stripped so
   the OpenWrt build doesn't treat it as a submodule.
4. Copy `devices/<DEVICE>/config` to `.config`, append theme package selects, run `make defconfig`.
5. Force custom feed packages to `# CONFIG_FEED_<name> is not set` so only explicitly-enabled
   packages from a feed ship (not the whole feed).
6. Layer overlay files: `devices/<DEVICE>/files/` then `devices/<DEVICE>/files.<VARIANT>/`
   (rsync'd in that order onto `files/`, so the variant layer wins on conflicts). `sshd_config` is
   force-`chmod 0600`'d afterward.

### Repo layout

```
devices/xiaomi_ax3600/
  config                 # the whole .config: target, toolchain, hardening, NSS packages, THEME pins added at build time
  files/                 # base rootfs overlay (sshd_config, QoL uci-defaults)
  files.edma-nss/        # edma-nss variant overlay (SQM template, rc.local)
patches/feeds/<variant>/<feed>/     # patches applied to feed source before defconfig, per flavour (edma-nss: luci NSS DSCP column; ppe: sqm-scripts pin)
scripts/                 # check-updates.sh, prepare-build.sh, prune-releases.sh — all set -euo pipefail, source scripts/lib/log.sh
docs/                    # ARCHITECTURE.md (pipeline rationale), CUSTOMIZE.md (every knob explained)
```

### Design decisions worth knowing before "fixing" something

- **Only ccache is cached** (inherited from upstream): `CONFIG_CCACHE=y` in `devices/common/config`,
  and `build.yml` saves `openwrt/.ccache` with `actions/cache`, keyed on a hash of the toolchain
  inputs, so a toolchain change starts from an empty cache. The build dir itself is never cached:
  it's too big for the cache limits, and a corrupted copy can produce broken images that look fine.
  `docs/ARCHITECTURE.md`'s "Why no caching?" and `docs/CUSTOMIZE.md`'s "Disabling caching" predate
  this and are stale on that point.
- **Feeds are updated with `feeds update`, never `git pull`**: both `openwrt-nss-edma` and the
  `edma-nss` feed are periodically rebased, so a plain pull can fail or merge badly. This matters
  for anyone debugging a "stale feed" build failure locally.
- **`nss-up` has a commented-out multicast daemon start stage** — intentionally inert because the
  reference network has no IPTV source. Don't "fix" this by uncommenting it upstream; it's a
  documented opt-in (see `docs/CUSTOMIZE.md`'s routed-multicast section).
- **Overlay layering order matters**: `files/` is base, `files.<VARIANT>/` is applied after and
  wins. When adding a file, decide deliberately whether it belongs in the base or the variant
  layer.
- Symbols in `devices/xiaomi_ax3600/config` that don't exist upstream are dropped silently by
  `make defconfig` — if a config addition seems to have no effect, verify the symbol still exists
  upstream rather than assuming the pipeline is broken.

## Contribution conventions (from `CONTRIBUTING.md`)

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `ci:` — body
  explains the *why*.
- Bash: `set -euo pipefail`, `source scripts/lib/log.sh`, two-space indent.
- If you touch `scripts/prune-releases.sh`, run `scripts/tests/prune-releases.test.sh` before
  opening a PR. The Lint workflow (`actionlint`, `shellcheck`, `yamllint`) runs on any PR touching
  `.github/workflows/**` or `scripts/**` — fix red lint rather than disabling the check.
