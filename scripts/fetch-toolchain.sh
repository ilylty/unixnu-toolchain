#!/bin/bash
# Download, verify and unpack the published UniXNU Linux toolchain.
#
#   fetch-toolchain.sh [PREFIX]        default /opt/unixnu-linux, or $UNIXNU_TOOLCHAIN
#   fetch-toolchain.sh --print-lock    print a toolchain.lock for the current asset
#   fetch-toolchain.sh --tag TAG ...   override the tag (default: from toolchain.lock)
#
# Environment:
#   TOOLCHAIN_TAG         release tag; overrides toolchain.lock
#   TOOLCHAIN_REPOSITORY  owner/name; default ilylty/unixnu-toolchain
#   TOOLCHAIN_LOCK        lock file; default <script dir>/../toolchain.lock
#   GH_TOKEN              read access to the release (public releases need none)
#
# Why the sha256 comes from a committed lock file rather than from the
# .sha256 asset beside the archive: a release asset can be replaced, so a
# hash that travels with it proves nothing. Pinning the expected digest in this
# repository is the same arrangement Bazel's toolchains_llvm uses
# (`extra_llvm_distributions` maps archive name to sha256 in the consumer).
#
# The archive is rooted at the prefix's basename, so it unpacks into any parent
# directory: `tar -C /opt -xf ...` and `tar -C $HOME -xf ...` both work, and
# UNIXNU_TOOLCHAIN / --prefix then point at the result. The one thing a moved
# prefix cannot fix is that setup-toolchain.py expands absolute paths into the
# xnu-host-cc wrapper and installs three shims into /usr/bin; re-running it in
# place is idempotent and repairs both.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="${TOOLCHAIN_REPOSITORY:-ilylty/unixnu-toolchain}"
LOCK="${TOOLCHAIN_LOCK:-$HERE/../toolchain.lock}"

print_lock=0
PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --print-lock) print_lock=1; shift ;;
        --tag)        TOOLCHAIN_TAG="$2"; shift 2 ;;
        --repository) REPOSITORY="$2"; shift 2 ;;
        --lock)       LOCK="$2"; shift 2 ;;
        -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)           echo "unknown option: $1" >&2; exit 2 ;;
        *)            PREFIX="$1"; shift ;;
    esac
done

lock_get() {
    # A deliberately dumb parser: the lock file is KEY=value, one per line.
    [ -f "$LOCK" ] || return 1
    sed -n "s/^$1=//p" "$LOCK" | head -1
}

TAG="${TOOLCHAIN_TAG:-$(lock_get tag || true)}"
if [ -z "${TAG:-}" ]; then
    echo "no tag: set TOOLCHAIN_TAG, pass --tag, or provide $LOCK" >&2
    exit 2
fi
ASSET="unixnu-linux-toolchain-${TAG}.tar.zst"
EXPECTED="$(lock_get sha256 || true)"

gh() { command gh "$@"; }

if [ "$print_lock" = 1 ]; then
    url="https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "downloading $url" >&2
    curl -fsSL --retry 3 -o "$tmp/$ASSET" "$url"
    digest="$(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)"
    size="$(stat -c%s "$tmp/$ASSET")"
    cat <<EOF
# UniXNU Linux toolchain pin. Regenerate with scripts/fetch-toolchain.sh --print-lock.
# The digest is checked against the downloaded archive; a replaced release asset
# then fails here instead of being executed.
repository=$REPOSITORY
tag=$TAG
asset=$ASSET
sha256=$digest
size=$size
EOF
    exit 0
fi

# ---------------------------------------------------------------------------

if [ -z "$PREFIX" ]; then
    PREFIX="${UNIXNU_TOOLCHAIN:-/opt/unixnu-linux}"
fi

if [ -x "$PREFIX/llvm/bin/clang" ] && [ -x "$PREFIX/CommandLineTools/usr/bin/ld" ]; then
    echo "toolchain already present at $PREFIX"
    if [ -n "$EXPECTED" ] && [ -f "$PREFIX/.toolchain-sha256" ]; then
        have="$(cat "$PREFIX/.toolchain-sha256")"
        if [ "$have" != "$EXPECTED" ]; then
            echo "::error::$PREFIX holds $have, lock pins $EXPECTED; remove it and re-run" >&2
            exit 1
        fi
    fi
    exit 0
fi

url="https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $ASSET from $REPOSITORY@$TAG"
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    gh release download "$TAG" --repo "$REPOSITORY" --pattern "$ASSET" --dir "$tmp"
else
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/$ASSET" "$url"
fi

actual="$(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)"
if [ -z "$EXPECTED" ]; then
    echo "::warning::no sha256 in $LOCK; trusting the download ($actual)" >&2
elif [ "$actual" != "$EXPECTED" ]; then
    echo "::error::sha256 mismatch" >&2
    echo "  expected $EXPECTED" >&2
    echo "  actual   $actual" >&2
    exit 1
else
    echo "sha256 ok: $actual"
fi

parent="$(dirname "$PREFIX")"
base="$(basename "$PREFIX")"
mkdir -p "$parent"
echo "unpacking into $parent"
tar -C "$parent" --zstd -xf "$tmp/$ASSET"
[ -d "$parent/$base" ] || { echo "archive did not produce $parent/$base" >&2; exit 1; }

# Ownership: the workflow runs the installer under sudo, which leaves root-owned
# files behind; make the prefix writable by whoever is building.
if [ "$(id -u)" = 0 ]; then
    chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$parent/$base" 2>/dev/null || true
fi
printf '%s\n' "$actual" > "$parent/$base/.toolchain-sha256"

echo "toolchain ready at $PREFIX"
du -sh "$PREFIX" 2>/dev/null || true
