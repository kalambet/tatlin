#!/usr/bin/env bash
#
# Tatlin release: archive -> Developer-ID export -> codesign verify -> notarize ->
# staple -> (optional) DMG (M3.8, ADR-9). Config from scripts/config.yaml; any value
# can be overridden by env var. Use --dry-run to validate everything without building
# or contacting Apple.
#
#   ./scripts/release.sh --dry-run     # preflight + plan only
#   ./scripts/release.sh               # full signed + notarized build (prompts first)
#
set -euo pipefail

# ---- pretty output --------------------------------------------------------
if [[ -t 1 ]]; then C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;34m'; C_0=$'\033[0m'
else C_G=; C_R=; C_Y=; C_B=; C_0=; fi
print_step()    { echo "${C_B}==>${C_0} $*"; }
print_success() { echo "${C_G}✓${C_0} $*"; }
print_warn()    { echo "${C_Y}!${C_0} $*"; }
print_error()   { echo "${C_R}✗${C_0} $*" >&2; }
die()           { print_error "$@"; exit 1; }

# ---- paths ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
cd "$REPO_ROOT"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) die "unknown arg: $arg (try --dry-run)" ;;
  esac
done

# ---- config (YAML leaf-key grep; env override wins) -----------------------
[[ -f "$CONFIG" ]] || die "missing config: $CONFIG"
yget() { grep -E "^[[:space:]]*$1:" "$CONFIG" | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^\"(.*)\"$/\1/"; }

SCHEME="${SCHEME:-$(yget scheme)}"
PROJECT="${PROJECT:-$(yget project)}"
BUNDLE_ID="${BUNDLE_ID:-$(yget bundle_id)}"
CONFIGURATION="${CONFIGURATION:-$(yget configuration)}"
TEAM_ID="${TEAM_ID:-$(yget team_id)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(yget identity)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-$(yget keychain_profile)}"
BUILD_DIR="${BUILD_DIR:-$(yget build_dir)}"
MAKE_DMG="${MAKE_DMG:-$(yget make_dmg)}"

ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$SCHEME.app"
ZIP="$BUILD_DIR/$SCHEME-notarize.zip"
DMG="$BUILD_DIR/$SCHEME.dmg"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"

echo "${C_B}Tatlin release${C_0}  (dry-run=$DRY_RUN)"
echo "  scheme=$SCHEME  config=$CONFIGURATION  bundle=$BUNDLE_ID"
echo "  team=$TEAM_ID  identity='$SIGN_IDENTITY'  notary-profile=$NOTARY_PROFILE"
echo "  out=$BUILD_DIR  dmg=$MAKE_DMG"
echo

# ---- preflight ------------------------------------------------------------
print_step "Preflight"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
[[ -d "$PROJECT" ]] || die "project not found: $PROJECT"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  print_success "codesign identity present: $SIGN_IDENTITY"
else
  print_warn "no '$SIGN_IDENTITY' identity in keychain."
  print_warn "  Create it: Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
  [[ $DRY_RUN -eq 1 ]] || die "cannot sign for direct distribution without a Developer ID Application cert"
fi

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  print_success "notary profile reachable: $NOTARY_PROFILE"
else
  print_warn "notary profile '$NOTARY_PROFILE' not set up."
  print_warn "  Create it: xcrun notarytool store-credentials $NOTARY_PROFILE --team-id $TEAM_ID --apple-id <id> --password <app-specific-pw>"
  [[ $DRY_RUN -eq 1 ]] || die "cannot notarize without stored credentials"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  print_success "Dry run OK — config valid; would archive → export → notarize → staple$([[ "$MAKE_DMG" == true ]] && echo ' → dmg')."
  exit 0
fi

# ---- confirm (outward-facing: uploads the build to Apple) -----------------
read -r -p "$(echo "${C_Y}This builds, signs, and submits the app to Apple for notarization. Continue? [y/N] ${C_0}")" reply
[[ "$reply" =~ ^[Yy]$ ]] || die "aborted"

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

# ---- archive --------------------------------------------------------------
print_step "Archiving ($CONFIGURATION)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" archive

# ---- export (Developer ID) ------------------------------------------------
print_step "Exporting Developer-ID app"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"
[[ -d "$APP" ]] || die "export produced no .app at $APP"

# ---- verify signing -------------------------------------------------------
print_step "Verifying signature + entitlements"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime" \
  && print_success "hardened runtime present" || print_warn "hardened runtime flag not detected"
print_step "Embedded entitlements (ADR-9a):"
codesign -d --entitlements :- "$APP" 2>/dev/null \
  | grep -Eo 'com\.apple\.security[^<]*' | sort -u | sed 's/^/    /' || true

# ---- notarize + staple ----------------------------------------------------
print_step "Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"
print_step "Submitting to Apple notary service (this can take minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
print_step "Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" && print_success "staple validated"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /' || print_warn "spctl assessment non-zero (review above)"

# ---- dmg (optional) -------------------------------------------------------
if [[ "$MAKE_DMG" == true ]]; then
  print_step "Building DMG"
  hdiutil create -volname "$SCHEME" -srcfolder "$APP" -ov -format UDZO "$DMG"
  print_step "Stapling DMG"
  xcrun stapler staple "$DMG" || print_warn "DMG staple skipped"
  print_success "DMG: $DMG"
fi

print_success "Release ready in $BUILD_DIR — attach the $([[ "$MAKE_DMG" == true ]] && echo DMG || echo .app/zip) to a GitHub Release."
