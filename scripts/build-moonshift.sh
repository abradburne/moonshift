#!/bin/zsh
# Builds build/Moonshift.app.
#
#   build-moonshift.sh               for this checkout: the app uses the models
#                                    and covers in this folder
#   build-moonshift.sh --notarize    the same, notarized by Apple
#   build-moonshift.sh --release     self-contained and notarized, for other Macs:
#                                    the transcription helper ships inside the app, and models
#                                    and covers live in Application Support.
#                                    Written to build/release/, with a .dmg
#
# A release bundles two tools so that nothing has to be installed first: uv, and
# the music engine built by scripts/setup-metal.sh. Point MOONSHIFT_ENGINE_BINARY
# or MOONSHIFT_UV_BINARY at other copies if needed.
#   build-moonshift.sh --snapshot    development build that can save screenshots of
#                                    itself (see native/Dev/Snapshot.swift)
#
# Notarizing needs the Developer ID certificate in your keychain and the asc CLI
# with an authentication profile for the same team. The profile is always named
# explicitly, because the default asc profile may belong to another team.
# Override either with MOONSHIFT_SIGN_IDENTITY / MOONSHIFT_ASC_PROFILE.
set -euo pipefail
cd "${0:A:h:h}"
identity=${MOONSHIFT_SIGN_IDENTITY:-Developer ID Application: XenoCode Inc (HVUXZ635F3)}
profile=${MOONSHIFT_ASC_PROFILE:-XenoCode}
version=1.4.1
name=Moonshift
flags=(-O -wmo)
notarize=false
packaged=false
out=build
case "${1:-}" in
  '') ;;
  --notarize) notarize=true;;
  --release) notarize=true; packaged=true; out=build/release;;
  --snapshot) name=Moonshift-Snapshot; flags=(-Onone -D SNAPSHOT);;
  *) print 'Usage: build-moonshift.sh [--notarize|--release|--snapshot]'; exit 1;;
esac
# A release is kept apart, so it never replaces the checkout build you are running.
app="$out/$name.app"
work=build/intermediates
rm -rf "$app" "$work"
mkdir -p build/module-cache "$work" "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 $flags \
  -module-cache-path "$PWD/build/module-cache" -parse-as-library native/**/*.swift \
  -o "$app/Contents/MacOS/Moonshift"

# Compile the Icon Composer document: Liquid Glass on macOS 26 and later, with
# the flattened .icns it generates for earlier systems.
xcrun actool native/Resources/Moonshift.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon Moonshift \
  --output-partial-info-plist "$work/icon.plist" >/dev/null

# A checkout build finds its models and covers in this folder. The packaged
# app carries the transcription helper and setup scripts with it instead.
if $packaged; then
  location=''
  engine=${MOONSHIFT_ENGINE_BINARY:-.runtime/audio.cpp/build/macos-metal-release/bin/audiocpp_cli}
  # A copy kept in build/engine wins, for checkouts whose own engine targets a newer macOS.
  [[ -z "${MOONSHIFT_ENGINE_BINARY:-}" && -x build/engine/audiocpp_cli ]] && engine=build/engine/audiocpp_cli
  uv=${MOONSHIFT_UV_BINARY:-$(command -v uv)}
  [[ -x "$engine" && -x "$uv" ]] || { print 'A release needs the built music engine and uv. Run scripts/setup-moonshift.sh first.'; exit 1 }
  # The engine must run wherever the app does, not only on the Mac that built it.
  minimum=$(vtool -show-build "$engine" | awk '/minos/ {print $2}')
  [[ "${minimum%%.*}" -le 14 ]] || { print "The music engine was built for macOS $minimum. Rebuild it with scripts/setup-metal.sh."; exit 1 }
  mkdir -p "$app/Contents/Helpers"
  cp "$engine" "$app/Contents/Helpers/audiocpp_cli"
  cp "$uv" "$app/Contents/Helpers/uv"
  mkdir -p "$app/Contents/Resources/studio" "$app/Contents/Resources/scripts"
  cp studio/*.py "$app/Contents/Resources/studio/"
  cp scripts/setup-*.sh scripts/patch-metal-progress.py "$app/Contents/Resources/scripts/"
  cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
else
  location="<key>StudioRoot</key><string>$PWD</string>"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Moonshift</string>
  <key>CFBundleIdentifier</key><string>jp.co.xenocode.Moonshift</string>
  <key>CFBundleName</key><string>Moonshift</string>
  <key>CFBundleDisplayName</key><string>Moonshift</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Alan Bradburne. Free software under the GNU GPL v3 or later.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  $location
  <key>StudioPort</key><integer>${MOONSHIFT_PORT:-8766}</integer>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $work/icon.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

if $notarize; then
  for helper in "$app"/Contents/Helpers/*(N); do
    codesign --force --options runtime --timestamp --sign "$identity" "$helper"
  done
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
  codesign --verify --strict "$app"
  ditto -c -k --keepParent "$app" "$work/Moonshift.zip"
  asc --profile "$profile" notarization submit --file "$work/Moonshift.zip" --wait
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
  if $packaged; then
    # A disk image with the usual drag-to-Applications layout, notarized itself
    # so it opens cleanly after download.
    dmg="$out/Moonshift-$version.dmg"
    mkdir "$work/dmg"
    cp -R "$app" "$work/dmg/"
    ln -s /Applications "$work/dmg/Applications"
    rm -f "$dmg"
    hdiutil create -quiet -volname Moonshift -srcfolder "$work/dmg" -format UDZO -imagekey zlib-level=9 "$dmg"
    codesign --force --timestamp --sign "$identity" "$dmg"
    asc --profile "$profile" notarization submit --file "$dmg" --wait
    xcrun stapler staple "$dmg"
    print "Packaged $PWD/$dmg"
  fi
elif security find-identity -v -p codesigning | grep -qF "$identity"; then
  # A stable signature lets macOS remember permissions across rebuilds.
  codesign --force --options runtime --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi
rm -rf "$work"
print "Built $PWD/$app"
