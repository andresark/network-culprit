#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output_dir="$project_dir/dist"
final_app_dir="$output_dir/Network Culprit.app"
release_version=${NETWORK_CULPRIT_RELEASE_VERSION:-1.4.2}
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Release version must be major.minor.patch.'
  exit 1
fi
version_parts=(${(s:.:)release_version})
build_number=$((version_parts[1] * 1000000 + version_parts[2] * 1000 + version_parts[3]))
cd "$project_dir"
mkdir -p "$output_dir"
# Remap debug information so release binaries do not expose a builder's home path.
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=."
binary_dir=$(swift build -c release --show-bin-path)
staging_dir=$(mktemp -d "$project_dir/.build/native-app-bundle-staging.XXXXXX")
app_dir="$staging_dir/Network Culprit.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/.build/NetworkCulprit.iconset"
cp "$binary_dir/NetworkCulprit" "$app_dir/Contents/MacOS/NetworkCulprit"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE.txt"
swift "$project_dir/scripts/GenerateIcon.swift" "$project_dir/.build/NetworkCulprit-icon.png"
for dimension in 16 32 128 256 512; do
  sips -z "$dimension" "$dimension" "$project_dir/.build/NetworkCulprit-icon.png" --out "$project_dir/.build/NetworkCulprit.iconset/icon_${dimension}x${dimension}.png" >/dev/null
  double_dimension=$((dimension * 2))
  sips -z "$double_dimension" "$double_dimension" "$project_dir/.build/NetworkCulprit-icon.png" --out "$project_dir/.build/NetworkCulprit.iconset/icon_${dimension}x${dimension}@2x.png" >/dev/null
done
iconutil -c icns "$project_dir/.build/NetworkCulprit.iconset" -o "$app_dir/Contents/Resources/NetworkCulprit.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Network Culprit</string>
<key>CFBundleDisplayName</key><string>Network Culprit</string>
<key>CFBundleIdentifier</key><string>local.NetworkCulprit</string>
<key>CFBundleExecutable</key><string>NetworkCulprit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>NetworkCulprit</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Network Culprit measures your router, configured DNS servers, and selected Tailscale peer to identify which network layer is failing. It saves diagnostic history locally and does not change network settings.</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Network Culprit contributors. MIT License.</string>
</dict></plist>
PLIST
plutil -replace CFBundleShortVersionString -string "$release_version" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"
plutil -insert NetworkCulpritSourceURL -string 'https://github.com/andresark/network-culprit' "$app_dir/Contents/Info.plist"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier local.NetworkCulprit --options runtime "$app_dir"
codesign --verify --deep --strict "$app_dir"
# Never overwrite the executable of a running, code-signed app. Preserve its
# inode in the build cache and install the fully signed staged bundle by rename.
if [[ -e "$final_app_dir" ]]; then
  mv "$final_app_dir" "$staging_dir/previous-signed-build.app"
fi
mv "$app_dir" "$final_app_dir"
print "Built: $final_app_dir"
