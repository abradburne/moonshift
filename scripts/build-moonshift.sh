#!/bin/zsh
# Builds build/Moonshift.app for this folder.
#
#   build-moonshift.sh               local build, signed with Developer ID when available
#   build-moonshift.sh --notarize    signed with Developer ID and notarized by Apple
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
version=1.0.0
name=Moonshift
flags=(-O -wmo)
notarize=false
case "${1:-}" in
  '') ;;
  --notarize) notarize=true;;
  --snapshot) name=Moonshift-Snapshot; flags=(-Onone -D SNAPSHOT);;
  *) print 'Usage: build-moonshift.sh [--notarize|--snapshot]'; exit 1;;
esac
app="build/$name.app"
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

# The app finds its service, models and covers in the folder it was built from.
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
  <key>StudioRoot</key><string>$PWD</string>
  <key>StudioPort</key><integer>8766</integer>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $work/icon.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

if $notarize; then
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
  codesign --verify --strict "$app"
  ditto -c -k --keepParent "$app" "$work/Moonshift.zip"
  asc --profile "$profile" notarization submit --file "$work/Moonshift.zip" --wait
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
elif security find-identity -v -p codesigning | grep -qF "$identity"; then
  # A stable signature lets macOS remember permissions across rebuilds.
  codesign --force --options runtime --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi
rm -rf "$work"
print "Built $PWD/$app"
