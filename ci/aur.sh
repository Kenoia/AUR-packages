#!/bin/bash
# CI entry point, run as the builder user after ci/setup.sh.
#
#   update          nvchecker all packages; for each newer upstream: bump, build,
#                   push to AUR; then push the commits back to the repo.
#   release <base>  build + push to AUR every package changed in <base>..HEAD
#   check <base>    build every package changed in <base>..HEAD (no push)
#
# Packages are always built from committed files (git archive HEAD), so only
# tracked files ever reach AUR. A package is pushed only when its version is
# newer than what AUR has, which makes re-running any mode safe.

set -euo pipefail
shopt -s inherit_errexit # otherwise $(build_one) would ignore a failed makepkg

self=$(realpath "$0")
cd "$(dirname "$self")/.."

# Fail fast when the AUR is unreachable instead of waiting on a prompt.
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15"

export SRCDEST=${SRCDEST:-$HOME/srcdest} # shared by updpkgsums and makepkg
mkdir -p "$SRCDEST"

source config # maintainer="Name <email>"
git config user.name "${maintainer% <*}"
git config user.email "$(sed -E 's/.*<(.*)>/\1/' <<< "$maintainer")"

# GitHub Actions context; empty when the script is run by hand.
gh_token=$(printenv GITHUB_TOKEN || true)
gh_repo=$(printenv GITHUB_REPOSITORY || true)
gh_run_url=$(printenv GITHUB_SERVER_URL || true)/$(printenv GITHUB_REPOSITORY || true)/actions/runs/$(printenv GITHUB_RUN_ID || true)
gh_branch=$(printenv GITHUB_REF_NAME || true)
[[ -n $gh_branch ]] || gh_branch=main

log() { printf '\e[1;34m==> %s\e[0m\n' "$*"; }
err() { printf '\e[1;31m==> ERROR: %s\e[0m\n' "$*" >&2; }

pkgbuild_var() { # <pkg> <var>
    bash -c 'source "$1/PKGBUILD" >/dev/null 2>&1; printf "%s" "${!2}"' _ "$1" "$2"
}

srcinfo_version() { # <.SRCINFO> -> epoch:pkgver-pkgrel
    local epoch pkgver pkgrel
    epoch=$(awk -F ' = ' '/^\tepoch = / { print $2; exit }' "$1")
    pkgver=$(awk -F ' = ' '/^\tpkgver = / { print $2; exit }' "$1")
    pkgrel=$(awk -F ' = ' '/^\tpkgrel = / { print $2; exit }' "$1")
    [[ -n $pkgver && -n $pkgrel ]] || { err "no pkgver/pkgrel in $1"; return 1; }
    printf '%s:%s-%s' "${epoch:-0}" "$pkgver" "$pkgrel"
}

changed_packages() { # <base>
    # A new branch reports an all-zero base; there is nothing to diff against.
    [[ $1 =~ ^0+$ ]] && return 0
    git diff --name-only "$1" HEAD | cut -d/ -f1 | sort -u |
        while read -r p; do
            if [[ -f $p/PKGBUILD ]]; then echo "$p"; fi
        done
}

# Package dir whose pkgname or provides is <name>, if any.
local_provider() { # <name>
    local p name=$1
    for p in */PKGBUILD; do
        p=${p%/PKGBUILD}
        # shellcheck disable=SC2016
        if bash -c 'source "$1/PKGBUILD" >/dev/null 2>&1
            for x in "$pkgname" "${provides[@]%%[<>=]*}"; do [[ $x == "$2" ]] && exit 0; done
            exit 1' _ "$p" "$name"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Dependencies that only this repo provides (AUR-only), are built and installed
# first, so makepkg --syncdeps can resolve them.
install_local_deps() { # <pkg>
    local dep provider build
    # shellcheck disable=SC2016
    for dep in $(bash -c 'source "$1/PKGBUILD" >/dev/null 2>&1
        a=depends_$(uname -m) b=makedepends_$(uname -m)
        printf "%s\n" "${depends[@]}" "${makedepends[@]}" "${!a}" "${!b}"' _ "$1" | sed 's/[<>=].*//' | sort -u); do
        [[ -n $dep ]] || continue
        pacman -T "$dep" >/dev/null && continue  # already installed
        pacman -Si "$dep" >/dev/null 2>&1 && continue  # makepkg -s will fetch it
        provider=$(local_provider "$dep") || continue  # makepkg reports it
        [[ $provider != "$1" ]] || continue
        log "$1: building local dependency $provider for $dep"
        build=$(build_one "$provider")
        sudo pacman -U --noconfirm --asdeps "$build"/*.pkg.tar.* >&2
    done
}

build_one() { # <pkg> -> prints build dir
    local dir
    install_local_deps "$1" >&2
    dir=$(mktemp -d)
    git archive HEAD:"$1" | tar -x -C "$dir"
    (
        cd "$dir"
        makepkg --syncdeps --noconfirm >&2
        makepkg --printsrcinfo > .SRCINFO
        namcap PKGBUILD ./*.pkg.tar.* >&2
    )
    echo "$dir"
}

release_one() { # <pkg>
    local pkg=$1 build aur local_ver aur_ver
    build=$(build_one "$pkg")
    aur=$(mktemp -d)
    git clone -q "ssh://ssh://aur@aur.archlinux.org/$pkg.git" "$aur"

    local_ver=$(srcinfo_version "$build/.SRCINFO")
    if [[ -f $aur/.SRCINFO ]]; then
        aur_ver=$(srcinfo_version "$aur/.SRCINFO")
        if (($(vercmp "$local_ver" "$aur_ver") <= 0)); then
            log "$pkg: $local_ver is not newer than AUR $aur_ver, skipping"
            return 0
        fi
    fi

    find "$aur" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    git archive HEAD:"$pkg" | tar -x -C "$aur"
    cp "$build/.SRCINFO" "$aur/"
    git -C "$aur" add -A
    git -C "$aur" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
        commit -q -m "$(git log -1 --format=%B -- "$pkg")" -m "CI: $gh_run_url"
    git -C "$aur" push -q origin HEAD:master
    log "$pkg: pushed $local_ver to AUR"
}

bump_release_one() { # <pkg> <version>
    local pkg=$1 ver=$2
    ./bump.sh "$pkg" "$ver"
    git add "$pkg/PKGBUILD"
    git commit -q -m "$pkg: update to $ver-$(pkgbuild_var "$pkg" pkgrel)"
    release_one "$pkg"
}

# Each package runs in its own process: errexit is disabled inside functions
# called from an if condition, so in-process error isolation would swallow
# failures.
run_each() { # <subcommand> <pkg>...
    local sub=$1 pkg failed=()
    shift
    (($# > 0)) || log "no packages changed"
    for pkg in "$@"; do
        log "$sub $pkg"
        "$self" "$sub" "$pkg" || failed+=("$pkg")
    done
    ((${#failed[@]} == 0)) || { err "failed: ${failed[*]}"; return 1; }
}

# Pushes the update commits back. GITHUB_TOKEN pushes do not trigger workflows,
# so this cannot loop.
push_back() { # <start-sha>
    local start=$1
    if [[ -z $gh_token ]]; then
        log "GITHUB_TOKEN is unset, leaving $(git rev-list --count "$start"..HEAD) commit(s) unpushed"
        return 0
    fi
    local url="https://x-access-token:$gh_token@github.com/$gh_repo.git"
    git fetch -q "$url" "$gh_branch"
    git rebase -q FETCH_HEAD
    git push -q "$url" "HEAD:$gh_branch"
    log "pushed $(git rev-list --count FETCH_HEAD..HEAD) commit(s) to $gh_branch"
}

update() {
    local -A latest=()
    local name ver pkg cur head start failed=()
    while IFS=$'\t' read -r name ver; do
        latest[$name]=$ver
    done < <(nvchecker -c nvchecker.toml --logger json |
        jq -r 'select(.event == "updated") | [.name, .version] | @tsv')

    start=$(git rev-parse HEAD)
    for pkg in */PKGBUILD; do
        pkg=${pkg%/PKGBUILD}
        ver=${latest[$pkg]:-}
        if [[ ! $ver =~ ^[A-Za-z0-9._+]+$ ]]; then
            err "$pkg: bad or missing upstream version '$ver'"
            failed+=("$pkg")
            continue
        fi
        cur=$(pkgbuild_var "$pkg" pkgver)
        if (($(vercmp "$ver" "$cur") <= 0)); then
            log "$pkg: $cur is up to date"
            continue
        fi
        log "$pkg: $cur -> $ver"
        head=$(git rev-parse HEAD)
        if ! "$self" bump-release-one "$pkg" "$ver"; then
            git reset -q --hard "$head"
            failed+=("$pkg")
        fi
    done

    if [[ $(git rev-parse HEAD) != "$start" ]]; then
        push_back "$start"
    fi

    ((${#failed[@]} == 0)) || { err "failed: ${failed[*]}"; return 1; }
}

case ${1:-} in
update) update ;;
release | check)
    # Assign first: a failed substitution inside an argument list would not abort.
    changed=$(changed_packages "$2")
    # Package names never contain whitespace, so word splitting is intended.
    # shellcheck disable=SC2086
    if [[ $1 == release ]]; then run_each release-one $changed; else run_each build-one $changed; fi
    ;;
release-one) release_one "$2" ;;
build-one) build_one "$2" >/dev/null ;;
bump-release-one) bump_release_one "$2" "$3" ;;
*)
    echo "Usage: $0 update | release <base> | check <base>" >&2
    exit 2
    ;;
esac
