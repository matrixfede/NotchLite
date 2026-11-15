#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc Sources/NotchLite/Collectors/CollectorKit.swift Tests/NotchLiteTests/UsageTests.swift -o "$test_dir/usage-tests"
"$test_dir/usage-tests"
