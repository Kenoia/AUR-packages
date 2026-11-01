#!/bin/bash
# Prepares the archlinux:base-devel container (runs as root): toolchain, an
# unprivileged builder user (makepkg refuses root), and the AUR SSH identity.
#
# AUR_SSH_KEY holds the private key itself (a GitHub secret), not a path.

set -euo pipefail

pacman-key --init
pacman -Syu --noconfirm --needed git openssh namcap nvchecker pacman-contrib jq

useradd -m builder
echo 'builder ALL=(root) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/builder
workspace=$(printenv GITHUB_WORKSPACE || true)
if [[ -n $workspace ]]; then
    chown -R builder:builder "$workspace"
fi

ssh_dir=/home/builder/.ssh
install -d -m 700 -o builder -g builder "$ssh_dir"
install -m 644 -o builder -g builder ci/aur_known_hosts "$ssh_dir/known_hosts"
key=$(printenv AUR_SSH_KEY || true)
if [[ -n $key ]]; then
    # GitHub secrets carry no trailing newline; OpenSSH rejects the key without it.
    printf '%s\n' "$key" | install -m 600 -o builder -g builder /dev/stdin "$ssh_dir/aur"
    printf 'Host aur.archlinux.org\n    User aur\n    IdentityFile ~/.ssh/aur\n' \
        | install -m 600 -o builder -g builder /dev/stdin "$ssh_dir/config"
fi
