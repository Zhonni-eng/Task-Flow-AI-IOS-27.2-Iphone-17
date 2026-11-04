#!/bin/zsh
# Runs the TaskflowKit test suites (business logic, storage, AI planning) on this Mac.
# Works with Xcode or with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/../TaskflowKit"
if xcodebuild -license check >/dev/null 2>&1; then
  swift test "$@"
else
  # Command Line Tools: the Swift Testing macros live in a separate plugin folder.
  DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
    -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
fi
