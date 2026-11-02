#!/bin/sh
# Builds a Debian package of the fastroute command-line router, to install it
# system wide with apt (/usr/bin/fastroute).
#
# By default the binary is cross-linked with cargo-zigbuild against an old
# glibc (2.17, the same as scripts/build-linux.sh), so the same .deb installs
# and runs on Debian 11, Ubuntu 20.04 and every newer release. Needs zig and
# cargo-zigbuild in the PATH (or in ~/.local/bin and ~/.cargo/bin); when
# missing they are installed in the user's home, no root needed:
#   cargo install --locked cargo-zigbuild         (-> ~/.cargo/bin)
#   zig 0.14.1 from https://ziglang.org/download/ (-> ~/.local/opt, ~/.local/bin/zig)
# and with rustup the Rust target is added (rustup target add <triple>).
#
# --native builds with the system gcc toolchain instead: the package then
# needs the glibc of that toolchain (written in Depends, so apt refuses it on
# an older system). With --arch of another architecture it uses the gcc cross
# toolchain (e.g. gcc-powerpc64le-linux-gnu) and needs the Rust target
# installed (rustup target add <triple>).
#
# --arch ARCH builds for a Debian architecture other than the build machine:
#   amd64 (x86_64), arm64 (aarch64), ppc64el (powerpc64 little endian),
#   ppc64 (powerpc64 big endian; --native only, zig cannot link it)
#
# The highest glibc symbol version used by the binary is written in the
# package Depends as the minimum libc6 version. It is checked against
# MAX_GLIBC (default 2.31, Debian 11 and Ubuntu 20.04) for cargo-zigbuild
# builds, and for --native builds when MAX_GLIBC is set.
#
# --revision N makes the package version <version>-N (Debian revision, for a
# new package of the same upstream version; the GitHub workflow takes it from
# a vX.Y.Z-N tag). Without it the package version is the Cargo.toml one.
#
# Usage: scripts/build-deb.sh [--native] [--arch ARCH] [--revision N]
#          -> dist/fastroute_<version>[-N]_<arch>.deb
# Install: sudo apt install ./dist/fastroute_<version>_<arch>.deb
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
GLIBC=${GLIBC:-2.17}            # glibc linked against by cargo-zigbuild
CHECK_GLIBC=${MAX_GLIBC:+1}     # MAX_GLIBC given: check it in --native too
MAX_GLIBC=${MAX_GLIBC:-2.31}    # oldest system the package must run on
NATIVE=0
ARCH=""
REVISION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --native) NATIVE=1; shift ;;
        --arch) [ $# -ge 2 ] || { echo "--arch needs a value" >&2; exit 2; }
                ARCH=$2; shift 2 ;;
        --revision) [ $# -ge 2 ] || { echo "--revision needs a value" >&2; exit 2; }
                REVISION=$2; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[ "$NATIVE" = 1 ] || CHECK_GLIBC=1

# ~/.cargo/bin first: a rustup toolchain wins over an older distro cargo
PATH="$HOME/.cargo/bin:$PATH:$HOME/.local/bin"
export PATH

for tool in cargo dpkg-deb dpkg readelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not found" >&2; exit 1; }
done

VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -n 1)
[ -n "$VERSION" ] || { echo "error: no version in Cargo.toml" >&2; exit 1; }
case "$REVISION" in
    "") DEB_VERSION=$VERSION ;;
    *[!0-9]*) echo "error: --revision must be a number" >&2; exit 2 ;;
    *) DEB_VERSION=$VERSION-$REVISION ;;
esac
HOST_ARCH=$(dpkg --print-architecture)
ARCH=${ARCH:-$HOST_ARCH}
case "$ARCH" in
    amd64)   TRIPLE=x86_64-unknown-linux-gnu;      GNU=x86_64-linux-gnu ;;
    arm64)   TRIPLE=aarch64-unknown-linux-gnu;     GNU=aarch64-linux-gnu ;;
    ppc64el) TRIPLE=powerpc64le-unknown-linux-gnu; GNU=powerpc64le-linux-gnu ;;
    ppc64)   TRIPLE=powerpc64-unknown-linux-gnu;   GNU=powerpc64-linux-gnu ;;
    *) echo "error: architecture $ARCH not supported" >&2; exit 1 ;;
esac

# zig is not packaged for Debian 11 / Ubuntu 20.04: when missing it is
# downloaded from ziglang.org (pinned version, sha256 checked) into
# ~/.local/opt/zig-<version>, with a link in ~/.local/bin/zig
ZIG_VERSION=0.14.1
install_zig() {
    case "$HOST_ARCH" in
        amd64)   zarch=x86_64
                 zsum=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c ;;
        arm64)   zarch=aarch64
                 zsum=f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b ;;
        ppc64el) zarch=powerpc64le
                 zsum=15523e748efd9224ae164482e5cc1f8c11b035246b9749fb5b00758484f384a1 ;;
        *) echo "error: zig not found and no download for $HOST_ARCH" >&2
           echo "(install zig 0.13 or newer, or use --native)" >&2; exit 1 ;;
    esac
    for tool in curl tar xz sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "error: zig not found, and $tool is needed to download it" >&2; exit 1; }
    done
    zname=zig-$zarch-linux-$ZIG_VERSION
    echo "zig not found, installing $zname in ~/.local/opt..."
    mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"
    ztmp=$(mktemp -d)
    curl -fL --proto '=https' --tlsv1.2 -o "$ztmp/$zname.tar.xz" \
        "https://ziglang.org/download/$ZIG_VERSION/$zname.tar.xz"
    echo "$zsum  $ztmp/$zname.tar.xz" | sha256sum -c - >/dev/null || {
        echo "error: checksum mismatch for $zname.tar.xz" >&2; rm -rf "$ztmp"; exit 1; }
    rm -rf "$HOME/.local/opt/$zname"
    tar -xJf "$ztmp/$zname.tar.xz" -C "$HOME/.local/opt"
    rm -rf "$ztmp"
    ln -sfn "$HOME/.local/opt/$zname/zig" "$HOME/.local/bin/zig"
}

# --- build ---------------------------------------------------------------
cd "$ROOT"
if [ "$NATIVE" = 1 ] && [ "$ARCH" = "$HOST_ARCH" ]; then
    echo "Building fastroute $VERSION with the system toolchain..."
    CARGO_PROFILE_RELEASE_STRIP=symbols cargo build --release -p fastroute
    BIN="$TARGET_DIR/release/fastroute"
    HOW="system toolchain"
elif [ "$NATIVE" = 1 ]; then
    command -v "$GNU-gcc" >/dev/null 2>&1 || {
        echo "error: $GNU-gcc not found (apt install gcc-$GNU)" >&2; exit 1; }
    echo "Building fastroute $VERSION for $TRIPLE with $GNU-gcc..."
    UPPER=$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')
    LOWER=$(echo "$TRIPLE" | tr '-' '_')
    env "CARGO_TARGET_${UPPER}_LINKER=$GNU-gcc" "CC_${LOWER}=$GNU-gcc" \
        "AR_${LOWER}=$GNU-ar" CARGO_PROFILE_RELEASE_STRIP=symbols \
        cargo build --release -p fastroute --target "$TRIPLE"
    BIN="$TARGET_DIR/$TRIPLE/release/fastroute"
    HOW="gcc cross toolchain $GNU"
else
    [ "$ARCH" != ppc64 ] || {
        echo "error: ppc64 (big endian) needs --native with gcc-$GNU" >&2; exit 1; }
    command -v zig >/dev/null 2>&1 || install_zig
    command -v cargo-zigbuild >/dev/null 2>&1 || {
        echo "cargo-zigbuild not found, installing it in ~/.cargo/bin..."
        cargo install --locked cargo-zigbuild; }
    if command -v rustup >/dev/null 2>&1 &&
       ! rustup target list --installed | grep -qx "$TRIPLE"; then
        rustup target add "$TRIPLE"
    fi
    echo "Building fastroute $VERSION for $TRIPLE, glibc $GLIBC..."
    CARGO_PROFILE_RELEASE_STRIP=symbols \
        cargo zigbuild --release -p fastroute --target "$TRIPLE.$GLIBC"
    BIN="$TARGET_DIR/$TRIPLE/release/fastroute"
    HOW="glibc $GLIBC, cargo-zigbuild"
fi
[ -x "$BIN" ] || { echo "error: $BIN not built" >&2; exit 1; }

# --- glibc check -----------------------------------------------------------
# readelf reads the ELF of any architecture (objdump only the host one)
NEED_GLIBC=$(readelf --dyn-syms -W "$BIN" | sed -n 's/.*@GLIBC_\([0-9.]*\).*/\1/p' \
             | sort -t. -k1,1n -k2,2n -k3,3n -u | tail -n 1)
[ -n "$NEED_GLIBC" ] || NEED_GLIBC=2.2.5
echo "Binary needs glibc >= $NEED_GLIBC"
if [ -n "$CHECK_GLIBC" ] && dpkg --compare-versions "$NEED_GLIBC" gt "$MAX_GLIBC"; then
    echo "error: glibc $NEED_GLIBC is newer than $MAX_GLIBC" >&2
    exit 1
fi

# Depends from the shared libraries the binary links: libc6 always (libc,
# libm, libpthread, libdl), libgcc-s1 only when it needs libgcc_s (the
# gcc builds do, the cargo-zigbuild one does not)
DEPENDS="libc6 (>= $NEED_GLIBC)"
if readelf -d "$BIN" | grep -q 'NEEDED.*\[libgcc_s\.so'; then
    DEPENDS="$DEPENDS, libgcc-s1"
fi
echo "Depends: $DEPENDS"

# --- package tree ------------------------------------------------------------
PKG=fastroute_${DEB_VERSION}_${ARCH}
STAGE="$ROOT/target/deb/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/doc/fastroute"
install -m 0755 "$BIN" "$STAGE/usr/bin/fastroute"
cat > "$STAGE/usr/share/doc/fastroute/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: fastroute
Source: https://github.com/parisxmas/fastroute

Files: *
Copyright: 2026 Baris Akin
 Derivative work of Freerouting (https://github.com/freerouting/freerouting),
 originally written by Alfons Wirtz; see NOTICE.
License: GPL-3+
 This program is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation, either version 3 of the License, or (at your option)
 any later version.
 .
 On Debian systems, the complete text of the GNU General Public License
 version 3 can be found in /usr/share/common-licenses/GPL-3.
EOF
install -m 0644 "$ROOT/NOTICE" "$STAGE/usr/share/doc/fastroute/NOTICE"
install -m 0644 "$ROOT/README.md" "$STAGE/usr/share/doc/fastroute/README.md"
find "$STAGE" -type d -exec chmod 0755 {} +

# Maintainer: who builds the package (DEBFULLNAME/DEBEMAIL, or git config)
NAME=${DEBFULLNAME:-$(git -C "$ROOT" config user.name || echo "fastroute builder")}
EMAIL=${DEBEMAIL:-$(git -C "$ROOT" config user.email || echo "builder@localhost.localdomain")}
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
# A package with a Debian revision is not native: its changelog is
# changelog.Debian (Debian policy 12.7)
CHANGELOG="$STAGE/usr/share/doc/fastroute/changelog${REVISION:+.Debian}"
cat > "$CHANGELOG" <<EOF
fastroute ($DEB_VERSION) unstable; urgency=medium

  * Local build of fastroute $VERSION, commit $COMMIT.
  * Built with: $HOW.

 -- $NAME <$EMAIL>  $(date -R)
EOF
gzip -9n "$CHANGELOG"

SIZE=$(du -sk "$STAGE/usr" | cut -f1)
DESCRIPTION=$(sed -n 's/^description *= *"\(.*\)"/\1/p' \
              "$ROOT/crates/fastroute/Cargo.toml" | head -n 1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: fastroute
Version: $DEB_VERSION
Architecture: $ARCH
Maintainer: $NAME <$EMAIL>
Installed-Size: $SIZE
Depends: $DEPENDS
Section: electronics
Priority: optional
Homepage: https://github.com/parisxmas/fastroute
Description: ${DESCRIPTION:-PCB autorouter}
 Command-line PCB autorouter, a Rust port of Freerouting. Reads a Specctra
 DSN file and writes the routed Specctra session (SES).
EOF

chmod 0644 "$STAGE"/usr/share/doc/fastroute/*
mkdir -p "$ROOT/dist"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$ROOT/dist/$PKG.deb" >/dev/null
echo "wrote dist/$PKG.deb ($(du -h "$ROOT/dist/$PKG.deb" | cut -f1))"
echo "install with: sudo apt install ./dist/$PKG.deb"
