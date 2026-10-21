#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
compiler=$(xcrun --find swiftc)
plugin="${compiler:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$plugin"
else
  swift test
fi
