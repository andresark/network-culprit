#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app_dir="$project_dir/dist/Network Culprit.app"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
if plutil -extract NetworkCulpritSourceDirectory raw "$app_dir/Contents/Info.plist" >/dev/null 2>&1; then
  print -u2 'Public bundles must not contain a local source directory.'
  exit 1
fi
# Use a file to avoid a pipe/SIGPIPE hiding strings' exit status.
strings "$app_dir/Contents/MacOS/NetworkCulprit" > "$project_dir/.build/public-binary-strings.txt"
if LC_ALL=C grep -E '/Users/|/home/[^/]+/' "$project_dir/.build/public-binary-strings.txt"; then
  print -u2 'Public executable contains a builder home path.'
  exit 1
fi
print 'Public bundle verification passed.'
