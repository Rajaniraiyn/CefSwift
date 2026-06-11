#!/usr/bin/env bash
#
# check-symbols.sh — audit the C bridge's dlsym table against a real CEF binary.
#
# Extracts every symbol name from the X-macro list in Sources/CCef (ccef_symbols.h)
# and verifies each one is an exported global of the CEF framework binary
# (`nm -gU`). Also reports — informationally, never failing — how many exported
# _cef_* symbols the framework has versus how many CefSwift binds.
#
# Usage:
#   Scripts/check-symbols.sh [path-to-framework-binary]
#
# Without an argument it searches, in order:
#   1. $CEF_FRAMEWORK_PATH (file, or a .framework dir)
#   2. .cef/dist/*/Release/Chromium Embedded Framework.framework (versioned or flat)
#   3. /tmp/cefswift-ref/cef_binary_*/Release/... (flat reference extraction)
#
# Exit codes: 0 = every bound symbol exists; 1 = missing symbols or no binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[check-symbols] %s\n' "$*" >&2; }
die() { printf '[check-symbols] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Locate ccef_symbols.h ----------------------------------------------------
SYMBOLS_H="$(find "$ROOT/Sources/CCef" -type f -name ccef_symbols.h 2>/dev/null | head -n1)"
[[ -n "$SYMBOLS_H" ]] || die "ccef_symbols.h not found under Sources/CCef"

# --- Resolve the framework binary ----------------------------------------------
# Accepts: a Mach-O file, a .framework directory (versioned or flat layout).
resolve_binary() { # candidate path -> echoes binary path or nothing
  local p="$1"
  [[ -n "$p" ]] || return 1
  if [[ -d "$p" ]]; then
    for sub in "Versions/A/Chromium Embedded Framework" "Chromium Embedded Framework"; do
      if [[ -f "$p/$sub" && ! -L "$p/$sub" ]] || [[ -e "$p/$sub" ]]; then
        printf '%s\n' "$p/$sub"
        return 0
      fi
    done
    return 1
  fi
  [[ -f "$p" ]] && printf '%s\n' "$p"
}

BINARY=""
if [[ $# -ge 1 ]]; then
  BINARY="$(resolve_binary "$1" || true)"
  [[ -n "$BINARY" ]] || die "no framework binary at: $1"
else
  CANDIDATES=()
  [[ -n "${CEF_FRAMEWORK_PATH:-}" ]] && CANDIDATES+=("$CEF_FRAMEWORK_PATH")
  while IFS= read -r d; do CANDIDATES+=("$d"); done < <(
    find "$ROOT/.cef/dist" -maxdepth 3 -type d -name 'Chromium Embedded Framework.framework' 2>/dev/null
  )
  while IFS= read -r d; do CANDIDATES+=("$d"); done < <(
    find /tmp/cefswift-ref -maxdepth 3 -type d -name 'Chromium Embedded Framework.framework' 2>/dev/null
  )
  for c in "${CANDIDATES[@]:-}"; do
    BINARY="$(resolve_binary "$c" || true)"
    [[ -n "$BINARY" ]] && break
  done
  [[ -n "$BINARY" ]] || die "no CEF framework binary found. Run 'swift package ... cef download' or pass a path / set CEF_FRAMEWORK_PATH."
fi
log "framework binary: $BINARY"
log "symbol table:     $SYMBOLS_H"

command -v nm >/dev/null 2>&1 || die "nm is required (Command Line Tools)"

# --- Extract bound symbol names from the X-macro list ---------------------------
# Matches both CCEF_SYM(type, name, ...) and CCEF_SYM_VOID(name, ...), tolerant
# of the return type and name being on the same line as the macro opener.
BOUND="$(awk '
  /^[[:space:]]*CCEF_SYM_VOID\(/ {
    s = $0; sub(/^[[:space:]]*CCEF_SYM_VOID\([[:space:]]*/, "", s)
    sub(/[,)].*$/, "", s); gsub(/[[:space:]]/, "", s)
    if (s != "") print s; next
  }
  /^[[:space:]]*CCEF_SYM\(/ {
    s = $0; sub(/^[[:space:]]*CCEF_SYM\([[:space:]]*/, "", s)
    # name is the 2nd comma-separated field (type may contain spaces/* but no comma)
    n = split(s, parts, ",")
    if (n >= 2) { name = parts[2]; gsub(/[[:space:]]/, "", name); if (name != "") print name }
  }
' "$SYMBOLS_H" | sort -u)"
BOUND_COUNT="$(printf '%s\n' "$BOUND" | grep -c . || true)"
[[ "$BOUND_COUNT" -gt 0 ]] || die "extracted zero symbols from $SYMBOLS_H — parser or file broken"

# --- Exported globals of the framework binary -----------------------------------
EXPORTS="$(nm -gU "$BINARY" | awk '{print $NF}' | sed 's/^_//' | sort -u)"
CEF_EXPORT_COUNT="$(printf '%s\n' "$EXPORTS" | grep -c '^cef_' || true)"

# --- Verify every bound symbol is exported --------------------------------------
MISSING="$(comm -23 <(printf '%s\n' "$BOUND") <(printf '%s\n' "$EXPORTS") || true)"

log "bound symbols (ccef_symbols.h): $BOUND_COUNT"
log "exported cef_* globals:         $CEF_EXPORT_COUNT (informational — we bind $BOUND_COUNT of them)"

if [[ -n "$MISSING" ]]; then
  log "MISSING from framework exports:"
  printf '%s\n' "$MISSING" | sed 's/^/[check-symbols]   - /' >&2
  die "$(printf '%s\n' "$MISSING" | grep -c .) bound symbol(s) not exported by the framework"
fi

log "OK — all $BOUND_COUNT bound symbols are exported by the framework"
