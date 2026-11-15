#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc Sources/NotchLite/Collectors/CollectorKit.swift Tests/NotchLiteTests/UsageTests.swift -o "$test_dir/usage-tests"
"$test_dir/usage-tests"

swiftc Sources/NotchLite/RemoteAgentEvent.swift Tests/RemoteEventTests.swift -o "$test_dir/remote-tests"
"$test_dir/remote-tests"
python3 -m unittest discover -s Tests -p "test_remote*.py"
swiftc -DDEBUG Sources/NotchLite/RemoteAgentEvent.swift Sources/NotchLite/AgentService.swift Sources/NotchLite/AgentLauncher.swift Sources/NotchLite/Collectors/CollectorKit.swift Tests/RemoteSessionTests.swift -o "$test_dir/session-tests"
"$test_dir/session-tests"
swiftc Sources/NotchLite/Settings.swift Tests/AgentVisibilityTests.swift -o "$test_dir/visibility-tests"
"$test_dir/visibility-tests"
