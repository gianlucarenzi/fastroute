#!/bin/sh
# Builds a Debian package of the fastroute command-line router, to install it
# system wide with apt (/usr/bin/fastroute).
#
# By default the binary is cross-linked with cargo-zigbuild against an old
# glibc (2.17, the same as scripts/build-linux.sh), so the same .deb installs
# and runs on Debian 11, Ubuntu 20.04 and every newer release. Needs zig and
# cargo-zigbuild in the PATH (or in ~/.local/bin and ~/.cargo/bin):
#   cargo install --locked cargo-zigbuild
#   zig from https://ziglang.org/download/ (0.13 or newer)
#
# --native builds with the system toolchain instead: the package then needs
# the glibc of the build machine (written in Depends, so apt refuses it on an
# older system).
#
# The highest glibc symbol version used by the binary is checked against
# MAX_GLIBC (default 2.31, Debian 11 and Ubuntu 20.04) and written in the
# package Depends as the minimum libc6 version.
#
# Usage: scripts/build-deb.sh [--native]   -> dist/fastroute_<version>_<arch>.deb
# Install: sudo apt install ./dist/fastroute_<version>_<arch>.deb
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
GLIBC=${GLIBC:-2.17}            # glibc linked against by cargo-zigbuild
MAX_GLIBC=${MAX_GLIBC:-2.31}    # oldest system the package must run on
NATIVE=0

for arg in "$@"; do
    case "$arg" in
        --native) NATIVE=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin"
export PATH

for tool in cargo dpkg-deb dpkg objdump; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not found" >&2; exit 1; }
done

VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -n 1)
[ -n "$VERSION" ] || { echo "error: no version in Cargo.toml" >&2; exit 1; }
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) TRIPLE=x86_64-unknown-linux-gnu ;;
    arm64) TRIPLE=aarch64-unknown-linux-gnu ;;
    *) echo "error: architecture $ARCH not supported" >&2; exit 1 ;;
esac

# --- build ---------------------------------------------------------------
cd "$ROOT"
if [ "$NATIVE" = 1 ]; then
    echo "Building fastroute $VERSION with the system toolchain..."
    CARGO_PROFILE_RELEASE_STRIP=symbols cargo build --release -p fastroute
    BIN="$TARGET_DIR/release/fastroute"
else
    for tool in zig cargo-zigbuild; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "error: $tool not found, needed for a binary that runs on" >&2
            echo "glibc $MAX_GLIBC (see the comment at the top of this script," >&2
            echo "or use --native for this system only)" >&2
            exit 1; }
    done
    echo "Building fastroute $VERSION for $TRIPLE, glibc $GLIBC..."
    CARGO_PROFILE_RELEASE_STRIP=symbols \
        cargo zigbuild --release -p fastroute --target "$TRIPLE.$GLIBC"
    BIN="$TARGET_DIR/$TRIPLE/release/fastroute"
fi
[ -x "$BIN" ] || { echo "error: $BIN not built" >&2; exit 1; }

# --- glibc check -----------------------------------------------------------
NEED_GLIBC=$(objdump -T "$BIN" | sed -n 's/.*GLIBC_\([0-9.]*\).*/\1/p' \
             | sort -t. -k1,1n -k2,2n -k3,3n -u | tail -n 1)
[ -n "$NEED_GLIBC" ] || NEED_GLIBC=2.2.5
echo "Binary needs glibc >= $NEED_GLIBC"
if [ "$NATIVE" = 0 ] && dpkg --compare-versions "$NEED_GLIBC" gt "$MAX_GLIBC"; then
    echo "error: glibc $NEED_GLIBC is newer than $MAX_GLIBC" >&2
    exit 1
fi

# --- package tree ------------------------------------------------------------
PKG=fastroute_${VERSION}_${ARCH}
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
if [ "$NATIVE" = 1 ]; then HOW="system toolchain"; else HOW="glibc $GLIBC, cargo-zigbuild"; fi
cat > "$STAGE/usr/share/doc/fastroute/changelog" <<EOF
fastroute ($VERSION) unstable; urgency=medium

  * Local build of fastroute $VERSION, commit $COMMIT.
  * Built with: $HOW.

 -- $NAME <$EMAIL>  $(date -R)
EOF
gzip -9n "$STAGE/usr/share/doc/fastroute/changelog"

SIZE=$(du -sk "$STAGE/usr" | cut -f1)
DESCRIPTION=$(sed -n 's/^description *= *"\(.*\)"/\1/p' \
              "$ROOT/crates/fastroute/Cargo.toml" | head -n 1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: fastroute
Version: $VERSION
Architecture: $ARCH
Maintainer: $NAME <$EMAIL>
Installed-Size: $SIZE
Depends: libc6 (>= $NEED_GLIBC), libgcc-s1
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
