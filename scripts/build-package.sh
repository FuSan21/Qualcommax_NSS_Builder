#!/usr/bin/env bash
# Build one OpenWrt package as an .apk against the official SDK for TARGET.
#
# Why the snapshot SDK and not a 24.10 one: the images this repo builds come
# from an openwrt/main fork, and main installs packages with apk. The 24.10
# release line is still opkg/ipk, so its SDK cannot produce a file the router
# can install.
#
# luci-app packages are LUCI_PKGARCH:=all, so the .apk this produces is
# arch-independent - TARGET only decides which luci feed revision the package
# is built against, which is why it should match the image's target.
#
# Inputs (environment):
#   TARGET       target/subtarget, e.g. qualcommax/ipq807x   (required)
#   PKG_NAME     package name, e.g. luci-app-webauthn        (required)
#   PKG_SRC      directory holding the package Makefile      (required)
#   OUT_DIR      directory the built .apk files are copied to (required)
#   PKG_VERSION  version to inject; unset leaves the Makefile alone
#   PKG_RELEASE  release to inject alongside PKG_VERSION (default 1)
#   SDK_BASE     SDK download directory (default: snapshots for TARGET)
#   SDK_DIR      where the SDK is unpacked (default: ./sdk)
set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

: "${TARGET:?TARGET is required, e.g. qualcommax/ipq807x}"
: "${PKG_NAME:?PKG_NAME is required, e.g. luci-app-webauthn}"
: "${PKG_SRC:?PKG_SRC is required, the directory holding the package Makefile}"
: "${OUT_DIR:?OUT_DIR is required, the directory built .apk files are copied to}"

SDK_BASE="${SDK_BASE:-https://downloads.openwrt.org/snapshots/targets/${TARGET}}"
SDK_DIR="${SDK_DIR:-${PWD}/sdk}"
PKG_VERSION="${PKG_VERSION:-}"
PKG_RELEASE="${PKG_RELEASE:-1}"

PKG_SRC=$(cd -- "$PKG_SRC" && pwd)
[[ -f "${PKG_SRC}/Makefile" ]] || log::die "no Makefile in ${PKG_SRC}"
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd)

fetch_sdk() {
  local index name
  log::info "Resolving SDK from ${SDK_BASE}/"
  index=$(curl -fsSL "${SDK_BASE}/") || log::die "cannot list ${SDK_BASE}/"

  # The snapshot filename carries the compiler version, so it moves. Read it
  # out of the directory index rather than pinning a name that rots.
  name=$(grep -oE 'openwrt-sdk-[^"]+\.tar\.(xz|zst)' <<<"$index" | sort -u | head -n1)
  [[ -n "$name" ]] || log::die "no SDK tarball listed at ${SDK_BASE}/"
  log::info "SDK tarball: ${name}"

  curl -fsSL -o "$name" "${SDK_BASE}/${name}"
  curl -fsSL -o sha256sums "${SDK_BASE}/sha256sums"
  # Snapshots are rebuilt daily and served over plain mirrors; verify the
  # tarball against the published sums before unpacking it.
  grep -F " *${name}" sha256sums >sha256sums.sdk || log::die "no checksum published for ${name}"
  sha256sum -c sha256sums.sdk || log::die "SDK checksum mismatch"

  rm -rf "$SDK_DIR"
  mkdir -p "$SDK_DIR"
  tar -xf "$name" --strip-components=1 -C "$SDK_DIR"
  rm -f "$name" sha256sums sha256sums.sdk
}

prepare_feeds() {
  log::info "Updating feeds"
  ./scripts/feeds update -a
  # install -a is best-effort: a single unsatisfiable package in a feed must
  # not fail the run. The luci-base check below is the real gate.
  ./scripts/feeds install -a || log::warn "feeds install -a reported errors; continuing"
  [[ -d package/feeds/luci/luci-base ]] || log::die "luci feed missing after install"
}

stage_package() {
  log::info "Staging ${PKG_NAME} from ${PKG_SRC}"
  rm -rf "package/${PKG_NAME}"
  mkdir -p "package/${PKG_NAME}"
  rsync -a --delete --exclude '.git' "${PKG_SRC}/" "package/${PKG_NAME}/"
}

inject_version() {
  local mk="package/${PKG_NAME}/Makefile"

  [[ -n "$PKG_VERSION" ]] || { log::info "no PKG_VERSION given; using the Makefile as-is"; return; }
  if grep -q '^PKG_VERSION:=' "$mk"; then
    log::info "Makefile pins PKG_VERSION; leaving it alone"
    return
  fi

  # luci.mk falls back to a git-derived version, and the staged copy has no
  # .git. Pin it so the .apk carries the upstream commit it was built from.
  log::info "Injecting PKG_VERSION=${PKG_VERSION} PKG_RELEASE=${PKG_RELEASE}"
  awk -v ver="$PKG_VERSION" -v rel="$PKG_RELEASE" '
    { print }
    !seen && /^include \$\(TOPDIR\)\/rules\.mk/ {
      print "PKG_VERSION:=" ver
      print "PKG_RELEASE:=" rel
      seen = 1
    }
    END { if (!seen) exit 1 }
  ' "$mk" >"${mk}.new" || log::die "no 'include \$(TOPDIR)/rules.mk' line in ${mk}"
  mv "${mk}.new" "$mk"
}

configure() {
  log::info "Configuring for apk output"
  # Appended, not written over: the SDK ships a .config that already selects
  # its target and subtarget. Later assignments win in kconfig, so these two
  # override whatever the SDK shipped without discarding the rest.
  {
    echo "CONFIG_USE_APK=y"
    echo "CONFIG_PACKAGE_${PKG_NAME}=m"
  } >>.config
  make defconfig

  # defconfig drops symbols the SDK does not know, so both of these are
  # checked after the fact rather than assumed - an SDK without USE_APK would
  # otherwise quietly hand back an .ipk.
  grep -qx 'CONFIG_USE_APK=y' .config || log::die "this SDK does not build apk packages"
  grep -qx "CONFIG_PACKAGE_${PKG_NAME}=m" .config \
    || log::die "${PKG_NAME} is not selectable; check its Makefile's dependencies"
}

compile() {
  log::info "Compiling ${PKG_NAME}"
  if ! make "package/${PKG_NAME}/compile" -j"$(nproc)" V=sw; then
    log::warn "parallel build failed; retrying single-threaded for diagnostics"
    make "package/${PKG_NAME}/compile" -j1 V=s
  fi
}

collect() {
  local built=()
  mapfile -t built < <(find bin -type f -name "${PKG_NAME}-*.apk" | sort)
  [[ ${#built[@]} -gt 0 ]] || log::die "no .apk produced under $(pwd)/bin"

  cp "${built[@]}" "$OUT_DIR/"
  (cd "$OUT_DIR" && sha256sum ./*.apk >sha256sums.txt)
  log::info "Collected ${#built[@]} package(s) into ${OUT_DIR}:"
  printf '  %s\n' "${built[@]##*/}"
}

fetch_sdk
cd "$SDK_DIR"
prepare_feeds
stage_package
inject_version
configure
compile
collect
