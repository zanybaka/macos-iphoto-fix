#!/usr/bin/env bash
#
# fix-iphoto-sequoia.sh
#
# Repair Apple iPhoto / Aperture so they launch on modern macOS (Sonoma, Sequoia, ...).
#
# It targets the two failure layers seen on recent macOS:
#   1. dyld abort at launch:  "Symbol not found: _OBJC_CLASS_$_<X>"
#      (a private AppKit class whose *symbol* was dropped from the OS; the class
#       may still exist at runtime, but ProKit's static two-level bind fails).
#   2. A later crash inside removed/changed AppKit internals (e.g. the Sequoia
#      NSSegmentedControl "updateSegmentItemConfiguration:" out-of-bounds), which
#      is handled by the Retroactive runtime fixer (ApertureFixer).
#
# Two situations are handled:
#   * ALREADY-PATCHED app (Retroactive ran once, then a macOS upgrade broke it):
#       -> surgical top-up. We rebuild the bundle's AppKit shim to stub exactly
#          the AppKit classes whose symbol is missing on *this* OS/arch, and
#          (optionally) swap in a newer ApertureFixer from your own Retroactive.
#   * PRISTINE app (never patched): the symbol shim alone is not enough because
#       ProKit still links the system AppKit. We detect this and guide you to run
#       Retroactive first, then re-run this tool to top-up for your macOS. An
#       experimental --full mode can attempt the redirection using your own
#       Retroactive assets.
#
# This script ships NO Apple or Retroactive binaries. The AppKit shim is built
# from clean-room source in this repo; the ApertureFixer is read from a copy of
# Retroactive that YOU download (https://github.com/cormiertyshawn895/Retroactive).
#
# Apple apps are x86_64, so all analysis is done in the x86_64 slice (under Rosetta
# on Apple Silicon). Run with no action flag for a dry diagnosis.
#
# License: MIT.

# shellcheck disable=SC2012  # `ls -t | head` is the concise "newest file by mtime" idiom here
# shellcheck disable=SC2016  # single-quoted strings are literal grep/sed regex, by design
set -euo pipefail

# ----------------------------------------------------------------------------- ui
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die()  { printf '%serr%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: fix-iphoto-sequoia.sh [options]

  --app PATH           Path to iPhoto.app / Aperture.app
                       (default: auto-detect in common locations)
  --retroactive PATH   Path to a downloaded Retroactive.app, used as the source
                       of an up-to-date ApertureFixer (and assets for --full).
  --diagnose           Analyze only; make no changes. (Default when no action.)
  --fix                Apply the fix (top-up for already-patched apps).
  --full               Experimental: also patch a PRISTINE app (needs --retroactive).
  --launch             Launch the app afterwards and report whether it stays up.
  --yes                Don't prompt for confirmation.
  -h, --help           Show this help.

Examples:
  ./fix-iphoto-sequoia.sh --app "/Applications/iPhoto.app"
  ./fix-iphoto-sequoia.sh --app "/Applications/iPhoto.app" \
      --fix --retroactive /Applications/Retroactive.app --launch
USAGE
}

# --------------------------------------------------------------------------- args
APP=""; RETRO=""; ACTION="diagnose"; FULL=0; DO_LAUNCH=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?}"; shift 2;;
    --retroactive) RETRO="${2:?}"; shift 2;;
    --diagnose) ACTION="diagnose"; shift;;
    --fix) ACTION="fix"; shift;;
    --full) FULL=1; ACTION="fix"; shift;;
    --launch) DO_LAUNCH=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1 (see --help)";;
  esac
done

ARCH="x86_64"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------- preflight
[ "$(uname)" = "Darwin" ] || die "macOS only."
for t in clang nm otool codesign install_name_tool; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t (run: xcode-select --install)"
done
OSVER="$(sw_vers -productVersion)"
if [ "$(uname -m)" = "arm64" ]; then
  /usr/bin/pgrep -q oahd 2>/dev/null || warn "Rosetta 2 not detected; install: softwareupdate --install-rosetta --agree-to-license"
fi

# --------------------------------------------------------------------- locate app
if [ -z "$APP" ]; then
  for c in "/Applications/iPhoto.app" "/Applications/Aperture.app" \
           "/Applications/Images/iPhoto.app" "$HOME/Applications/iPhoto.app"; do
    [ -d "$c" ] && { APP="$c"; break; }
  done
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then die "app not found; pass --app /path/to/iPhoto.app"; fi
APP="${APP%/}"
MAIN_BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || basename "$APP" .app)"
[ -f "$MAIN_BIN" ] || MAIN_BIN="$(ls "$APP"/Contents/MacOS/* 2>/dev/null | head -1)"
APPNAME="$(basename "$APP")"
log "App:        $APP"
log "macOS:      $OSVER ($(uname -m)), analyzing $ARCH slice"

# --------------------------------------------------------- build the symbol probe
# A tiny x86_64 helper: loads the frameworks these apps link, then reads class
# names on stdin and prints those whose _OBJC_CLASS_$_<name> symbol is NOT
# exported on this OS. Loading the frameworks avoids false positives for classes
# that live outside AppKit (AVFoundation, QTKit, WebKit, ...).
SYMCHECK="$TMP/symcheck"
cat > "$TMP/symcheck.m" <<'EOF'
#import <Foundation/Foundation.h>
#import <dlfcn.h>
int main(void){ @autoreleasepool{
  // Test specifically whether AppKit (and its re-exports) exports each symbol on
  // this OS. The bundled shim re-exports system AppKit, so "not exported by
  // AppKit" is exactly what the shim must stub for a two-level "from AppKit" bind.
  void* ak = dlopen("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", RTLD_NOW|RTLD_GLOBAL);
  if(!ak) return 2;
  NSData* d=[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
  for(NSString* line in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]){
    NSString* n=[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(!n.length) continue;
    if(!dlsym(ak,[[@"OBJC_CLASS_$_" stringByAppendingString:n] UTF8String]))
      printf("%s\n", n.UTF8String);
  }
}return 0;}
EOF
clang -arch "$ARCH" -framework Foundation -o "$SYMCHECK" "$TMP/symcheck.m" \
  || die "failed to build the symbol probe"

# -------------------------------------------------------- enumerate macho binaries
macho_binaries() {
  local fw base
  for fw in "$APP"/Contents/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    base="$(basename "$fw" .framework)"
    [ -f "$fw/Versions/A/$base" ] && printf '%s\n' "$fw/Versions/A/$base"
  done
  [ -f "$MAIN_BIN" ] && printf '%s\n' "$MAIN_BIN"
  find "$APP/Contents" \( -path "*/PlugIns/*" -o -path "*/XPCServices/*" \
       -o -path "*/Library/*Plug*/*" \) -type f -perm -u+x 2>/dev/null
}

# all undefined ObjC class imports across the bundle, with their source library
RAW="$TMP/undef.txt"
build_raw() {
  : > "$RAW"
  while IFS= read -r b; do
    [ -f "$b" ] || continue
    nm -m -arch "$ARCH" "$b" 2>/dev/null | grep 'undefined.*_OBJC_CLASS_\$_' >> "$RAW" || true
  done < <(macho_binaries)
}

# classes imported from a given library-regex whose symbol is missing on this OS
missing_for() {  # $1 = library alternation, e.g. 'AppKit'
  local classes="$TMP/c.$$.txt"
  grep -E "\(from ($1)\)" "$RAW" 2>/dev/null \
    | sed -E 's/.*_OBJC_CLASS_\$_([A-Za-z0-9_]+).*/\1/' | sort -u > "$classes" || true
  if [ -s "$classes" ]; then "$SYMCHECK" < "$classes" | sort -u; fi
}

# ----------------------------------------------------------------- detect state
SHIM_FW="$APP/Contents/Frameworks/AppKit.framework"
SHIM="$SHIM_FW/Versions/C/AppKit"
PATCHED=0; [ -f "$SHIM" ] && PATCHED=1
FIXER="$APP/Contents/Frameworks/ApertureFixer.framework/Versions/A/ApertureFixer"

# classes the CURRENT bundle shim already exports
shim_exports() {
  [ -f "$SHIM" ] || return 0
  nm -arch "$ARCH" "$SHIM" 2>/dev/null \
    | sed -nE 's/.* _OBJC_CLASS_\$_([A-Za-z0-9_]+)$/\1/p' | sort -u
}

# ----------------------------------------------------------------- diagnose
log "Patch state: $([ "$PATCHED" = 1 ] && echo 'Retroactive-patched (bundled AppKit shim present)' || echo 'pristine (no bundled AppKit shim)')"
log "Scanning bundle for removed AppKit class symbols on macOS $OSVER ..."
build_raw
# Full set the shim must provide (AppKit classes AppKit no longer exports):
missing_for 'AppKit' | sort -u > "$TMP/miss.txt" || true
MISSING="$(cat "$TMP/miss.txt")"
# Of those, which the current shim does NOT yet provide (== why it still crashes):
shim_exports > "$TMP/have.txt"
comm -23 "$TMP/miss.txt" "$TMP/have.txt" > "$TMP/unsat.txt" 2>/dev/null || cp "$TMP/miss.txt" "$TMP/unsat.txt"
UNSAT="$(cat "$TMP/unsat.txt")"

if [ -z "$MISSING" ]; then
  ok "No AppKit class symbols need stubbing for the scanned binaries."
else
  log "Shim must provide (a rebuild includes all of these): $(printf '%s' "$MISSING" | tr '\n' ' ')"
  if [ "$PATCHED" = 1 ] && [ -z "$UNSAT" ]; then
    ok "Current shim already provides all of them — looks correct for macOS $OSVER."
  else
    warn "NOT yet provided by the bundle (this is what breaks launch): ${UNSAT:-<all of the above>}"
  fi
fi
if [ -f "$FIXER" ]; then
  has_seg="$(nm -arch "$ARCH" "$FIXER" 2>/dev/null | grep -c 'retro_updateSegmentItemConfiguration' || true)"
  log "ApertureFixer present (Sequoia segmented-control fix: $([ "${has_seg:-0}" -gt 0 ] && echo yes || echo NO))"
fi

if [ "$ACTION" = "diagnose" ]; then
  echo
  if [ "$PATCHED" = 1 ]; then
    log "To repair:  $0 --app \"$APP\" --fix --retroactive /path/to/Retroactive.app --launch"
  else
    log "Pristine app. Patch with Retroactive first: https://github.com/cormiertyshawn895/Retroactive"
    log "Then:  $0 --app \"$APP\" --fix   (or experimental:  --full --retroactive ...)"
  fi
  exit 0
fi

# ----------------------------------------------------------------- helpers (fix)
confirm() { [ "$ASSUME_YES" = 1 ] && return 0; printf 'Proceed with modifying "%s"? [y/N] ' "$APP"; read -r a; [ "$a" = y ] || [ "$a" = Y ]; }

backup_app() {
  local dst; dst="${APP%.app}.backup-$(date +%Y%m%d-%H%M%S).app"
  log "Backing up -> $dst"
  if /bin/cp -c -R "$APP" "$dst" 2>/dev/null; then ok "backup (APFS clone)"; else ditto "$APP" "$dst"; ok "backup (copy)"; fi
}

adhoc_sign() { codesign --force --sign - "$1" >/dev/null 2>&1 && ok "ad-hoc signed: $(basename "$1")"; }

shim_superclass() { case "$1" in *View|*Indicator) echo NSView;; *) echo NSObject;; esac; }

build_shim() {  # $1=class list  $2=output path
  local out="$2" src="$TMP/appkit_shim.m" sup
  { echo '#import <Cocoa/Cocoa.h>'
    for c in $1; do sup="$(shim_superclass "$c")"; echo "@interface $c : $sup @end"; echo "@implementation $c @end"; done
  } > "$src"
  clang -arch "$ARCH" -dynamiclib -o "$out" "$src" \
    -install_name "/System/Library/Frameworks/AppKit.framework/Versions/A/AppKit" \
    -compatibility_version 45.0.0 -current_version 9999.0.0 \
    -Wl,-reexport_framework,AppKit -framework Foundation || die "shim build failed"
}

swap_aperturefixer() {  # uses $RETRO
  local src="$RETRO/Contents/Resources/ApertureFixer/Versions/A/ApertureFixer"
  [ -f "$src" ]   || { warn "no ApertureFixer in $RETRO (skipping fixer swap)"; return 0; }
  [ -f "$FIXER" ] || { warn "bundle has no ApertureFixer to replace (skipping)"; return 0; }
  local new_cnt old_cnt new_seg old_seg
  new_cnt="$(nm -arch "$ARCH" "$src"   2>/dev/null | grep -c 'retro_' || true)"
  old_cnt="$(nm -arch "$ARCH" "$FIXER" 2>/dev/null | grep -c 'retro_' || true)"
  new_seg="$(nm -arch "$ARCH" "$src"   2>/dev/null | grep -c 'retro_updateSegmentItemConfiguration' || true)"
  old_seg="$(nm -arch "$ARCH" "$FIXER" 2>/dev/null | grep -c 'retro_updateSegmentItemConfiguration' || true)"
  # don't downgrade: if the bundle's fixer already has more fixes (incl. the
  # segmented-control one), keep it.
  if [ "${new_cnt:-0}" -lt "${old_cnt:-0}" ] && [ "${old_seg:-0}" -ge 1 ]; then
    warn "Retroactive's ApertureFixer ($new_cnt fixes) is older than the bundle's ($old_cnt); keeping bundle's."
    return 0
  fi
  cp "$src" "$FIXER"; chmod 755 "$FIXER"; xattr -c "$FIXER" 2>/dev/null || true
  adhoc_sign "$FIXER"
  ok "ApertureFixer refreshed from Retroactive (Sequoia segmented-control fix: $([ "${new_seg:-0}" -gt 0 ] && echo yes || echo no))"
}

verify_shim() {
  [ -n "$MISSING" ] || { ok "no stubs were needed"; return 0; }
  log "Verifying the shim now exports the stubbed classes ..."
  local c okall=1
  for c in $MISSING; do
    if nm -arch "$ARCH" "$SHIM" 2>/dev/null | grep -q "_OBJC_CLASS_\$_$c\$"; then ok "exports $c"; else warn "missing $c in shim"; okall=0; fi
  done
  [ "$okall" = 1 ]
}

# ----------------------------------------------------------------- top-up (patched)
do_topup() {
  confirm || die "aborted."
  backup_app
  if [ -z "$MISSING" ]; then
    log "No missing AppKit symbols; leaving shim unchanged."
  else
    log "Rebuilding AppKit shim with stubs: $(printf '%s' "$MISSING" | tr '\n' ' ')"
    build_shim "$MISSING" "$TMP/AppKit.shim"
    cp "$TMP/AppKit.shim" "$SHIM"; chmod 755 "$SHIM"; xattr -c "$SHIM" 2>/dev/null || true
    adhoc_sign "$SHIM"
  fi
  if [ -n "$RETRO" ]; then swap_aperturefixer; else
    warn "no --retroactive: skipping ApertureFixer refresh (later-stage crashes may remain)."
  fi
}

# ------------------------------------------------------- experimental full patch
do_full() {
  [ -n "$RETRO" ] || die "--full needs --retroactive /path/to/Retroactive.app"
  warn "EXPERIMENTAL full patch of a pristine app. Retroactive's own app is the"
  warn "reference and is recommended; this is best-effort using YOUR Retroactive assets."
  confirm || die "aborted."
  backup_app
  local res="$RETRO/Contents/Resources" insert_dylib="$RETRO/Contents/Resources/insert_dylib"
  [ -x "$insert_dylib" ] || die "insert_dylib not found in Retroactive ($insert_dylib)"

  mkdir -p "$SHIM_FW/Versions/C"
  build_shim "${MISSING:-NSRegion}" "$SHIM"; chmod 755 "$SHIM"; adhoc_sign "$SHIM"

  local prokit="$APP/Contents/Frameworks/ProKit.framework/Versions/A/ProKit"
  if [ -f "$prokit" ]; then
    install_name_tool -change \
      /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
      @executable_path/../Frameworks/AppKit.framework/Versions/C/AppKit \
      "$prokit" 2>/dev/null || warn "could not rewrite ProKit AppKit path"
    adhoc_sign "$prokit"
  fi
  if [ -d "$res/ApertureFixer" ]; then
    rm -rf "$APP/Contents/Frameworks/ApertureFixer.framework"
    cp -R "$res/ApertureFixer" "$APP/Contents/Frameworks/ApertureFixer.framework"
    "$insert_dylib" --inplace --all-yes \
      @executable_path/../Frameworks/ApertureFixer.framework/Versions/A/ApertureFixer \
      "$MAIN_BIN" >/dev/null 2>&1 || warn "ApertureFixer injection failed"
    adhoc_sign "$APP/Contents/Frameworks/ApertureFixer.framework/Versions/A/ApertureFixer"
  fi
  adhoc_sign "$MAIN_BIN"
  warn "Best-effort only. iPhoto/Aperture may also need Python.framework and the"
  warn "iLifeMediaBrowser shim. If it still fails, run Retroactive's app, then --fix."
}

# ------------------------------------------------------------------------ run
if [ "$PATCHED" = 1 ]; then
  do_topup
elif [ "$FULL" = 1 ]; then
  do_full
else
  echo
  warn "PRISTINE app — the symbol shim can't help until ProKit is redirected."
  warn "Patch it with Retroactive first: https://github.com/cormiertyshawn895/Retroactive"
  warn "then:  $0 --app \"$APP\" --fix --retroactive /path/to/Retroactive.app"
  warn "or experimental:  $0 --app \"$APP\" --full --retroactive /path/to/Retroactive.app"
  exit 2
fi

if [ "$PATCHED" = 1 ]; then verify_shim || true; fi

# ------------------------------------------------------------------ optional launch
if [ "$DO_LAUNCH" = 1 ]; then
  log "Launching $APPNAME ..."
  before="$(ls -t "$HOME/Library/Logs/DiagnosticReports/"*.ips 2>/dev/null | head -1 || true)"
  pkill -f "$MAIN_BIN" 2>/dev/null || true
  open "$APP"; sleep 40
  if pgrep -f "$MAIN_BIN" >/dev/null 2>&1; then
    ok "$APPNAME is running (stayed up ~40s) on macOS $OSVER."
  else
    after="$(ls -t "$HOME/Library/Logs/DiagnosticReports/"*.ips 2>/dev/null | head -1 || true)"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      warn "It crashed. Newest report: $after"
      grep -m1 -E 'Symbol not found|Library not loaded' "$after" 2>/dev/null || true
    else
      warn "$APPNAME not running (no crash report; check Gatekeeper / right-click Open)."
    fi
  fi
fi

ok "Done. A timestamped backup of the original app is alongside it."
