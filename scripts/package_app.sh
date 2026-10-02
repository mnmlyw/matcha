#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package_app.sh [--build-only]

Builds a ReleaseSafe Matcha.app and verifies its bundle version.

Without --build-only, also signs, packages, notarizes, staples, and verifies
matcha-macos-arm64.dmg. Full packaging requires:

  MATCHA_SIGN_IDENTITY   Developer ID Application identity (required)
  MATCHA_NOTARY_PROFILE  notarytool keychain profile (default: matcha-notary)
  MATCHA_DMG_PATH        output path (default: ./matcha-macos-arm64.dmg)
EOF
}

build_only=false
case "${1:-}" in
  "") ;;
  --build-only) build_only=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_root"

version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' build.zig.zon)
if [[ -z "$version" ]]; then
  echo "Could not read version from build.zig.zon" >&2
  exit 1
fi

zig build app -Doptimize=ReleaseSafe

app_path="$repo_root/zig-out/Matcha.app"
plist_path="$app_path/Contents/Info.plist"
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
if [[ "$bundle_version" != "$version" ]]; then
  echo "Bundle version $bundle_version does not match build.zig.zon $version" >&2
  exit 1
fi

if [[ "$build_only" == true ]]; then
  echo "Validated Matcha.app v$version (ReleaseSafe)"
  exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Refusing to package a dirty tracked tree; commit release preparation first" >&2
  exit 1
fi

identity=${MATCHA_SIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  echo "MATCHA_SIGN_IDENTITY must name a Developer ID Application identity" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
  echo "Signing identity not found: $identity" >&2
  exit 1
fi

notary_profile=${MATCHA_NOTARY_PROFILE:-matcha-notary}
output_path=${MATCHA_DMG_PATH:-$repo_root/matcha-macos-arm64.dmg}
if [[ -e "$output_path" ]]; then
  echo "Refusing to overwrite existing output: $output_path" >&2
  exit 1
fi

codesign --deep --force --options runtime --timestamp --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

release_tmp=$(mktemp -d "${TMPDIR:-/tmp}/matcha-release.XXXXXX")
stage_dir="$release_tmp/payload"
mkdir -p "$stage_dir"
trap 'rm -rf "$release_tmp"' EXIT
cp -R "$app_path" "$stage_dir/Matcha.app"
ln -s /Applications "$stage_dir/Applications"

temp_dmg="$release_tmp/matcha-macos-arm64.dmg"
hdiutil create -volname Matcha -srcfolder "$stage_dir" -ov -format UDZO "$temp_dmg"
codesign --force --timestamp --sign "$identity" "$temp_dmg"
xcrun notarytool submit "$temp_dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$temp_dmg"
xcrun stapler validate "$temp_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$temp_dmg"

mv "$temp_dmg" "$output_path"
echo "Prepared Matcha v$version: $output_path"
