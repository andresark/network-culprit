#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
built_app="$project_dir/dist/Network Culprit.app"
installed_app="/Applications/Network Culprit.app"
if [[ ! -d "$built_app" ]]; then
  print -u2 "Build the app first with scripts/build-native-macos-app.sh."
  exit 1
fi
if [[ -e "$installed_app" ]]; then
  installed_identifier=$(plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist")
  if [[ "$installed_identifier" != "local.NetworkCulprit" ]]; then
    print -u2 "Refusing to replace a different application at $installed_app."
    exit 1
  fi
fi
staging_dir=$(mktemp -d "/Applications/.Network-Culprit-install-staging.XXXXXX")
ditto "$built_app" "$staging_dir/Network Culprit.app"
codesign --verify --deep --strict "$staging_dir/Network Culprit.app"
if [[ -e "$installed_app" ]]; then
  mkdir -p "$project_dir/.build"
  previous_app="$project_dir/.build/previous-installed-network-culprit-$(uuidgen).app"
  mv "$installed_app" "$previous_app"
fi
mv "$staging_dir/Network Culprit.app" "$installed_app"
rmdir "$staging_dir"
print "Installed: $installed_app"
print "Enable Launch Network Culprit at Login in the app's Monitoring Settings."
