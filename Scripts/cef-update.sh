#!/usr/bin/env bash
#
# cef-update.sh — check cef-builds.spotifycdn.com for a newer stable CEF,
# and if found: rewrite CEF_VERSION.json, download the new macosarm64 minimal
# distro, and re-vendor the CEF `include/` header tree into Sources/CCef.
#
# Usage:
#   Scripts/cef-update.sh            # works locally and in CI
#
# Behavior:
#   - Picks the HIGHEST cef_version with channel == "stable" that is available
#     for BOTH macosarm64 and macosx64 with BOTH minimal and standard files.
#     (index.json entries are NOT version-ordered, and multiple stable major
#     lines coexist — we sort numerically and take the max.)
#   - If it equals the current pin, prints "up to date" and exits 0.
#   - Otherwise performs the update and writes a PR body to
#     .cef/update-pr-body.md.
#   - When $GITHUB_OUTPUT is set (GitHub Actions), emits machine-readable
#     outputs: updated, old, new, chromium, warning, body_path.
#
# Requirements: bash, curl, jq, tar; python3 optional (not required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/CEF_VERSION.json"
INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CDN_BASE="https://cef-builds.spotifycdn.com"
CACHE_DIR="$ROOT/.cef"
DOWNLOADS_DIR="$CACHE_DIR/downloads"
BODY_FILE="$CACHE_DIR/update-pr-body.md"

TMP="$(mktemp -d /tmp/cef-update.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '[cef-update] %s\n' "$*" >&2; }
die() { printf '[cef-update] ERROR: %s\n' "$*" >&2; exit 1; }

emit_output() { # key value — writes to $GITHUB_OUTPUT in CI, stdout locally
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

human_size() { # bytes -> "123.4 MB"
  awk -v b="$1" 'BEGIN { printf (b >= 1073741824) ? "%.2f GB" : "%.1f MB", b / ((b >= 1073741824) ? 1073741824 : 1048576) }'
}

sha1_of() { # file
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 1 "$1" | awk '{print $1}'
  else
    sha1sum "$1" | awk '{print $1}'
  fi
}

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq   >/dev/null 2>&1 || die "jq is required"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

# --- 1. Fetch index.json (conditional GET via ETag; ~10 MB otherwise) --------
mkdir -p "$CACHE_DIR"
INDEX="$CACHE_DIR/index.json"
ETAG_FILE="$CACHE_DIR/index.etag"
log "fetching index.json (conditional)"
if [[ -s "$INDEX" && -f "$ETAG_FILE" ]]; then
  curl -fsSL --etag-compare "$ETAG_FILE" --etag-save "$ETAG_FILE" \
    -o "$TMP/index.json" "$INDEX_URL"
  if [[ -s "$TMP/index.json" ]]; then
    mv "$TMP/index.json" "$INDEX"
  else
    log "index.json unchanged (HTTP 304), using cached copy"
  fi
else
  curl -fsSL --etag-save "$ETAG_FILE" -o "$INDEX" "$INDEX_URL"
fi
jq -e . "$INDEX" >/dev/null || die "downloaded index.json is not valid JSON"

# --- 2. Pick the highest stable version available on both mac platforms ------
# A version qualifies only if both platforms list it as stable WITH both a
# "minimal" and a "standard" file (some entries lack flavors).
NEW="$(jq -r '
  def vkey: split("+")[0] | split(".") | map(tonumber);
  def qualified($p):
    .[$p].versions
    | map(select(.channel == "stable"
                 and any(.files[]; .type == "minimal")
                 and any(.files[]; .type == "standard"))
          | .cef_version);
  (qualified("macosarm64")) as $a
  | (qualified("macosx64")) as $b
  | ($a - ($a - $b))                      # intersection: stable on BOTH
  | sort_by(vkey)
  | last // empty
' "$INDEX")"
[[ -n "$NEW" ]] || die "could not determine latest stable CEF version from index.json"

OLD="$(jq -r .cef "$MANIFEST")"
log "current pin: $OLD"
log "latest stable (both mac platforms): $NEW"

if [[ "$NEW" == "$OLD" ]]; then
  log "up to date"
  emit_output updated false
  emit_output old "$OLD"
  emit_output new "$NEW"
  exit 0
fi

OLD_CHROMIUM="$(jq -r .chromium "$MANIFEST")"
NEW_CHROMIUM="$(jq -r --arg v "$NEW" \
  '.macosarm64.versions[] | select(.cef_version == $v) | .chromium_version' "$INDEX" | head -n1)"

# --- 3. Rewrite CEF_VERSION.json ---------------------------------------------
log "rewriting CEF_VERSION.json"
jq -n --arg v "$NEW" --arg chromium "$NEW_CHROMIUM" --slurpfile idx "$INDEX" '
  def file($p; $t):
    $idx[0][$p].versions[]
    | select(.cef_version == $v)
    | .files[] | select(.type == $t)
    | {name, sha1, size};
  {
    cef: $v,
    chromium: $chromium,
    channel: "stable",
    platforms: {
      macosarm64: { minimal: file("macosarm64"; "minimal"),
                    standard: file("macosarm64"; "standard") },
      macosx64:   { minimal: file("macosx64"; "minimal"),
                    standard: file("macosx64"; "standard") }
    }
  }
' > "$TMP/CEF_VERSION.json"
jq -e '.platforms.macosarm64.minimal.sha1 and .platforms.macosarm64.standard.sha1
       and .platforms.macosx64.minimal.sha1 and .platforms.macosx64.standard.sha1' \
  "$TMP/CEF_VERSION.json" >/dev/null || die "new manifest is missing file entries"
mv "$TMP/CEF_VERSION.json" "$MANIFEST"

# --- 4. Download + verify the new macosarm64 minimal tarball ------------------
TARBALL_NAME="$(jq -r '.platforms.macosarm64.minimal.name' "$MANIFEST")"
TARBALL_SHA1="$(jq -r '.platforms.macosarm64.minimal.sha1' "$MANIFEST")"
# CDN requires '+' to be percent-encoded in the path.
TARBALL_URL="$CDN_BASE/${TARBALL_NAME//+/%2B}"
mkdir -p "$DOWNLOADS_DIR"
TARBALL="$DOWNLOADS_DIR/$TARBALL_NAME"
if [[ -f "$TARBALL" ]] && [[ "$(sha1_of "$TARBALL")" == "$TARBALL_SHA1" ]]; then
  log "tarball already cached: $TARBALL"
else
  log "downloading $TARBALL_URL"
  curl -fL --retry 3 -o "$TARBALL" "$TARBALL_URL"
  ACTUAL_SHA1="$(sha1_of "$TARBALL")"
  [[ "$ACTUAL_SHA1" == "$TARBALL_SHA1" ]] \
    || die "sha1 mismatch for $TARBALL_NAME (expected $TARBALL_SHA1, got $ACTUAL_SHA1)"
fi

log "extracting headers"
mkdir -p "$TMP/extract"
tar -xjf "$TARBALL" -C "$TMP/extract"
NEW_INCLUDE="$(find "$TMP/extract" -maxdepth 2 -type d -name include | head -n1)"
[[ -n "$NEW_INCLUDE" && -f "$NEW_INCLUDE/cef_version.h" ]] \
  || die "could not find include/ tree in extracted distro"

# --- 5. Re-vendor the header tree into Sources/CCef ---------------------------
# Discover the vendored CEF include/ tree at runtime (its exact location under
# Sources/CCef is owned by the CCef target layout): it is the directory named
# "include" that contains cef_version.h. Only that directory is replaced;
# CefSwift-authored files (CCef.h, module.modulemap, ccef_config.h,
# ccef_loader.*, ccef_symbols.h) live OUTSIDE it and are preserved.
VENDORED_VERSION_H="$(find "$ROOT/Sources/CCef" -type f -path '*/include/cef_version.h' 2>/dev/null | head -n1)"
[[ -n "$VENDORED_VERSION_H" ]] \
  || die "could not locate vendored CEF include/ tree under Sources/CCef (no */include/cef_version.h)"
VENDORED_INCLUDE="$(cd "$(dirname "$VENDORED_VERSION_H")" && pwd)"
case "$VENDORED_INCLUDE" in
  "$ROOT/Sources/CCef/"*) ;;
  *) die "refusing to replace directory outside Sources/CCef: $VENDORED_INCLUDE" ;;
esac
log "re-vendoring headers: $VENDORED_INCLUDE"
rm -rf "$VENDORED_INCLUDE"
cp -R "$NEW_INCLUDE" "$VENDORED_INCLUDE"

# --- 6. Check the pinned CEF_API_VERSION is still supported -------------------
WARNING=""
PINNED_RAW="$(grep -rh '#define CEF_API_VERSION ' "$ROOT/Sources/CCef" --include='*.h' 2>/dev/null \
  | grep -v 'CEF_API_VERSION_' | head -n1 | awk '{print $3}' || true)"
PINNED="${PINNED_RAW##*_}"   # accept both `14800` and `CEF_API_VERSION_14800`
if [[ -z "$PINNED" ]]; then
  WARNING="Could not find the pinned '#define CEF_API_VERSION' in Sources/CCef; verify ccef_config.h manually."
elif ! grep -q "#define CEF_API_VERSION_${PINNED} " "$VENDORED_INCLUDE/cef_api_versions.h" 2>/dev/null; then
  WARNING="Pinned CEF_API_VERSION ${PINNED} is NOT listed in the new include/cef_api_versions.h — the pin must be migrated before this update can ship."
fi
[[ -n "$WARNING" ]] && log "WARNING: $WARNING"

# --- 7. PR body + outputs ------------------------------------------------------
ARM_MIN_SIZE="$(jq -r '.platforms.macosarm64.minimal.size' "$MANIFEST")"
ARM_STD_SIZE="$(jq -r '.platforms.macosarm64.standard.size' "$MANIFEST")"
X64_MIN_SIZE="$(jq -r '.platforms.macosx64.minimal.size' "$MANIFEST")"
X64_STD_SIZE="$(jq -r '.platforms.macosx64.standard.size' "$MANIFEST")"

{
  printf '## Bump CEF to %s\n\n' "$NEW"
  printf 'Automated update by `Scripts/cef-update.sh` (cef-update workflow).\n\n'
  printf '| | Old | New |\n|---|---|---|\n'
  printf '| CEF | `%s` | `%s` |\n' "$OLD" "$NEW"
  printf '| Chromium | `%s` | `%s` |\n\n' "$OLD_CHROMIUM" "$NEW_CHROMIUM"
  printf '### Distribution sizes\n\n'
  printf '| Platform | Minimal | Standard |\n|---|---|---|\n'
  printf '| macosarm64 | %s | %s |\n' "$(human_size "$ARM_MIN_SIZE")" "$(human_size "$ARM_STD_SIZE")"
  printf '| macosx64 | %s | %s |\n\n' "$(human_size "$X64_MIN_SIZE")" "$(human_size "$X64_STD_SIZE")"
  printf '### Changes\n\n'
  printf -- '- `CEF_VERSION.json` rewritten from index.json (minimal + standard, both mac platforms)\n'
  printf -- '- `Sources/CCef` vendored `include/` tree replaced with the %s distro headers\n\n' "$NEW"
  if [[ -n "$WARNING" ]]; then
    printf '> [!WARNING]\n> %s\n\n' "$WARNING"
  fi
  printf 'CI builds, tests, bundles the Browser example and smoke-launches CEF before this merges.\n'
} > "$BODY_FILE"

emit_output updated true
emit_output old "$OLD"
emit_output new "$NEW"
emit_output chromium "$NEW_CHROMIUM"
emit_output warning "$WARNING"
emit_output body_path "$BODY_FILE"

log "update prepared: $OLD -> $NEW (PR body: $BODY_FILE)"
