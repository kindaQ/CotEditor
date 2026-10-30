#!/bin/sh
set -eu

# Run the storage tests with Command Line Tools, independently of the Xcode application target.
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/coteditor-session-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

mkdir -p "$test_dir/Tests"
cp "$repo_dir/CotEditor/Sources/Document/SessionCache.swift" "$test_dir/Tests/"
cp "$repo_dir/Tests/Sources/Models/SessionCacheTests.swift" "$test_dir/Tests/"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CotEditorSessionCacheTests",
    platforms: [.macOS(.v26)],
    targets: [.testTarget(name: "SessionCacheTests", path: "Tests")]
)
SWIFT

set --
developer_dir=$(xcode-select -p)
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
if [ -d "$testing_frameworks/Testing.framework" ]; then
    set -- -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xswiftc -plugin-path -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing" \
        -Xlinker -rpath -Xlinker "$testing_frameworks"
    if [ ! -d "$testing_frameworks/_Testing_Foundation.framework/Modules" ]; then
        set -- "$@" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    fi
fi

CLANG_MODULE_CACHE_PATH="$test_dir/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$test_dir/ModuleCache" \
swift test --package-path "$test_dir" --scratch-path "$test_dir/.build" \
    --cache-path "$test_dir/Cache" --config-path "$test_dir/Configuration" \
    --security-path "$test_dir/Security" --disable-sandbox --disable-xctest --enable-swift-testing "$@"
