#!/bin/bash

set -eo pipefail

confirm() {
    read -rp "Continue? [y/N] " reply
    case "$reply" in
    [yY][eE][sS] | [yY]) true ;;
    *) false ;;
    esac
}

if [[ "$1" == "" ]]; then
    pkg=$(exa -D | fzf --prompt "pkgname to update > " --preview="bat --color=always {}/PKGBUILD")
    echo "$pkg"
else
    pkg="$1"
fi

git add "$pkg"

cd "$pkg"

source PKGBUILD

if [[ "$2" == "" ]]; then
    echo "Old version: $pkgver"
    read -rp "New version? " ver
else
    ver="$2"
fi

if [[ "$ver" == "$pkgver" ]]; then
    rel=$(("$pkgrel" + 1))
else
    rel=1
fi

# Backup before modifying — restore on any failure or abort
cp PKGBUILD PKGBUILD.bak
rollback() { echo "==> Restoring PKGBUILD..."; mv PKGBUILD.bak PKGBUILD; }

sed -i "s/^pkgver=.*/pkgver=$ver/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=$rel/" PKGBUILD

updpkgsums || { echo "==> updpkgsums failed!"; rollback; exit 1; }

rm -r src || true
git clean -dxn
confirm || { echo "==> Aborted."; rollback; exit 0; }
git clean -dxf

git add -A
git diff --cached
confirm || { echo "==> Aborted."; rollback; exit 0; }

git commit -am "$pkg: update to $ver-$rel" --edit
git push
rm -f PKGBUILD.bak
