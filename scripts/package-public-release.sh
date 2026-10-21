#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
"$project_dir/scripts/verify-public-app.sh"
cd "$project_dir/dist"
version=$(plutil -extract CFBundleShortVersionString raw 'Network Culprit.app/Contents/Info.plist')
if [[ -n "${GITHUB_REF_NAME:-}" && "$GITHUB_REF_NAME" == v* && "$GITHUB_REF_NAME" != "v$version" ]]; then
  print -u2 'Release tag must match the bundle version.'
  exit 1
fi
archive="Network-Culprit-${version}-macOS27-AppleSilicon.zip"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr 'Network Culprit.app' "$archive"
shasum -a 256 "$archive" > SHA256SUMS.txt
print "Packaged: $archive"
