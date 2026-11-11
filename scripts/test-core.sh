#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Recent standalone Command Line Tools ship Testing, but SwiftPM may not discover
# its framework and macro plugin. Keep this host workaround outside the package.
daywell_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
daywell_frameworks="$daywell_developer/Library/Developer/Frameworks"
daywell_testing_plugin="$daywell_developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$daywell_developer" == */CommandLineTools && -d "$daywell_frameworks/Testing.framework" && -f "$daywell_testing_plugin" ]]; then
    exec swift test --scratch-path build/swiftpm --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$daywell_frameworks" \
        -Xswiftc -load-plugin-library -Xswiftc "$daywell_testing_plugin" \
        -Xlinker -rpath -Xlinker "$daywell_frameworks" "$@"
fi
exec swift test --scratch-path build/swiftpm --disable-xctest "$@"
