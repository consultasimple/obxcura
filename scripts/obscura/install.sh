#!/usr/bin/env bash
#
# Install the Obscura headless browser (the external binary this gem drives).
#
# Defaults to the latest release, the stealth build, and /usr/local/bin.
#
#   scripts/obscura/install.sh                      # latest stealth -> /usr/local/bin
#   scripts/obscura/install.sh --version v0.2.0     # pin a release
#   scripts/obscura/install.sh --prefix ~/.local/bin
#   scripts/obscura/install.sh --no-render          # smaller build, no screenshot/pdf
#
# Why stealth by default: it is the only build measured to get past Imperva
# /Incapsula, and unlike the -no-render archives it still carries the render
# feature, so the :render specs (Page#screenshot, Page#pdf) actually run.

set -euo pipefail

REPO="h4ckf0r0day/obscura"
PREFIX="/usr/local/bin"
VERSION=""
STEALTH=1
RENDER=1

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

info() { printf '==> %s\n' "$1"; }

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; [ -n "$VERSION" ] || die "--version needs a tag (e.g. v0.2.0)"; shift 2 ;;
    --prefix)  PREFIX="${2:-}";  [ -n "$PREFIX" ]  || die "--prefix needs a directory"; shift 2 ;;
    --no-stealth) STEALTH=0; shift ;;
    --no-render)  RENDER=0; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

for cmd in curl tar; do
  command -v "$cmd" >/dev/null || die "$cmd is required but not installed"
done

# --- platform -----------------------------------------------------------------

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux)  os="linux" ;;
  *) die "unsupported OS: $(uname -s). Windows builds exist but this script does not handle them." ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch="aarch64" ;;
  x86_64|amd64)  arch="x86_64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# Written as `if`, not `[ ... ] && asset=...`: under `set -e` a trailing test
# that evaluates false makes the whole statement non-zero and kills the script.
asset="obscura-${arch}-${os}"
if [ "$RENDER" -eq 0 ]; then asset="${asset}-no-render"; fi
if [ "$STEALTH" -eq 1 ]; then asset="${asset}-stealth"; fi
asset="${asset}.tar.gz"

# --- destination --------------------------------------------------------------
# Checked before the download: no point pulling ~90MB to then discover the
# prefix is wrong.

[ -d "$PREFIX" ] || die "prefix does not exist: $PREFIX"

if [ -w "$PREFIX" ]; then
  sudo=""
else
  sudo="sudo"
  info "${PREFIX} is not writable — sudo will ask for your password"
fi

# --- version ------------------------------------------------------------------

if [ -z "$VERSION" ]; then
  info "Resolving the latest release of ${REPO}"
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || die "could not resolve the latest release tag (GitHub API rate limit? pass --version)"
fi

url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"

# --- download -----------------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading ${asset} (${VERSION}) for ${PREFIX}"
curl -fSL --progress-bar -o "${tmp}/obscura.tar.gz" "$url" ||
  die "download failed: $url"

# The archives are flat: obscura and obscura-worker sit at the root, no
# top-level directory, so no --strip-components.
tar -xzf "${tmp}/obscura.tar.gz" -C "$tmp"

for binary in obscura obscura-worker; do
  [ -f "${tmp}/${binary}" ] ||
    die "${binary} missing from ${asset} — the archive layout changed"
done

# --- install ------------------------------------------------------------------

# `obscura serve` looks for obscura-worker as a sibling, so the pair always
# moves together. Installing one alone silently mixes builds.
for binary in obscura obscura-worker; do
  target="${PREFIX}/${binary}"

  # Delete before copying, never overwrite in place. macOS caches a code
  # signature per vnode; writing new bytes into the existing inode leaves the
  # cached CDHash stale and the kernel SIGKILLs the binary on exec — even
  # though the file is byte-identical to a copy that runs fine elsewhere.
  # Removing first means the copy lands on a fresh inode with nothing cached.
  $sudo rm -f "$target"
  $sudo cp "${tmp}/${binary}" "$target"
  $sudo chmod 755 "$target"
done

# --- verify -------------------------------------------------------------------

info "Verifying ${PREFIX}/obscura"

set +e
reported="$("${PREFIX}/obscura" --version 2>&1)"
status=$?
set -e

if [ "$status" -eq 137 ]; then
  die "the installed binary was SIGKILLed on exec (stale macOS code-signature cache).
     Re-run this script; if it persists: sudo codesign -f -s - ${PREFIX}/obscura
     (note that re-signing rewrites the signature and changes the checksum below)."
fi
[ "$status" -eq 0 ] || die "${PREFIX}/obscura --version exited ${status}: ${reported}"

flavor="stealth"
[ "$STEALTH" -eq 1 ] || flavor="unsuffixed"
[ "$RENDER" -eq 1 ]  || flavor="${flavor}, no-render"

cat <<EOF

Installed ${reported} (${flavor}) from ${asset}
  ${PREFIX}/obscura
  ${PREFIX}/obscura-worker

EOF

# All four builds of a given release answer --version identically, so the
# checksum is the only reliable way to tell later which one is installed.
if command -v shasum >/dev/null; then
  shasum -a 256 "${PREFIX}/obscura" "${PREFIX}/obscura-worker"
elif command -v sha256sum >/dev/null; then
  sha256sum "${PREFIX}/obscura" "${PREFIX}/obscura-worker"
fi
