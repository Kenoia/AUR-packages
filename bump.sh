#!/bin/bash
# Non-interactive version bump used by ci/aur.sh.
# Usage: ./bump.sh <pkgname> <version>
# Sets pkgver/pkgrel and refreshes checksums; commit/PR is the caller's job.

set -euo pipefail

usage() {
    echo "Usage: $0 <pkgname> <version>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage

pkg=$1
ver=$2

[[ -f "$pkg/PKGBUILD" ]] || {
    echo "Error: $pkg/PKGBUILD does not exist" >&2
    exit 1
}

cd "$pkg"

current_pkgver=$(bash -c 'source PKGBUILD >/dev/null 2>&1; printf "%s" "$pkgver"')
current_pkgrel=$(bash -c 'source PKGBUILD >/dev/null 2>&1; printf "%s" "$pkgrel"')

if [[ "$ver" == "$current_pkgver" ]]; then
    rel=$((current_pkgrel + 1))
else
    rel=1
fi

sed -i \
    -e "s/^pkgver=.*/pkgver=$ver/" \
    -e "s/^pkgrel=.*/pkgrel=$rel/" \
    PKGBUILD

updpkgsums

echo "$pkg: $current_pkgver-$current_pkgrel -> $ver-$rel"
