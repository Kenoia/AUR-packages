#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 <pkgname> <version>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage

pkg=$1
ver=$2
pkgbuild="$pkg/PKGBUILD"

[[ -f "$pkgbuild" ]] || {
    echo "Error: $pkgbuild does not exist" >&2
    exit 1
}

# Local packages must stay outside Git to avoid accidental AUR commits/pushes.
git check-ignore -q -- "$pkgbuild" || {
    echo "Error: $pkgbuild is not ignored by Git; refusing to update it as a local package" >&2
    exit 1
}

current_pkgver=$(bash -c 'source "$1"; printf "%s" "$pkgver"' _ "$pkgbuild")
current_pkgrel=$(bash -c 'source "$1"; printf "%s" "$pkgrel"' _ "$pkgbuild")

if [[ "$ver" == "$current_pkgver" ]]; then
    [[ "$current_pkgrel" =~ ^[0-9]+$ ]] || {
        echo "Error: pkgrel must be an integer, got: $current_pkgrel" >&2
        exit 1
    }
    rel=$((current_pkgrel + 1))
else
    rel=1
fi

backup=$(mktemp)
cp "$pkgbuild" "$backup"
rollback() {
    echo "==> Restoring $pkgbuild" >&2
    cp "$backup" "$pkgbuild"
}
trap 'rollback; rm -f "$backup"' ERR INT TERM

sed -i \
    -e "s/^pkgver=.*/pkgver=$ver/" \
    -e "s/^pkgrel=.*/pkgrel=$rel/" \
    "$pkgbuild"

(
    cd "$pkg"
    updpkgsums
)

trap - ERR INT TERM
rm -f "$backup"

printf '==> Updated %s: %s-%s -> %s-%s\n' \
    "$pkg" "$current_pkgver" "$current_pkgrel" "$ver" "$rel"

(
    cd "$pkg"
    makepkg -Ccf --noconfirm
    mapfile -t packages < <(makepkg --packagelist)
    [[ ${#packages[@]} -gt 0 ]] || {
        echo "Error: makepkg did not report any package files" >&2
        exit 1
    }
    sudo pacman -U -- "${packages[@]}"
)
